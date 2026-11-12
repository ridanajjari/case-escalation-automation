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
}
