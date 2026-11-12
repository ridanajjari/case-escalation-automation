# Case Escalation Automation — Salesforce

A scheduled Apex batch that raises the priority of open cases that have breached an SLA threshold, posts a Chatter alert on the case and emails the case owner.

---

## Business Problem

Support teams miss SLAs when cases sit open too long without being noticed. Managers have no visibility until a customer complains. This job runs on a schedule and escalates cases that have waited too long at their current priority.

---

## How It Works

```
Every hour (scheduled)
        │
        ▼
CaseEscalationBatch loads active Case_Escalation_Rule__mdt rows
and queries open cases at a "From" priority
        │
        │  age = hours since Last_Escalated_At__c
        │        (or since CreatedDate if never escalated)
        │
        ├─ Medium, age >= 48 hours ──► Priority = High
        │
        └─ High,   age >= 24 hours ──► Priority = Critical (see prerequisite)
                │
                ▼
        ┌────────────────────────────────────────────────┐
        │ 1. Update Priority + stamp Last_Escalated_At__c │
        │    (Database.update with allOrNone = false)     │
        │ 2. For rows that saved successfully only:       │
        │    - post a Chatter alert on the case           │
        │    - email the owner if it is an active User    │
        │ 3. Email a run summary (counts + errors) to the │
        │    user the job runs as                         │
        └────────────────────────────────────────────────┘
```

Because age is measured from the last escalation, a Medium case escalated to High gets a fresh 24 hours at High. It is not escalated again to Critical on the next hourly run.

---

## SLA Rules (Custom Metadata)

Rules live in the `Case_Escalation_Rule__mdt` Custom Metadata Type, so thresholds and mappings can be changed in Setup without a code change.

| Record             | From Priority | Threshold Hours | To Priority | Active |
| ------------------ | ------------- | --------------- | ----------- | ------ |
| `Medium_To_High`   | Medium        | 48              | High        | ✔      |
| `High_To_Critical` | High          | 24              | Critical    | ✔      |

When the batch starts, it skips (and lists in the run summary) any active rule that:

- targets a value that is not an active `Case.Priority` picklist value,
- has a missing or zero threshold, or
- duplicates another active rule's From Priority.

### Prerequisite: the `Critical` priority

`Critical` is **not** a standard Case priority (the defaults are High, Medium and Low). Add it before relying on the `High_To_Critical` rule:

Setup → Object Manager → Case → Fields & Relationships → Priority → Values → **New** → `Critical`.

Without it, the batch skips the `High_To_Critical` rule and reports it in the run summary. It does not fail every High-priority update. This repo intentionally does **not** ship `StandardValueSet` metadata for `CasePriority`: deploying that file replaces the org's whole priority value set, which is risky in an org that already customised it.

---

## Notifications

- **Chatter**: one post per successfully escalated case. Posts are inserted with `allOrNone = false`, and failures are listed in the run summary.
- **Owner email**: sent with `setTargetObjectId(ownerId)` and `setSaveAsActivity(false)`. It is sent only when the owner is an active User.
  - Queue-owned cases (owner Id prefix `00G`) get no email; the Chatter post on the record is their notification.
  - A blank Subject is shown as `(no subject)`.
- **Email failures never fail the batch**: the batch checks the per-transaction email invocation limit first and catches send errors (for example, deliverability set to "System email only"). Both cases are recorded in the run summary, which is also written to the debug log.

---

## Design Notes and Known Limits

- **Sharing**: `CaseEscalationBatch` is `without sharing` on purpose. An org-wide SLA job must see every open case, whoever scheduled it. `CaseEscalationScheduler` is `with sharing`: it only enqueues the batch.
- **System mode**: the batch query and its Case/FeedItem DML run with `AccessLevel.SYSTEM_MODE`, so the job does not depend on the scheduling user's field-level security on `Last_Escalated_At__c`. The permission set gives admins read access to the field.
- **Query selectivity**: SOQL cannot express `COALESCE(Last_Escalated_At__c, CreatedDate)`, so `start()` pre-filters with:
  - `IsClosed = false`
  - `Priority IN (active From priorities)`
  - `(Last_Escalated_At__c < cutoff OR (Last_Escalated_At__c = null AND CreatedDate < cutoff))`, where the cutoff is the smallest threshold.

  The exact per-rule threshold is then checked in Apex. Because of the `OR` across a non-indexed custom field, this query is not selective. A batch `QueryLocator` handles that, but on a very large Case table it is a full scan. A custom index on `Last_Escalated_At__c` would be the next step.

- **Calendar hours**, not business hours.
- A **manual priority change** does not reset `Last_Escalated_At__c`.

---

## Why not Escalation Rules / Entitlements?

- **Standard Case Escalation Rules** can reassign a case and notify people after a time-based age threshold. Their escalation actions **cannot update fields** such as Priority, and only one escalation rule can be active at a time.
- **Entitlement Management (Entitlement Processes + Milestones)** is the platform's full SLA model: business hours, milestone timers, and success/warning/violation actions, including field updates. For a real support org with contractual SLAs, it is what I would evaluate first. It needs entitlements set up per account or contact, plus process configuration and licensing.
- **This project** keeps the escalation chain in a small, testable Apex batch driven by Custom Metadata. It exists to demonstrate batch/schedulable Apex, partial-success DML and notification handling, not to replace Entitlements.

---

## Project Structure

