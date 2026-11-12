@IsTest
private class CaseEscalationBatchTest {
  // Tests inject their own rules so they do not depend on the shipped
  // Case_Escalation_Rule__mdt rows, nor on the org having a "Critical"
  // Case priority. Only standard Case.Priority values are used here.
  private static void useTestRules() {
    CaseEscalationBatch.rulesOverride = new List<CaseEscalationBatch.EscalationRule>{
      new CaseEscalationBatch.EscalationRule('Low', 'Medium', 24),
      new CaseEscalationBatch.EscalationRule('Medium', 'High', 48)
    };
  }

  // Creates a case and backdates CreatedDate via Test.setCreatedDate
  private static Case createCase(String priority, Integer hoursAgo) {
    Case c = new Case(
      Subject = 'Test Case — ' + priority,
      Priority = priority,
      Status = 'New',
      Origin = 'Email'
    );
    insert c;
    Test.setCreatedDate(c.Id, DateTime.now().addHours(-hoursAgo));
    return c;
  }

  // Re-reads cases with the fields the batch query selects, so tests can
  // call execute() directly on a known scope. Test data access to
  // Last_Escalated_At__c uses SYSTEM_MODE, like the batch itself, so the
  // tests do not depend on the running user's field-level security.
  private static List<Case> queryForBatch(Set<Id> caseIds) {
    return [
      SELECT
        Id,
        CaseNumber,
        Subject,
        Priority,
        Status,
        CreatedDate,
        Last_Escalated_At__c,
        OwnerId,
        Account.Name
      FROM Case
      WHERE Id IN :caseIds
      WITH SYSTEM_MODE
      ORDER BY CaseNumber
    ];
  }

  private static String priorityOf(Id caseId) {
    return [SELECT Priority FROM Case WHERE Id = :caseId].Priority;
  }

  @IsTest
  static void testMediumCaseEscalatedAfter48Hours() {
    useTestRules();
    Case c = createCase('Medium', 50);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [
      SELECT Priority, Last_Escalated_At__c
      FROM Case
      WHERE Id = :c.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(
      'High',
      updated.Priority,
      'Medium case open 50h should be escalated to High'
    );
    Assert.isNotNull(
      updated.Last_Escalated_At__c,
      'Escalation must stamp Last_Escalated_At__c'
    );
  }

  @IsTest
  static void testLowCaseEscalatedAfter24Hours() {
    useTestRules();
    Case c = createCase('Low', 26);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      'Medium',
      priorityOf(c.Id),
      'Low case open 26h should be escalated to Medium (24h rule)'
    );
  }

