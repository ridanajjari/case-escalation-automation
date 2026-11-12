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
 *   - A Chatter post is added to the Case (also for queue-owned Cases)
 *   - If the owner is an active User, an email is sent to them via
 *     setTargetObjectId (no Activity is logged). Queue-owned Cases get no
 *     email: the Chatter post on the record is their notification.
 *   Notifications are only built for rows whose update succeeded. Email
 *   failures (limits, deliverability turned off) are caught and reported in
 *   the run summary; they never fail the batch.
 *
 * Schedule this job via CaseEscalationScheduler or directly in Setup > Apex Jobs.
 *
 * Sharing: declared `without sharing` on purpose. This is an org-wide SLA job:
 * it must evaluate every open Case regardless of which user scheduled it,
 * otherwise Cases the scheduling user cannot see would silently never escalate.
 * It only updates Case.Priority and Case.Last_Escalated_At__c and posts to the
 * Case feed; it exposes no data back to an interactive user.
 */
public without sharing class CaseEscalationBatch implements Database.Batchable<SObject>, Database.Stateful {
  private static final Long MILLIS_PER_HOUR = 3600000;

  private static final String CASE_QUERY =
    'SELECT Id, CaseNumber, Subject, Priority, Status, CreatedDate, ' +
    'Last_Escalated_At__c, OwnerId, Account.Name ' +
    'FROM Case ' +
    'WHERE IsClosed = false ' +
    'AND Priority IN :fromPriorities ' +
    'AND (Last_Escalated_At__c < :cutoff ' +
    'OR (Last_Escalated_At__c = null AND CreatedDate < :cutoff))';

  // Test-only injection point so tests do not depend on the shipped CMDT rows.
  @TestVisible
  private static List<EscalationRule> rulesOverride;

  private Map<String, EscalationRule> rulesByFromPriority = new Map<String, EscalationRule>();
  private Integer minThresholdHours;
  private Integer escalatedCount = 0;
  @TestVisible
  private List<String> errors = new List<String>();
  // Owner emails handed to Messaging.sendEmail in this transaction, kept so
  // tests can assert on them without depending on the org's email
  // deliverability setting. Static (not serialized with the Stateful batch).
  @TestVisible
  private static List<Messaging.SingleEmailMessage> ownerEmails = new List<Messaging.SingleEmailMessage>();

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
    DateTime cutoff = DateTime.now()
      .addHours(-(minThresholdHours == null ? 0 : minThresholdHours));
    Map<String, Object> binds = new Map<String, Object>{
      'fromPriorities' => rulesByFromPriority.keySet(),
      'cutoff' => cutoff
    };
    // SYSTEM_MODE: this is an org-wide system job (see the sharing note
    // above), so it must not depend on the scheduling user's field-level
    // security on Last_Escalated_At__c.
    return Database.getQueryLocatorWithBinds(
      CASE_QUERY,
      binds,
      AccessLevel.SYSTEM_MODE
    );
  }

  public void execute(Database.BatchableContext bc, List<Case> cases) {
    List<Case> toUpdate = new List<Case>();
    Map<Id, Long> hoursByCaseId = new Map<Id, Long>();

    DateTime now = DateTime.now();
    for (Case c : cases) {
      Long hoursOpen = hoursSinceLastEscalation(c, now);
      String newPriority = getEscalatedPriority(c.Priority, hoursOpen);

      if (newPriority == null)
        continue;

      c.Priority = newPriority;
      c.Last_Escalated_At__c = now;
      toUpdate.add(c);
      hoursByCaseId.put(c.Id, hoursOpen);
    }

    if (toUpdate.isEmpty()) {
      return;
    }

    List<Case> escalated = new List<Case>();
    List<Database.SaveResult> results = Database.update(
      toUpdate,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        escalatedCount++;
        escalated.add(toUpdate[i]);
      } else {
        errors.add(
          'Case ' +
            toUpdate[i].CaseNumber +
            ': ' +
            results[i].getErrors()[0].getMessage()
        );
      }
    }

    // Notifications are built only for rows whose update succeeded, so a
    // failed escalation never produces a Chatter post or an email.
    postToChatter(escalated, hoursByCaseId);
    emailOwners(escalated, hoursByCaseId);
  }

  private void emailOwners(List<Case> escalated, Map<Id, Long> hoursByCaseId) {
    // Queue owners (Group, Id prefix 00G) are skipped on purpose.
    Set<Id> userOwnerIds = new Set<Id>();
    for (Case c : escalated) {
      if (c.OwnerId.getSObjectType() == User.SObjectType) {
        userOwnerIds.add(c.OwnerId);
      }
    }
    if (userOwnerIds.isEmpty()) {
      return;
    }

    // setTargetObjectId fails for inactive users, so only email active ones.
    Map<Id, User> activeOwners = new Map<Id, User>(
      [SELECT Id, Name FROM User WHERE Id IN :userOwnerIds AND IsActive = TRUE]
    );

    List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
    for (Case c : escalated) {
      User owner = activeOwners.get(c.OwnerId);
      if (owner != null) {
        emails.add(buildEmail(c, owner, hoursByCaseId.get(c.Id)));
      }
    }
    ownerEmails.addAll(emails);
    sendSafely(emails, 'Owner notification');
  }

  // Sends without ever throwing: limit or deliverability problems are
  // recorded in the run summary instead of failing the batch chunk.
  private void sendSafely(
    List<Messaging.SingleEmailMessage> emails,
    String purpose
  ) {
    if (emails.isEmpty()) {
      return;
    }
    if (Limits.getEmailInvocations() >= Limits.getLimitEmailInvocations()) {
      errors.add(
        purpose + ' email skipped: per-transaction email limit reached.'
      );
      return;
    }
    try {
      List<Messaging.SendEmailResult> results = Messaging.sendEmail(
        emails,
        false
      );
      for (Messaging.SendEmailResult result : results) {
        if (!result.isSuccess()) {
          errors.add(
            purpose + ' email failed: ' + result.getErrors()[0].getMessage()
          );
        }
      }
    } catch (Exception e) {
      errors.add(purpose + ' email not sent: ' + e.getMessage());
    }
  }

  private void postToChatter(
    List<Case> escalated,
    Map<Id, Long> hoursByCaseId
  ) {
    List<FeedItem> posts = new List<FeedItem>();
    for (Case c : escalated) {
      posts.add(buildChatterPost(c, hoursByCaseId.get(c.Id)));
    }
    if (posts.isEmpty()) {
      return;
    }
    List<Database.SaveResult> results = Database.insert(
      posts,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        errors.add(
          'Chatter post failed for Case ' +
            escalated[i].CaseNumber +
            ': ' +
            results[i].getErrors()[0].getMessage()
        );
      }
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

    // Always visible in the debug log, even if the summary email fails.
    System.debug(LoggingLevel.INFO, summary);

    // Notify the user the batch runs as (the user who scheduled it)
    Messaging.SingleEmailMessage adminEmail = new Messaging.SingleEmailMessage();
    adminEmail.setTargetObjectId(UserInfo.getUserId());
    adminEmail.setSaveAsActivity(false);
    adminEmail.setSubject('Case Escalation Batch — Run Summary');
    adminEmail.setPlainTextBody(summary);
    sendSafely(
      new List<Messaging.SingleEmailMessage>{ adminEmail },
      'Run summary'
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

  @TestVisible
  private static final String NO_SUBJECT = '(no subject)';

  private Messaging.SingleEmailMessage buildEmail(
    Case c,
    User owner,
    Long hoursOpen
  ) {
    Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
    // Emails sent to internal Users via setTargetObjectId do not count
    // against the org's daily single-email limit. saveAsActivity must be
    // false when the target is a User.
    email.setTargetObjectId(owner.Id);
    email.setSaveAsActivity(false);
    email.setSubject('ACTION REQUIRED — SLA Breach on Case #' + c.CaseNumber);
    email.setPlainTextBody(
      'Hi ' +
        owner.Name +
        ',\n\n' +
        'Case #' +
        c.CaseNumber +
        ' has breached its SLA.\n' +
        'Subject  : ' +
        (String.isBlank(c.Subject) ? NO_SUBJECT : c.Subject) +
        '\n' +
        'Account  : ' +
        (c.Account != null ? c.Account.Name : 'N/A') +
        '\n' +
        'Hours since opened or last escalated: ' +
        hoursOpen +
        '\n' +
        'New Priority: ' +
        c.Priority +
        '\n\n' +
        'Please take immediate action.\n\n' +
        'This is an automated notification from the Case Escalation System.'
    );
    return email;
  }
}
