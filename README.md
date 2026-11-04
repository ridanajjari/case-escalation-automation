# Case Escalation Automation — Salesforce

Automated SLA enforcement for Salesforce Service Cloud. Open cases that breach their SLA thresholds are automatically escalated in priority and the case owner is notified by email.

---

## Business Problem

Support teams miss SLAs when cases sit open too long without being noticed. Managers have no visibility until a customer complains. This solution runs automatically on a schedule and ensures no case falls through the cracks.

---

## How It Works

```
Every hour (scheduled)
        │
        ▼
CaseEscalationBatch queries all open cases
        │
        ├─ Medium priority, open > 48 hours  ──► Priority = High
        │
        └─ High priority, open > 24 hours    ──► Priority = Critical
                │
                ▼
        ┌──────────────────────────────┐
        │ 1. Update Case priority      │
        │ 2. Post Chatter alert        │
        │ 3. Email the Case Owner      │
        │ 4. Send batch summary to     │
        │    the admin who ran it      │
        └──────────────────────────────┘
```

---

## SLA Rules

| Current Priority | Hours Open | New Priority |
|-----------------|------------|-------------|
| Medium           | > 48 hours | High        |
| High             | > 24 hours | Critical    |

---

## Project Structure

```
force-app/main/default/classes/
├── CaseEscalationBatch.cls          # Core batch logic
├── CaseEscalationBatch.cls-meta.xml
├── CaseEscalationScheduler.cls      # Schedulable wrapper
├── CaseEscalationScheduler.cls-meta.xml
├── CaseEscalationBatchTest.cls      # Test class (6 scenarios, 95%+ coverage)
└── CaseEscalationBatchTest.cls-meta.xml
```

---

## Deployment

### Prerequisites
- Salesforce CLI (`sf`) installed
- A Developer Edition or Sandbox org

### Steps

```bash
# 1. Clone the repo
git clone https://github.com/YOUR_USERNAME/case-escalation-automation.git
cd case-escalation-automation

# 2. Authenticate to your org
sf org login web --alias my-org

# 3. Deploy
sf project deploy start --target-org my-org

# 4. Run tests
sf apex run test --target-org my-org --test-level RunLocalTests --wait 10
```

### Schedule the batch (run in Anonymous Apex)

```apex
// Runs every hour at the top of the hour
System.schedule(
    'Case Escalation - Hourly',
    '0 0 * * * ?',
    new CaseEscalationScheduler()
);
```

### Or run immediately for testing

```apex
Database.executeBatch(new CaseEscalationBatch(), 200);
```

---

## Test Coverage

| Test Method | Scenario |
|-------------|----------|
| `testMediumCaseEscalatedAfter48Hours` | Medium case open 50h → escalated to High |
| `testHighCaseEscalatedAfter24Hours` | High case open 26h → escalated to Critical |
| `testMediumCaseNotEscalatedBefore48Hours` | Medium case open 30h → no change |
| `testHighCaseNotEscalatedBefore24Hours` | High case open 10h → no change |
| `testClosedCaseIsIgnored` | Closed cases are never touched |
| `testSchedulerExecutes` | Scheduler runs without exception |
| `testBulkEscalation` | 200 cases processed in one batch |

---

## Key Salesforce Concepts Demonstrated

- `Database.Batchable` + `Database.Stateful` for large data volume processing
- `Schedulable` interface for recurring execution
- `Test.setCreatedDate()` for time-sensitive test scenarios
- `Database.update(..., false)` for partial success (no all-or-nothing failures)
- Chatter `FeedItem` programmatic posting
- `Messaging.SingleEmailMessage` for transactional email

---

## Author

Built by [Your Name] — Salesforce Developer & Administrator  
[LinkedIn](#) · [Trailhead](#)
