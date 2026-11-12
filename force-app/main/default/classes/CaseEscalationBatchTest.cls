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
  // call execute() directly on a known scope.
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
        Owner.Email,
        Owner.Name,
        Account.Name
      FROM Case
      WHERE Id IN :caseIds
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
    update c;

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
    update c;

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
  static void testSchedulerExecutes() {
    Test.startTest();
    CaseEscalationScheduler scheduler = new CaseEscalationScheduler();
    String cronExp = '0 0 * * * ?';
    System.schedule('Test Case Escalation', cronExp, scheduler);
    Test.stopTest();
    // No assertion needed — just verifying no exception is thrown
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