  @IsTest
  static void testMediumCaseNotEscalatedBefore48Hours() {
    useTestRules();
    Case c = createCase('Medium', 30);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      'Medium',
      priorityOf(c.Id),
      'Medium case open 30h should NOT be escalated yet'
    );
  }

  @IsTest
  static void testLowCaseNotEscalatedBefore24Hours() {
    useTestRules();
    Case c = createCase('Low', 10);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      'Low',
      priorityOf(c.Id),
      'Low case open 10h should NOT be escalated yet'
    );
  }

  @IsTest
  static void testClosedCaseIsIgnored() {
    useTestRules();
    Case c = new Case(
      Subject = 'Closed Case',
      Priority = 'Medium',
      Status = 'Closed',
      Origin = 'Email'
    );
    insert c;
    Test.setCreatedDate(c.Id, DateTime.now().addHours(-100));

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      'Medium',
      priorityOf(c.Id),
      'Closed cases should never be escalated'
    );
  }

  @IsTest
  static void testRecentlyEscalatedCaseIsNotEscalatedAgain() {
    useTestRules();
    // Created long ago, but escalated to Medium only 2 hours ago: the 48h
    // Medium threshold is measured from the escalation, not from creation.
    Case c = createCase('Medium', 100);
    c.Last_Escalated_At__c = DateTime.now().addHours(-2);
    Database.update(c, AccessLevel.SYSTEM_MODE);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      'Medium',
      priorityOf(c.Id),
      'A case escalated 2h ago must not be escalated again'
    );
  }

  @IsTest
  static void testNoDoubleEscalationAcrossConsecutiveRuns() {
    useTestRules();
    // 50h old: past both the Low (24h) and Medium (48h) thresholds if age
    // were measured from CreatedDate.
    Case c = createCase('Low', 50);
    CaseEscalationBatch batch = new CaseEscalationBatch();

    Test.startTest();
    batch.execute(null, queryForBatch(new Set<Id>{ c.Id }));
    // Simulates the next hourly run on the same record.
    batch.execute(null, queryForBatch(new Set<Id>{ c.Id }));
    Test.stopTest();

    Assert.areEqual(
      'Medium',
      priorityOf(c.Id),
      'Second run must not escalate Medium to High right after Low to Medium'
    );
  }

  @IsTest
  static void testEscalatesAgainOnceThresholdPassedSinceLastEscalation() {
    useTestRules();
    Case c = createCase('Medium', 200);
    c.Last_Escalated_At__c = DateTime.now().addHours(-50);
    Database.update(c, AccessLevel.SYSTEM_MODE);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Assert.areEqual(
      'High',
      priorityOf(c.Id),
      'Age since last escalation (50h) exceeds the 48h Medium threshold'
    );
  }

  @IsTest
  static void testRuleWithInvalidTargetPriorityIsSkipped() {
    CaseEscalationBatch.rulesOverride = new List<CaseEscalationBatch.EscalationRule>{
      new CaseEscalationBatch.EscalationRule('Medium', 'Not A Real Priority', 1)
    };
    Case c = createCase('Medium', 50);

    Test.startTest();
    CaseEscalationBatch batch = new CaseEscalationBatch();
    batch.execute(null, queryForBatch(new Set<Id>{ c.Id }));
    Test.stopTest();

    Assert.areEqual(
      'Medium',
      priorityOf(c.Id),
      'A rule targeting a non-existent priority must not touch the case'
    );
    Assert.areEqual(1, batch.errors.size(), 'Skipped rule must be reported');
    Assert.isTrue(
      batch.errors[0].contains('Not A Real Priority'),
      'Error should name the invalid priority: ' + batch.errors[0]
    );
  }

  @IsTest
  static void testChatterPostCreatedOnEscalation() {
    useTestRules();
    Case escalatedCase = createCase('Medium', 50);
    Case untouchedCase = createCase('Medium', 10);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    List<FeedItem> posts = [
      SELECT ParentId, Body
      FROM FeedItem
      WHERE
        ParentId IN :new Set<Id>{ escalatedCase.Id, untouchedCase.Id }
        AND Type = 'TextPost'
    ];
    Assert.areEqual(1, posts.size(), 'Only the escalated case gets a post');
    Assert.areEqual(escalatedCase.Id, posts[0].ParentId);
    Assert.isTrue(
      posts[0].Body.contains('Priority escalated to High'),
      'Post should name the new priority: ' + posts[0].Body
    );
  }

  @IsTest
  static void testPartialFailureNotifiesOnlySuccessfulRows() {
    useTestRules();
    Case ok1 = createCase('Medium', 50);
    Case ok2 = createCase('Medium', 50);
    Case failing = createCase('Medium', 50);
    Set<Id> allIds = new Set<Id>{ ok1.Id, ok2.Id, failing.Id };
    List<Case> scope = queryForBatch(allIds);
    String failingNumber = [SELECT CaseNumber FROM Case WHERE Id = :failing.Id]
    .CaseNumber;

    // Deleting a row after it was queried makes its update fail
    // (ENTITY_IS_DELETED) while the other rows in the scope succeed.
    delete failing;

    CaseEscalationBatch batch = new CaseEscalationBatch();
    Test.startTest();
    batch.execute(null, scope);
    Test.stopTest();

    Assert.areEqual('High', priorityOf(ok1.Id), 'ok1 should be escalated');
    Assert.areEqual('High', priorityOf(ok2.Id), 'ok2 should be escalated');

    List<FeedItem> posts = [
      SELECT ParentId
      FROM FeedItem
      WHERE ParentId IN :allIds AND Type = 'TextPost'
    ];
    Assert.areEqual(2, posts.size(), 'Only successful rows get a post');
    for (FeedItem post : posts) {
      Assert.areNotEqual(failing.Id, post.ParentId);
    }

    // Only update failures start with 'Case '; email delivery problems in
    // orgs with deliverability turned off are reported separately.
    List<String> updateErrors = new List<String>();
    for (String error : batch.errors) {
      if (error.startsWith('Case ')) {
        updateErrors.add(error);
      }
    }
    Assert.areEqual(1, updateErrors.size(), 'One update failure expected');
    Assert.isTrue(
      updateErrors[0].contains(failingNumber),
      'Error should name the failed case: ' + updateErrors[0]
    );

    Assert.areEqual(
      2,
      CaseEscalationBatch.ownerEmails.size(),
      'Only successful rows get an owner email'
    );
    for (Messaging.SingleEmailMessage email : CaseEscalationBatch.ownerEmails) {
      Assert.isFalse(
        email.getSubject().contains(failingNumber),
        'The failed case must not be emailed'
      );
    }
  }

  @IsTest
  static void testOwnerEmailTargetsUserAndHandlesNullSubject() {
    useTestRules();
    Case c = new Case(Priority = 'Medium', Status = 'New', Origin = 'Email');
    insert c;
    Test.setCreatedDate(c.Id, DateTime.now().addHours(-50));
    List<Case> scope = queryForBatch(new Set<Id>{ c.Id });

    Test.startTest();
    new CaseEscalationBatch().execute(null, scope);
    Test.stopTest();

    Assert.areEqual(
      1,
      CaseEscalationBatch.ownerEmails.size(),
      'One email for the user-owned case'
    );
    Messaging.SingleEmailMessage email = CaseEscalationBatch.ownerEmails[0];
    Assert.areEqual(
      scope[0].OwnerId,
      email.getTargetObjectId(),
      'Email must target the owner User Id'
    );
    Assert.isFalse(
      email.getSaveAsActivity(),
      'User-targeted email must not be saved as activity'
    );
    Assert.isTrue(
      email.getSubject().contains(scope[0].CaseNumber),
      'Subject should name the case'
    );
    Assert.isTrue(
      email.getPlainTextBody().contains(CaseEscalationBatch.NO_SUBJECT),
      'Blank Subject should fall back to placeholder text'
    );
  }

  @IsTest
  static void testQueueOwnedCaseGetsChatterPostButNoEmail() {
    useTestRules();
    Group queue = new Group(Name = 'Escalation Test Queue', Type = 'Queue');
    // Setup objects in their own context to avoid MIXED_DML_OPERATION.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert queue;
      insert new QueueSobject(QueueId = queue.Id, SobjectType = 'Case');
    }
    Case c = new Case(
      Subject = 'Queue owned',
      Priority = 'Medium',
      Status = 'New',
      Origin = 'Email',
      OwnerId = queue.Id
    );
    insert c;
    Test.setCreatedDate(c.Id, DateTime.now().addHours(-50));

    Test.startTest();
    new CaseEscalationBatch().execute(null, queryForBatch(new Set<Id>{ c.Id }));
    Test.stopTest();

    Assert.areEqual('High', priorityOf(c.Id), 'Queue-owned case escalates');
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM FeedItem
        WHERE ParentId = :c.Id AND Type = 'TextPost'
      ],
      'Queue-owned case still gets the Chatter post'
    );
    Assert.isTrue(
      CaseEscalationBatch.ownerEmails.isEmpty(),
      'Queues are not emailed'
    );
  }

  @IsTest
  static void testSchedulerIsScheduledHourly() {
    String jobName = 'Test Case Escalation';
    String cronExp = '0 0 * * * ?';

    Test.startTest();
    Id jobId = System.schedule(jobName, cronExp, new CaseEscalationScheduler());
    Test.stopTest();

    CronTrigger scheduled = [
      SELECT CronExpression, CronJobDetail.Name, State
      FROM CronTrigger
      WHERE Id = :jobId
    ];
    Assert.areEqual(cronExp, scheduled.CronExpression, 'Hourly cron expected');
    Assert.areEqual(jobName, scheduled.CronJobDetail.Name, 'Job name mismatch');
  }

  @IsTest
  static void testBulkEscalation() {
    useTestRules();
    List<Case> cases = new List<Case>();
    for (Integer i = 0; i < 200; i++) {
      cases.add(
        new Case(
          Subject = 'Bulk Case ' + i,
          Priority = 'Medium',
          Status = 'New',
          Origin = 'Email'
        )
      );
    }
    insert cases;

    for (Case c : cases) {
      Test.setCreatedDate(c.Id, DateTime.now().addHours(-50));
    }

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    List<Case> updated = [SELECT Priority FROM Case WHERE Id IN :cases];
    for (Case c : updated) {
      Assert.areEqual(
        'High',
        c.Priority,
        'All bulk Medium cases should be escalated to High'
      );
    }
  }
}