```
force-app/main/default/
├── classes/
│   ├── CaseEscalationBatch.cls        # Batch logic
│   ├── CaseEscalationScheduler.cls    # Schedulable wrapper
│   └── CaseEscalationBatchTest.cls    # 15 test methods
├── customMetadata/                    # Shipped Case_Escalation_Rule records
├── objects/
│   ├── Case/fields/Last_Escalated_At__c.field-meta.xml
│   └── Case_Escalation_Rule__mdt/     # CMDT type + fields
└── permissionsets/
    └── Case_Escalation_Automation.permissionset-meta.xml
```

---

## Deployment

### Prerequisites

- Salesforce CLI (`sf`) installed
- An org that can run Apex: Developer Edition, sandbox or scratch org
- Node.js, only for the lint and format scripts

### Steps

```bash
# 1. Clone the repo
git clone https://github.com/ridanajjari/case-escalation-automation.git
cd case-escalation-automation

# 2. Authenticate to your org
sf org login web --alias my-org

# 3. Deploy
sf project deploy start --source-dir force-app --target-org my-org --wait 30

# 4. Assign the permission set to the admin who schedules the job
sf org assign permset --name Case_Escalation_Automation --target-org my-org

# 5. Run the tests
sf apex run test --target-org my-org --class-names CaseEscalationBatchTest --code-coverage --result-format human --wait 30
```

Optional: add the `Critical` priority value (see the prerequisite above).

### Schedule the batch (run in Anonymous Apex)

```apex
// Runs every hour at the top of the hour
System.schedule(
  'Case Escalation - Hourly',
  '0 0 * * * ?',
  new CaseEscalationScheduler()
);
```

### Or run immediately

```apex
Database.executeBatch(new CaseEscalationBatch(), 200);
```

### Local checks

```bash
npm install
npm run lint
npm run prettier:verify
```

---

## Test Methods

The tests inject their own rules through a `@TestVisible` override and use only standard priorities (Low → Medium at 24h, Medium → High at 48h). They do not depend on the shipped metadata records or on `Critical` existing in the org.

| Test Method                                                | Scenario                                                                             |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `testMediumCaseEscalatedAfter48Hours`                      | Medium case open 50h → High, `Last_Escalated_At__c` stamped                          |
| `testLowCaseEscalatedAfter24Hours`                         | Low case open 26h → Medium                                                           |
| `testMediumCaseNotEscalatedBefore48Hours`                  | Medium case open 30h → no change                                                     |
| `testLowCaseNotEscalatedBefore24Hours`                     | Low case open 10h → no change                                                        |
| `testClosedCaseIsIgnored`                                  | Closed cases are never touched                                                       |
| `testRecentlyEscalatedCaseIsNotEscalatedAgain`             | Old case escalated 2h ago → no change                                                |
| `testNoDoubleEscalationAcrossConsecutiveRuns`              | Two consecutive runs → escalated one level only                                      |
| `testEscalatesAgainOnceThresholdPassedSinceLastEscalation` | Threshold passed since last escalation → escalated                                   |
| `testRuleWithInvalidTargetPriorityIsSkipped`               | Rule targeting a non-existent priority → case untouched, error reported              |
| `testChatterPostCreatedOnEscalation`                       | Chatter post only on the escalated case, naming the new priority                     |
| `testPartialFailureNotifiesOnlySuccessfulRows`             | One row fails to update → other rows escalated; no post or email for the failed row  |
| `testOwnerEmailTargetsUserAndHandlesNullSubject`           | Email targets the owner User Id, `saveAsActivity = false`, blank Subject placeholder |
| `testQueueOwnedCaseGetsChatterPostButNoEmail`              | Queue-owned case → escalated + Chatter post, no email                                |
| `testSchedulerIsScheduledHourly`                           | `CronTrigger` has the expected cron expression and job name                          |
| `testBulkEscalation`                                       | 200 cases processed in one batch                                                     |

---

## Testing

Status as of 2026-11-12:

- ✅ Deployed to a Developer Edition org at API 68.0 (2026-11-12): all classes, the `Last_Escalated_At__c` field, the Custom Metadata Type with its 2 records, and the permission set.
- ✅ 15/15 Apex tests passing (`CaseEscalationBatchTest`). Coverage as reported by `sf apex run test --code-coverage`:
  - `CaseEscalationBatch`: 88%
  - `CaseEscalationScheduler`: 100%

  The 25 uncovered lines are error and guard branches the tests do not trigger: duplicate-rule and invalid-threshold handling in rule loading, email-limit and email-send failure handling, Chatter insert failures, two empty-list early returns, and the null branch of the threshold conversion.

- ✅ Offline checks passing: `npm run prettier:verify` (also parses the Apex), `npm run lint`, and all `*-meta.xml` files are well-formed XML.
- Not exercised end to end: the shipped `High_To_Critical` rule. The test org has no `Critical` priority, and the tests use injected rules with standard priorities only.

---

## Key Salesforce Concepts Demonstrated

- `Database.Batchable` + `Database.Stateful` for large data volume processing
- `Schedulable` interface for recurring execution
- Custom Metadata Types for admin-configurable rules
- `Database.update(..., false)` with notifications driven by `SaveResult`
- Chatter `FeedItem` posting and `Messaging.SingleEmailMessage` with `setTargetObjectId`
- `Test.setCreatedDate()`, `@TestVisible` dependency injection and `CronTrigger` assertions in tests

---

## Author

**Rida Najjari** — Salesforce Consultant, Developer & Administrator

4x Salesforce Certified: Platform Administrator · Platform App Builder · Platform Developer I · Associate

- LinkedIn: [linkedin.com/in/rida-najjari](https://www.linkedin.com/in/rida-najjari)
- GitHub: [github.com/ridanajjari](https://github.com/ridanajjari)
