# CI redesign and release-readiness — 0.1.6 / 0.5.3

2026-10-14. Preparation only. No publication, PR merge or tags are authorized in this task. See the [pre-change audit](ci-audit-0.5.3.md), preserved logs from both attempts of [38554492568](https://github.com/devflier/flutter_chromium_webview/actions/runs/38554492568), and [PR #6](https://github.com/devflier/flutter_chromium_webview/pull/6).

## Root causes and changes

The live-service stages failed on explicit YouTube sign-in/bot challenges. Profiling starts after successful media readiness, so those failed stages collected zero active samples and did not exercise RSS acceptance. Foreground warnings were nonfatal: the native binding/body and eleven integration suites ran. Output directories and diagnostics were writable; artifacts were uploaded. No evidence establishes a profiler permission/startup failure in those attempts.

The old interface publisher depended on every native job. Now `interface_checks` validates API, formatting, analyzer, 21 unit/contract tests, package dry run and runnable example. `quality` verifies the main consumer with the local candidate interface. Interface publication depends only on those two relevant jobs; native jobs skip interface-only tags. Plugin publication retains every native platform gate, separate macOS core and memory gates and public dependency readiness. No continue-on-error masks required failures.

macOS categories:

| Category | Command/job | Meaning |
|---|---|---|
| A/B deterministic native, lifecycle/IPC/input/rendering/recovery | validate_macos.sh core / macos | Eleven native suites, resource churn, release build, native texture ownership and packaged shutdown |
| C sampled memory/media/cleanup | validate_macos.sh memory / macos_memory | Real loopback VP9 decode, 300s RSS samples, CDP video telemetry, strict unchanged <75000 KiB active RSS gate, settled disposal and renderer exit |
| D real external YouTube | validate_macos.sh live / macos_youtube_live | Explicit manual input; errors stay FAIL or proven external BLOCKED, nonzero exit; independently reported, not a publisher dependency |

The synthetic local video is a committed 75-KiB four-second 640×360 VP9 test pattern, served over HTTP loopback and looped. No mocks replace Chromium decode, Metal rendering or native ownership. Its source/codec/size/hash/reproduction command are recorded beside the fixture. This does not prove 1080p/4K, audio output, YouTube service availability or PPPlayer production playback. Existing YouTube adapter and native recovery APIs are unchanged.

Profiling remains accurately described as **sampled CEF RSS/video telemetry**, not Instruments Allocations or a heap/allocator trace. Host and recursive descendants (renderer/GPU/utility) are selected; process rows and role trends remain raw evidence. The required CDP endpoint must contain the test document. Observer start, decoded frames, progressing video/Metal, useful sample count, duration and final artifacts are required. Zero samples or missing/invalid report fail explicitly. The reporter publishes JSON and Markdown; GPU/renderer evidence, settled disposal, renderer absence and ownership recovery are mandatory. PID/command selection remains a legacy limitation (no exact PID start identity); this is not whole-app footprint accounting.

The old settled-disposal loop could skip its final observation after an interval overshoot. It now always captures a final point at/after the requested settle duration. Test assertions save evidence before a failing RSS comparison. No production cleanup sleep, forced GC or host restart was introduced.

The first complete final-point run passed native/strict RSS assertions but the
reporter correctly failed settled renderer absence: shared/global-context
renderer PID97106 remained after63.9s, while owned counters were at baseline and
all processes exited normally at app shutdown. This failure is preserved.
Inspection confirmed the fixture had default requires-gesture=true/global CEF
context, unlike the YouTube adapter's requires-gesture=false/private playback
context (`CustomContext` returns null for the former). The local media fixture
now uses the same private playback setting as the workload being replaced.
No renderer assertion was removed, no production context behavior changed, and
shared-context renderer retention is not claimed as a proven leak. A separate
300s private-context run validates the corrected fixture.

## Dependency and package audit

Both published package exports are explicit. Plugin0.5.3 calls evaluate/cancel JavaScript and uses PointerInput.clickCount and native browserCrash forwarding; published interface0.1.5 lacks these. Interface0.1.6 contains them and new contract tests verify correlation, defaults and native mapping without replacing real Chromium tests. Adding overridable methods with default unimplemented behavior broadens the pre-1.0 API without breaking extending implementations. PPPlayer's existing adapter contract and production native source are unchanged.

Main dependency is ^0.1.6. The plugin SDK constraint remains >=3.13.0; interface/example minimum is >=3.12.0. Current local SDK3.44.8/Dart3.12.2 supports interface testing but cannot validate the plugin release constraints. Native supplementary runs use the pre-existing isolated SDK-adjusted diagnostic copy, not a changed release pubspec. Pinned CI must validate the release with Flutter3.47.4/Dart3.13.3.

Monorepo overrides are development-only and excluded from the archive. The ordinary example pubspec points to its parent main package, not a nonexistent sibling interface. `verify_public_dependencies.sh` temporarily removes/restores both overrides, checks actual hosted0.1.6 in package_config, resolves/analyzes/tests main and example, and dry-runs publication. It does not silently substitute unpublished source. This readiness is separately invocable before publication; currently BLOCKED because public0.1.6 does not exist. No Dart lockfile is tracked for these library packages; the tracked macOS Podfile.lock is unaffected. No generated/native plugin registration or implementation change is required by this release.

## Test matrix (execution record)

| Check | Current result | Evidence / limits |
|---|---|---|
| Interface pub get / analysis / API unit tests | PASS, 21 tests | release-checks/redesign; analysis clean; API, cancellation, click-count and crash-event coverage |
| Interface example get / analysis / test / web build | PASS | Dependency resolution, clean analysis, one test and web build on installed supported SDK |
| Profile/live report regressions | PASS, 9 tests | Missing samples/observer/duration/RSS and renderer survival fail; exact75000 fails; error150 alone is not classified externally blocked |
| Shell syntax / workflow YAML and dependency invariants | PASS | Interface has no native needs; plugin retains memory gate; live is not a publisher dependency |
| New local video native profile | Private-context run in progress; pilot and shared-context completeness FAIL | Pilot: 302.242s, 12 samples, RSS delta −190912 KiB; native fixture passed but reporter rejected last disposal at58.661s. Second run: strict RSS PASS (−108432 KiB) but renderer-exit FAIL. Private-context run uses the matched adapter settings. Older local SDK; supplementary only |
| Plugin release SDK get/analyze/test/dry run | BLOCKED locally | Dart3.12.2 cannot satisfy >=3.13.0; remote candidate CI must run |
| Actual public dependency resolution | BLOCKED | Hosted interface0.1.6 is unpublished |
| Windows/Linux/Android native checks for revised candidate | NOT RUN locally | Unavailable host platforms; CI will report separately |
| Real YouTube | BLOCKED in two preserved attempts | Explicit service authentication challenge; no bypass or repeated retry campaign |
| Historical strict memory acceptance / long-term boundedness / physical8GB | FAIL / not established / BLOCKED | Separate from local media results; no retroactive reclassification |
| Publication / merge / tag actions | NOT RUN | New approval boundary; existing tags unchanged |

Local interface publication dry run from committed source passes with zero
warnings. The earlier dirty-tree dry run failed with an uncommitted-test warning;
it is preserved separately, not labeled passed. Two dependency-origin tests
reject a local path, old0.1.5 and a different host, and accept actual hosted0.1.6
configuration. This is resolution validation, not a fabricated public version.
The registry endpoint itself remains404 until actual publication.

## Decisions and next actions

Interface: API/publication-readiness architecture is independently releasable; **conditional GO for preparation**, no publication GO until final relevant CI and explicit source/tag approval. The existing unpublished interface tag points to the old workflow. The owner must approve a specific retag/new-version strategy; branch fixes cannot modify that old tag's execution.

Plugin: **NO-GO for publication** pending actual hosted interface0.1.6 resolution, final deterministic native/media checks and review of unresolved historical memory acceptance. A new local640×360 workload pass cannot certify the previous YouTube memory failures or establish long-term leak freedom. No threshold change or correction factor is introduced. Physical8GB testing and Release whole-app memory budgets remain outside current evidence.

Required approved sequence: settle interface tag/source strategy; run relevant interface/API consumer checks; approve and publish interface; verify public endpoint/archive; run `bash scripts/verify_public_dependencies.sh`; complete plugin native and strict memory gates; obtain explicit merge/release approval; merge reviewed source and use a matching new plugin tag for the established OIDC publication workflow; inspect publishing job and public archive. Commands and account requirements are in [publishing](../publishing.md). A successful tag push is not publication evidence.
