@IsTest
private class CaseEscalationBatchTest {
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

  @IsTest
  static void testMediumCaseEscalatedAfter48Hours() {
    Case c = createCase('Medium', 50);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [SELECT Priority FROM Case WHERE Id = :c.Id];
    Assert.areEqual(
      'High',
      updated.Priority,
      'Medium case open 50h should be escalated to High'
    );
  }

  @IsTest
  static void testHighCaseEscalatedAfter24Hours() {
    Case c = createCase('High', 26);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [SELECT Priority FROM Case WHERE Id = :c.Id];
    Assert.areEqual(
      'Critical',
      updated.Priority,
      'High case open 26h should be escalated to Critical'
    );
  }

  @IsTest
  static void testMediumCaseNotEscalatedBefore48Hours() {
    Case c = createCase('Medium', 30);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [SELECT Priority FROM Case WHERE Id = :c.Id];
    Assert.areEqual(
      'Medium',
      updated.Priority,
      'Medium case open 30h should NOT be escalated yet'
    );
  }

  @IsTest
  static void testHighCaseNotEscalatedBefore24Hours() {
    Case c = createCase('High', 10);

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [SELECT Priority FROM Case WHERE Id = :c.Id];
    Assert.areEqual(
      'High',
      updated.Priority,
      'High case open 10h should NOT be escalated yet'
    );
  }

  @IsTest
  static void testClosedCaseIsIgnored() {
    Case c = new Case(
      Subject = 'Closed Case',
      Priority = 'High',
      Status = 'Closed',
      Origin = 'Email'
    );
    insert c;
    Test.setCreatedDate(c.Id, DateTime.now().addHours(-48));

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [SELECT Priority FROM Case WHERE Id = :c.Id];
    Assert.areEqual(
      'High',
      updated.Priority,
      'Closed cases should never be escalated'
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

  // Re-reads a case with the fields the batch query selects, so tests can
  // call execute() directly on a known scope.
  private static List<Case> queryForBatch(Id caseId) {
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
      WHERE Id = :caseId
    ];
  }

  @IsTest
  static void testRecentlyEscalatedCaseIsNotEscalatedAgain() {
    // Created long ago, but escalated to High only 2 hours ago: the 24h
    // High threshold is measured from the escalation, not from creation.
    Case c = createCase('High', 100);
    c.Last_Escalated_At__c = DateTime.now().addHours(-2);
    update c;

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [SELECT Priority FROM Case WHERE Id = :c.Id];
    Assert.areEqual(
      'High',
      updated.Priority,
      'A case escalated 2h ago must not be escalated again'
    );
  }

  @IsTest
  static void testNoDoubleEscalationAcrossConsecutiveRuns() {
    Case c = createCase('Medium', 50);
    CaseEscalationBatch batch = new CaseEscalationBatch();

    Test.startTest();
    batch.execute(null, queryForBatch(c.Id));
    Case afterFirstRun = queryForBatch(c.Id)[0];
    // Simulates the next hourly run on the same record.
    batch.execute(null, new List<Case>{ afterFirstRun });
    Test.stopTest();

    Case updated = [
      SELECT Priority, Last_Escalated_At__c
      FROM Case
      WHERE Id = :c.Id
    ];
    Assert.areEqual(
      'High',
      updated.Priority,
      'Second run must not escalate High to the next level immediately'
    );
    Assert.isNotNull(
      updated.Last_Escalated_At__c,
      'Escalation must stamp Last_Escalated_At__c'
    );
  }

  @IsTest
  static void testEscalatesAgainOnceThresholdPassedSinceLastEscalation() {
    Case c = createCase('Medium', 200);
    c.Last_Escalated_At__c = DateTime.now().addHours(-50);
    update c;

    Test.startTest();
    Database.executeBatch(new CaseEscalationBatch(), 200);
    Test.stopTest();

    Case updated = [SELECT Priority FROM Case WHERE Id = :c.Id];
    Assert.areEqual(
      'High',
      updated.Priority,
      'Age since last escalation (50h) exceeds the 48h Medium threshold'
    );
  }
}
