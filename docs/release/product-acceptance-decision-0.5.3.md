# Product acceptance decisions for macOS 0.5.3

Status: PENDING OWNER APPROVAL. Preparation only; no new release approval or
numeric budget is created by this record. Earlier approval to publish with
limitations does not authorize publishing under the current explicit hold.

| Requirement | Proposed contract | Approval / evidence |
|---|---|---|
| Minimum RAM | Physical8GB; recommended16GB+ | Pending; physical8GB qualification BLOCKED |
| OS | Existing deployment target retained | Compatibility coverage beyond measured OS versions NOT RUN |
| Architecture | Apple Silicon baseline; Intel separately validated | Final supported architecture matrix pending |
| Concurrency | One active video browser; two separately validated | Pending; no multi-browser performance claim |
| Resolution |480p/720p/1080p;4K experimental | Pending; current deterministic fixture640x360 is not that matrix |
| Playback duration |60min plus six repeated sessions | Pending;300s diagnostic is not a substitute |
| Idle behavior | Keep CEF initialized; dispose browser resources/renderer | Pending contract; tested cleanup PASS |
| Shutdown | Zero owned host/helper survivors and restored tracked ownership | Existing mandatory gate, retained |
| Memory | Separate initialized,active,warm-accumulation and shutdown budgets | Numeric budgets UNSET; approval requires whole-app charged footprint and headroom |
| Performance | Sustained compositor rate relative to source, pacing, stalls, CPU/GPU and repeatability | Numeric limits UNSET; require representative hardware and product experience |
| A/V synchronization | Define supported audio workload and sync tolerance | NOT RUN: current fixture silent |
| Final display performance | Measure display presentation if a visible-FPS requirement is approved | INCONCLUSIVE: current instrumentation ends before scanout |

## Mandatory versus supplementary

Mandatory configured plugin gates: release-SDK quality, Linux/Windows/Android
native and release/smoke tests, macOS deterministic core, decoded-media RSS
completeness/ownership/shutdown, actual hosted interface0.1.6 and archive checks.
No diagnostic-scope success replaces a complete default/tag validation run.

Historical strict RSS acceptance remains FAIL; current deterministic memory
PASS is a distinct workload. It cannot remove that unresolved release decision.
Owner must explicitly decide whether current release remains held for historical
acceptance, or a release with precisely documented limitations is acceptable.
That decision is not a test pass and cannot bypass any configured CI failure.

Physical8GB qualification is mandatory before claiming8GB support. Whether
0.5.3 may ship without that claim requires explicit product approval. Long-term
leak freedom and allocator ownership cannot be claimed; additional allocator
profiling is supplementary unless it resolves a concrete unexplained defect.
Real YouTube remains separately reportable and blocked by service challenges
when applicable. No approved numeric performance gate exists yet; release
performance acceptance stays INCONCLUSIVE rather than inheriting memory PASS.

## Required owner action

Approve hardware/workload contract and the release treatment of historical
memory FAIL and unqualified hardware. Then gather clean Release whole-app
measurements on target hardware, repeated runs and appropriate headroom before
choosing/fixing numeric gates. Approve performance criteria before acceptance
runs; do not select limits above observed failures. No thresholds are changed
by this proposal.
