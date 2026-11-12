/**
 * Batch job that escalates open Cases that have breached their SLA thresholds.
 *
 * SLA rules come from the Case_Escalation_Rule__mdt Custom Metadata Type
 * (active rows only). Age = hours since Last_Escalated_At__c, or since
 * CreatedDate if the case has never been escalated. Shipped rules:
 *   - Medium priority, age >= 48 hours → escalated to High
 *   - High priority,   age >= 24 hours → escalated to Critical
 *
 * A rule whose To_Priority__c is not an active Case.Priority value (e.g.
 * "Critical" in an org that has not added it) is skipped and reported in the
 * run summary instead of failing every update.
 *
 * Measuring from the last escalation means a Medium case escalated to High
 * gets a fresh 24 hours at High instead of jumping straight to Critical on
 * the next run.
 *
 * On escalation:
 *   - Priority is updated and Last_Escalated_At__c is stamped
 *   - A chatter post is added to the Case
 *   - An email alert is sent to the Case Owner
 *
 * Schedule this job via CaseEscalationScheduler or directly in Setup > Apex Jobs.
 *
 * Sharing: declared `without sharing` on purpose. This is an org-wide SLA job:
 * it must evaluate every open Case regardless of which user scheduled it,
 * otherwise Cases the scheduling user cannot see would silently never escalate.
 * It only reads/updates Case.Priority and posts to the Case feed; it exposes no
 * data back to an interactive user.
 */
