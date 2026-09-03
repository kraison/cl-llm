---
name: correction
description: A note whose theory was overturned by a measurement
metadata:
  type: project
  modified: 2026-06-28T10:00:00Z
---
The weak-value cache leaks on device, we believe.

**CORRECTION — measured on-device 2026-07-01 (VG's mem-probe `run-cache-split`).** The
weak-value-cache theory is OVERTURNED for on-device: after the dense query + drop + GC,
node-cache count = 0.
