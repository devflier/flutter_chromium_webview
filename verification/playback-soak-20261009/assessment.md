# Assessment of the 30-minute live soak

Package ownership and sustained Metal rendering passed. The complete memory
plateau criterion remains unresolved because renderer RSS continued growing.
This result does not establish a Chromium leak or a complete soak pass.

The measured run lasted 1,801.1 seconds, collected 62 snapshots, completed all
nine interaction rounds and returned both processes' resource counters to the
pre-browser idle baseline after disposal. Every interaction paused/resumed and
sought; the sequence also included three resizes, two native window
fullscreen/restore cycles, two widget hide/show cycles and two track changes.

- One browser remained active, with three host and three client IOSurfaces.
- Flutter textures, Mach rights and connections stayed at their active baseline;
  pending requests were zero at every snapshot. Host generation stayed at one.
- 53,973 Metal blits completed; failed blits and software paint callbacks were
  zero. Actual decoded/dropped video frames were not measured.
- Host FDs reached 129 during warm-up and stayed there; lsof rows stayed at 196
  after warm-up. The host plus descendants stayed at nine processes.
- Host RSS was 188.6 MiB at five minutes and 191.5 MiB at completion. In the
  final ten minutes it ranged from 191.3 to 191.6 MiB, with a fitted slope of
  0.019 MiB/min.
- Combined RSS grew from 1,140.1 MiB at five minutes to 1,227.0 MiB in the final
  sample. Its fitted slope after five minutes was 3.663 MiB/min (R² 0.977), and
  its final-ten-minute slope was 3.595 MiB/min. Track changes caused visible
  steps, but growth also occurred between them.

The same process IDs persisted. The two main renderer RSS values grew from
274.5 to 338.9 MiB and from 136.3 to 150.0 MiB between five minutes and the final
sample. GPU RSS grew from 124.8 to 130.2 MiB. These measurements locate most of
the growth in renderers; RSS alone cannot distinguish live allocations,
caches, allocator retention or shared mappings.

Next: investigate renderer allocation/retention before treating the soak as a
complete plateau pass. Instruments Allocations / Leaks is the next diagnostic
step. Renderer/GPU/host crash recovery and release hardening were not exercised
in this run. No architecture tuning was applied.

The test used the mock Keychain option. Fullscreen refers to the native Flutter
window, and hide/show detaches and reattaches the widget. No screenshot was
captured because Computer Use access to the example app was unavailable.

Evidence: [interval summary](README.md), [raw report](soak-30m.json),
[CSV samples](samples.csv), [trend chart](resource-trends.png).
