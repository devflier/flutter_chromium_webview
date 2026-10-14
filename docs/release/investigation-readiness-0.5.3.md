# Android and macOS performance readiness — 2026-10-14

Preparation only. PR6, release/0.5.3. No publication,merge,tags or threshold changes.

## Actual gate matrix

| Gate | Result | Evidence | Remaining action |
|---|---|---|---|
| Interface API and package | PASS | Local recheck:analysis,21 tests,zero-warning dry run;example analysis/test PASS. Prior pinned CI PASS | Run default validation on final source before release |
| Interface source/tag strategy | BLOCKED | Existing unpublished tag f202e72 uses old workflow | Explicit owner approval of source/tag strategy |
| Dart/Flutter quality | PASS | Prior full candidate CI38566050605; affected Android run analyzes/tests release SDK | Full required final-source CI after targeted diagnostics |
| Linux native | PASS | Prior full candidate129e585 run38566050605 | Final-source full run NOT RUN |
| Windows native | PASS | Prior full candidate129e585 run38566050605 | Final-source full run NOT RUN |
| Android integrations | PASS | Independent HTML38603598173 and all five suites38604533507; persistent capture complete | Historical failure root cause INCONCLUSIVE; retain monitoring |
| Android release and smoke | PASS | Run38604533507,release APK and touch/keyboard/JS-alert smoke | Graceful shutdown is outside current smoke scope |
| macOS deterministic core | PASS | Prior full candidate129e585:23/23 stages;23 survivor lists empty | New Debug getter requires final-source core validation |
| macOS decoded-media memory | PASS | Prior pinned CI growth20768KiB;new local instrumented302.175s/12 samples growth−133424KiB,cleanup/renderer/shutdown PASS | Instrumented local is supplementary,not clean release acceptance |
| macOS playback performance | INCONCLUSIVE | Correct historical5330/8915 drop fraction;local zero drops;no final-display timestamps | CI timing run38605252039 BLOCKED in runner queue; product criteria pending |
| Historical memory acceptance | FAIL | Original strict RSS failures unchanged | Explicit product release decision; no retroactive pass |
| Physical8GB qualification | BLOCKED | No qualified physical8GB environment | Target hardware and Release whole-app evidence |
| Hosted interface0.1.6 | BLOCKED | Version unpublished/public endpoint404 at prior verification | Separately approved interface publication then actual hosted tests |
| Plugin publication readiness | BLOCKED | Outstanding gates above;no full final-source CI yet | Complete evidence and approvals; do not publish |

## Android finding

Historical38566050605 disconnected at Flutter streamListen after finding the
test isolate, before the test-result channel attached. Post-exit logcat failed255,
so no cause can be established retroactively. Both independent reproduction and
the preceding-suite sequence now PASS on Flutter3.47.4/Dart3.13.3/API36 x86_64.
No production Android defect is confirmed or patched. Retain original FAIL;
repeated success supports isolation,not proof of a Flutter/emulator root cause.

New persistent ADB collection begins before launch and continues after command
exit,independent of VM service. UTC boundaries,process observations,crash buffer,
Activity state,tombstone availability and native-crash Dropbox are retained.
Three wrapper regressions PASS. Invocation38603102853 failed before Flutter
because the emulator action splits shell lines; standalone investigate_android.sh
fixes this demonstrated diagnostic defect. Local API36.1/older-SDK attempt failed
with Activity unavailable while user RUNNING_LOCKED; this is a different failure.

## macOS finding

The arithmetic59.7869% is valid for matched video/context counters. Standards
combine pre-decode and missed-deadline losses in this count. presentedFrames is
Chromium composition submission,not Flutter display scanout. Metal completed
copies are not uniquely video frames. No compatible common frame ID exists
across the recorded stages; no end-to-end latency is inferred.

New opt-in local diagnostics:302.175s,12 samples,0/9021 drops,29.94 compositor FPS
against30fps source;9006 callback timings,22825 Flutter timings. Callback interval
avg33.53ms,p95/p99 50.1ms;Flutter raster avg0.48ms,p99 0.91ms. Zero repeated callback
frame IDs;37 compositor frames without observed callbacks,distinct from media
drops. Native and independent memory/completeness report PASS;survivors empty.
SDK3.44.8/Dart3.12.2,physical16GiB arm64 macOS27.0.1,supplementary Debug only.
Local emulator ran concurrently;no controlled equivalence/overhead claim.

Historical CI used pinned SDK/macOS26.6.2/arm64 but lacks qualified RAM/hypervisor
and per-frame timing. The new CI diagnostic38605252039 is queued without assigned
runner at latest inspection;comparison remains BLOCKED. Do not change renderer
architecture,force GC,select performance thresholds or claim hardware qualification.

## Separate decisions

Interface0.1.6: **NO-GO for publication** until explicit source/tag approval;
relevant API/package preparation checks PASS independently of native diagnostics.

Plugin0.5.3: **NO-GO**: missing hosted interface validation,queued CI performance
comparison,unapproved performance/hardware/memory decisions,historical RSS FAIL
and final-source full validation NOT RUN. A passing Android rerun does not make
all release gates green.

Product requirements/mandatory-versus-supplementary decisions are in
`docs/release/product-acceptance-decision-0.5.3.md`. All numeric budgets remain
UNSET. Original experiments outside the PR and all historical evidence unchanged.

## Commands and sources

- `gh workflow run ci.yml --ref release/0.5.3 -f validation_scope=android-html`
- `gh workflow run ci.yml --ref release/0.5.3 -f validation_scope=android`
- `gh workflow run ci.yml --ref release/0.5.3 -f validation_scope=macos-performance`
- `python3 -m unittest discover -s scripts -p test_android_diagnostics.py -v` (3 PASS)
- `python3 -m unittest discover -s scripts -p test_macos_performance.py -v` (4 PASS)
- diagnostic wrapper regressions7 PASS;release report9 PASS;hosted-origin2 PASS
- `python3 scripts/macos_profile_report.py --report RAW.json --directory NEWDIR --seconds 300`
- `python3 scripts/macos_performance_report.py --report RAW.json --directory NEWDIR`

Exact native commands,SDK/device properties and exit statuses are in raw result
JSON and full logs. Wrong local wrapper invocation and sandbox-denied diagnostics
are preserved separately;corrected commands PASS. No pass inferred from build
success or absent samples. YAML parse,shell syntax,changed Dart formatting and
supplementary fixture analysis PASS.

Counter definitions: https://w3c.github.io/media-playback-quality/ and
https://wicg.github.io/video-rvfc/ . Decode processing interval includes possible
conversion/staging;it is not CPU decode time or end-to-end presentation latency.
