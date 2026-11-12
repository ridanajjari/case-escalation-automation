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
 *
 * Sharing: `with sharing` because this class reads no data itself; it only
 * enqueues the batch. Record visibility for the escalation is decided by
 * CaseEscalationBatch's own sharing declaration.
 */
public with sharing class CaseEscalationScheduler implements Schedulable {
  public void execute(SchedulableContext sc) {
    Database.executeBatch(new CaseEscalationBatch(), 200);
  }
}
