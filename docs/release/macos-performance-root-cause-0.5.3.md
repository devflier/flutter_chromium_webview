# macOS performance attribution — experiment design and source audit

Preparation only. Historical RSS FAIL,physical8GB BLOCKED,long-term leak freedom
unproven;no numeric performance approval,publishing,merge or tags.

## Actual architecture

`macos/Host/main.mm`:CefSettings enables windowless rendering and sandbox;
CefRunMessageLoop drives CEF,then CefShutdown. No external_message_pump or
multi_threaded_message_loop is selected. `HostBrowserClient.mm:CreateBrowser`
sets windowless parent0,shared_texture_enabled=true and windowless_frame_rate60.
No external_begin_frame_enabled or SendExternalBeginFrame scheduling exists.
CEF owns the upstream cadence;Flutter rebuilds do not drive Chromium BeginFrame.

`HostBrowserClient.mm:OnAcceleratedPaint` checks session/surfaces, increments
callback/sequence,wraps CEF IOSurface,creates a destination texture in one of3
surfaces,encodes a blit,commits and synchronously waitsUntilCompleted. Then it
sends generation/sequence/slot in frameReady and advances slot. This synchronous
copy is a candidate bottleneck,not a demonstrated root cause. Existing GPU-time
telemetry resets every60 callbacks;prior getter was not a lifetime cumulative
counter. Historical raw values remain unchanged;new independent opt-in total
and bounded callback/copy-completion records fix the diagnostic interpretation.

`Classes/ChromiumBackend.mm`:frameReady selects the slot and calls
textureFrameAvailable. Surface creation uses a Mach side channel;IPC callbacks
and surface dispatch are marshalled to the app main queue. No per-frame Flutter
acknowledgment is required by the host. `ChromiumTexture.mm:selectSlot` replaces
the active retained buffer under a mutex;`copyPixelBuffer` retains the current
buffer. Intermediate slots can be superseded before Flutter reads them; repeated
reads are not unique video frames. No unbounded downstream frame queue is
created here. OSR has no native CEF parent NSView;visibility/focus behavior must
be measured rather than inferred from Flutter window visibility. No WasHidden
or external BeginFrame calls were found. OnPaint remains a separate software path
and existing no-fallback assertions remain.

## Environment evidence

Historical CI diagnostic attempt2:VirtualMac2,1;Apple M1(Virtual);3 CPUs;
hw.memsize7516192768(7GiB);kern.hv_vmm_present1. Load averages18.69/32.59/16.59
before stage,513 processes and4 stuck;CPU instantaneous snapshot59.25% idle.
This identifies virtualization and load,not sustained per-core saturation or
GPU/video-decode hardware availability. No physical8GB qualification follows.
Local physical16GiB M1Pro/arm64 has no hypervisor;SDK and OS differ from CI.
No direct causal attribution to runner environment is made from these facts.

## Predetermined diagnostic matrix

| Mode | Active CEF page/compositor | Plugin Metal copy | Flutter downstream updates |
|---|---|---|---|
| cef-only | Yes,same accelerated context | No | Omitted after initial surface registration |
| native-only | Yes | Yes | frameReady omitted after initial surface registration |
| full | Yes | Yes | Normal |
| control | Yes | Yes | Normal;additional per-frame timing disabled |

This is a CEF pipeline isolation inside the same harness,not a standalone
Chromium application. Flutter remains alive to create the equivalent viewport,
CDP observer and lifecycle. Initial blank texture registration may be consumed;
steady-state notifications are omitted only in explicitly selected Debug modes.
CEF shared-texture composition/GPU remains active in every mode. No hidden-page,
GPU-disabling,security,profile or scheduler flag is changed. Modes are disabled
without PERFORMANCE_DIAGNOSTICS=true and compiled out of Release.

Two reverse-ordered rounds:cef-only,native-only,full,control,control,full,
native-only,cef-only.60s active and60s disposal each;10s samples;same fixed VP9
640x360,30fps,four-second looping silent source,playback rate1,viewport/DPR.
Each is an independent test with normal startup/shutdown,not a forced runtime
restart within a repeated-session memory acceptance test. Eight short runs are
experimental:release memory reporter explicitly rejects experimentOnly and
nonfull modes. Standard300s/full release gates are unchanged.

Native records use mach_absolute_time converted to milliseconds within host;
JavaScript uses document performance timing;Flutter uses its own frame timings.
No cross-clock subtraction or claimed end-to-end latency. Records bounded4096
between samples;overflow explicit. Texture read/selection counters opt-in and
mutex-protected;read calls do not prove displayed unique frames. Instrumented
control comparisons quantify overhead descriptively without correction factors
or post-hoc significance thresholds. Matching release SDK required for within-CI
experiments;local availableSDK3.44.8 remains supplementary versus pinned3.47.4.

## SDK audit

Cached published direct dependencies:ffigen21 requires Dart>=3.10;plugin platform
interface2.1.8 requires>=3.0;path_provider2.1.6 requires^3.10/Flutter>=3.38.
Interface/example alreadydeclare>=3.12. Plugin>=3.13 had no identified direct
requirement;aligned to>=3.12 after real installed3.12.2 resolution and analysis
PASS. Full tests/dry run still required. This broadens compatibility,does not
change API or pin exact library SDK. Hosted interface0.1.6 validation remains
BLOCKED until separately approved publication. Dependency solver may choose
compatible older transitive versions;minimum patch3.12.0 itself is NOT RUN.