public without sharing class CaseEscalationBatch implements Database.Batchable<SObject>, Database.Stateful {
  private static final Long MILLIS_PER_HOUR = 3600000;

  // Test-only injection point so tests do not depend on the shipped CMDT rows.
  @TestVisible
  private static List<EscalationRule> rulesOverride;

  private Map<String, EscalationRule> rulesByFromPriority = new Map<String, EscalationRule>();
  private Integer minThresholdHours;
  private Integer escalatedCount = 0;
  @TestVisible
  private List<String> errors = new List<String>();

  public CaseEscalationBatch() {
    Set<String> validPriorities = new Set<String>();
    for (
      Schema.PicklistEntry entry : Schema.SObjectType.Case.fields.Priority.getPicklistValues()
    ) {
      if (entry.isActive()) {
        validPriorities.add(entry.getValue());
      }
    }

    for (EscalationRule rule : loadRules()) {
      if (!validPriorities.contains(rule.toPriority)) {
        errors.add(
          'Rule skipped: target priority "' +
            rule.toPriority +
            '" is not an active Case.Priority value.'
        );
        continue;
      }
      if (rule.thresholdHours == null || rule.thresholdHours < 1) {
        errors.add(
          'Rule skipped: invalid threshold for priority "' +
            rule.fromPriority +
            '".'
        );
        continue;
      }
      if (rulesByFromPriority.containsKey(rule.fromPriority)) {
        errors.add(
          'Rule skipped: more than one active rule for priority "' +
            rule.fromPriority +
            '".'
        );
        continue;
      }
      rulesByFromPriority.put(rule.fromPriority, rule);
      if (
        minThresholdHours == null ||
        rule.thresholdHours < minThresholdHours
      ) {
        minThresholdHours = rule.thresholdHours;
      }
    }
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    // Coarse SOQL pre-filter on the smallest active threshold; the exact
    // per-priority threshold is applied in execute(). SOQL cannot express
    // COALESCE(Last_Escalated_At__c, CreatedDate), hence the OR. With no
    // valid rules the priority set is empty and the query returns no rows.
    Set<String> fromPriorities = rulesByFromPriority.keySet();
    DateTime cutoff = DateTime.now()
      .addHours(-(minThresholdHours == null ? 0 : minThresholdHours));
    return Database.getQueryLocator(
      [
        SELECT
          Id,
          CaseNumber,
          Subject,
          Priority,
          Status,
          CreatedDate,
          Last_Escalated_At__c,
          OwnerId,
          Owner.Email,
          Owner.Name,
          Account.Name
        FROM Case
        WHERE
          IsClosed = FALSE
          AND Priority IN :fromPriorities
          AND (Last_Escalated_At__c < :cutoff
          OR (Last_Escalated_At__c = NULL
          AND CreatedDate < :cutoff))
      ]
    );
  }

  public void execute(Database.BatchableContext bc, List<Case> cases) {
    List<Case> toUpdate = new List<Case>();
    List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
    List<FeedItem> posts = new List<FeedItem>();

    DateTime now = DateTime.now();
    for (Case c : cases) {
      Long hoursOpen = hoursSinceLastEscalation(c, now);
      String newPriority = getEscalatedPriority(c.Priority, hoursOpen);

      if (newPriority == null)
        continue;

      c.Priority = newPriority;
      c.Last_Escalated_At__c = now;
      toUpdate.add(c);

      posts.add(buildChatterPost(c, hoursOpen));

      if (String.isNotBlank(c.Owner.Email)) {
        emails.add(buildEmail(c, hoursOpen));
      }
    }

    if (!toUpdate.isEmpty()) {
      List<Database.SaveResult> results = Database.update(toUpdate, false);
      for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
          escalatedCount++;
        } else {
          errors.add(
            'Case ' +
              toUpdate[i].CaseNumber +
              ': ' +
              results[i].getErrors()[0].getMessage()
          );
        }
      }
    }

    if (!posts.isEmpty()) {
      insert posts;
    }

    if (!emails.isEmpty()) {
      Messaging.sendEmail(emails, false);
    }
  }

  public void finish(Database.BatchableContext bc) {
    String summary =
      'CaseEscalationBatch completed.\n' +
      'Escalated: ' +
      escalatedCount +
      ' case(s).\n';

    if (!errors.isEmpty()) {
      summary +=
        'Errors (' +
        errors.size() +
        '):\n' +
        String.join(errors, '\n');
    }

    // Notify the running user
    Messaging.SingleEmailMessage adminEmail = new Messaging.SingleEmailMessage();
    adminEmail.setToAddresses(new List<String>{ UserInfo.getUserEmail() });
    adminEmail.setSubject('Case Escalation Batch — Run Summary');
    adminEmail.setPlainTextBody(summary);
    Messaging.sendEmail(
      new List<Messaging.SingleEmailMessage>{ adminEmail },
      false
    );
  }

  // Whole hours since the case was last escalated, or since it was created
  // if it has never been escalated.
  @TestVisible
  private static Long hoursSinceLastEscalation(Case c, DateTime now) {
    DateTime reference = c.Last_Escalated_At__c != null
      ? c.Last_Escalated_At__c
      : c.CreatedDate;
    return (now.getTime() - reference.getTime()) / MILLIS_PER_HOUR;
  }

  // Returns the new priority if SLA is breached, null if no escalation needed
  private String getEscalatedPriority(String currentPriority, Long hoursOpen) {
    EscalationRule rule = rulesByFromPriority.get(currentPriority);
    if (rule != null && hoursOpen >= rule.thresholdHours) {
      return rule.toPriority;
    }
    return null;
  }

  private static List<EscalationRule> loadRules() {
    if (rulesOverride != null) {
      return rulesOverride;
    }
    List<EscalationRule> rules = new List<EscalationRule>();
    for (
      Case_Escalation_Rule__mdt row : Case_Escalation_Rule__mdt.getAll()
        .values()
    ) {
      if (row.Is_Active__c) {
        rules.add(
          new EscalationRule(
            row.From_Priority__c,
            row.To_Priority__c,
            row.Threshold_Hours__c == null
              ? null
              : row.Threshold_Hours__c.intValue()
          )
        );
      }
    }
    return rules;
  }

  // In-memory form of a Case_Escalation_Rule__mdt row.
  @TestVisible
  private class EscalationRule {
    public String fromPriority;
    public String toPriority;
    public Integer thresholdHours;

    public EscalationRule(
      String fromPriority,
      String toPriority,
      Integer thresholdHours
    ) {
      this.fromPriority = fromPriority;
      this.toPriority = toPriority;
      this.thresholdHours = thresholdHours;
    }
  }

  private FeedItem buildChatterPost(Case c, Long hoursOpen) {
    FeedItem post = new FeedItem();
    post.ParentId = c.Id;
    post.Body =
      'SLA BREACH — ' +
      hoursOpen +
      ' hour(s) since this case was opened or last escalated. Priority escalated to ' +
      c.Priority +
      '. Immediate attention required.';
    return post;
  }

  private Messaging.SingleEmailMessage buildEmail(Case c, Long hoursOpen) {
    Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
    email.setToAddresses(new List<String>{ c.Owner.Email });
    email.setSubject('ACTION REQUIRED — SLA Breach on Case #' + c.CaseNumber);
    email.setPlainTextBody(
      'Hi ' +
        c.Owner.Name +
        ',\n\n' +
        'Case #' +
        c.CaseNumber +
        ' has breached its SLA.\n' +
        'Subject  : ' +
        c.Subject +
        '\n' +
        'Account  : ' +
        (c.Account != null ? c.Account.Name : 'N/A') +
        '\n' +
        'Open for : ' +
        hoursOpen +
        ' hour(s)\n' +
        'New Priority: ' +
        c.Priority +
        '\n\n' +
        'Please take immediate action.\n\n' +
        'This is an automated notification from the Case Escalation System.'
    );
    return email;
  }
}
