/**
 * Schedulable wrapper for CaseEscalationBatch.
 *
 * To schedule from Anonymous Apex (runs every hour):
 *
 *   CaseEscalationScheduler job = new CaseEscalationScheduler();
 *   System.schedule('Case Escalation - Hourly', '0 0 * * * ?', job);
 *
 * To run immediately for testing:
 *
 *   Database.executeBatch(new CaseEscalationBatch(), 200);
 */
global class CaseEscalationScheduler implements Schedulable {
  global void execute(SchedulableContext sc) {
    Database.executeBatch(new CaseEscalationBatch(), 200);
  }
}
