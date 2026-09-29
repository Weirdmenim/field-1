# Phase 11 Risk Register

| ID | Risk | Severity | Control |
|---|---|---:|---|
| P11-R01 | Recorded PASS disagrees with underlying evidence | Critical | Machine evidence audit; release status promotion only after audit PASS |
| P11-R02 | Release harness works only on one developer machine | Critical | Remove hard-coded paths; canonical CI/local command; supported runtime matrix |
| P11-R03 | Stale files from previous runs make a failed run look green | Critical | Fresh run directory; preserve prior runs separately; require run-scoped manifest |
| P11-R04 | Fixing test harness accidentally weakens inventory invariants | Critical | Invariants verifier remains mandatory; no stock-authority redesign in Phase 11 |
| P11-R05 | Browser proof is flaky and gets bypassed | High | Deterministic context selection, diagnostic artifacts, retry only for infrastructure startup—not failed assertions |
| P11-R06 | Existing 186 closure statuses are blindly reopened or blindly trusted | High | Keep historical matrix record; distinguish repository record from program baseline approval |
| P11-R07 | Future ERP changes regress Phase 1–10 behavior | Critical | Phase 11 sealed baseline becomes mandatory regression gate for all later phases |
| P11-R08 | Backups exist but restore is untested | High | Automated restore smoke proof before phase exit |
| P11-R09 | Tenant isolation assumptions fail under new modules | Critical | Negative cross-tenant tests become permanent suite |
| P11-R10 | Test evidence depends on chat/manual interpretation | High | Self-contained release manifest and machine-audited evidence bundle |
