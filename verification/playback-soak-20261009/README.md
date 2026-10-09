# Playback soak results

Live rendering/resource gates: **passed**. Duration: 30.02 minutes.

| Checkpoint | Actual minute | Host RSS MiB | Host + helpers RSS MiB | Numeric FDs | Processes | Completed Metal frames | Software callbacks |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 min | 0.01 | 151.9 | 1083.6 | 124 | 9 | 87 | 0 |
| 5 min | 5.02 | 188.6 | 1140.1 | 129 | 9 | 9138 | 0 |
| 15 min | 15.11 | 191.4 | 1178.9 | 129 | 9 | 27227 | 0 |
| 30 min | 30.01 | 191.5 | 1222.2 | 129 | 9 | 53956 | 0 |

## Trends

| Metric | Slope after 5 min | Slope in final 10 min | Final 10 min range |
| --- | --- | --- | --- |
| hostRssMiB | 0.120/min | 0.019/min | 191.3–191.6 |
| totalRssMiB | 3.663/min | 3.595/min | 1196.2–1227.0 |
| numericDescriptors | 0.000/min | 0.000/min | 129.0–129.0 |
| processCount | 0.000/min | 0.000/min | 9.0–9.0 |

Slopes are least-squares fits to interval samples. They are measurements, not automatic proof of a leak or a plateau. Correlate changes with the interaction timeline and caches.

Completed interactions: 9. Post-disposal return to idle baseline: True.

Actual decoded/dropped video frames remain unmeasured. Completed Metal blits and paint callbacks are separate metrics. The live gate verifies Metal progress and no additional software callbacks after startup.

The data includes only the measured host and its descendants. Numeric FDs differ from lsof row count, which also includes mappings and nonnumeric handles. Aggregate RSS may double-count shared pages across processes.

Fullscreen exercises the native Flutter window; hide/show detaches and reattaches the widget. No screenshot was captured because Computer Use access to the example app was unavailable. No architecture tuning was applied.
