# Device-twin spec — the on-device budget reporter

The Mac harness measures **quality** (WER, ad-F1) and relative speed, but it cannot measure what
actually gates the product: **ANE throughput, real peak RSS under the jetsam ceiling, and thermal
state** on the floor device. The device twin is a thin iOS app that does exactly that — never
shipped, PRD §9.3/§9.6/§10.

## What it is

A minimal SwiftUI iOS app that links **the same `HarkCore`** and runs `PipelineOrchestrator` on a
bundled sample episode with the **real** engines, reporting per stage:

- **RTF** — audioSeconds / wallClock, per stage and end-to-end.
- **Peak RSS** — `task_info(TASK_VM_INFO)` `phys_footprint` sampled ~4×/s during each stage; the
  number that must stay under `os_proc_available_memory()`.
- **Thermal state** — `ProcessInfo.processInfo.thermalState` sampled per stage, and time-to-`.serious`
  under sustained load (PRD §9.6 budgets for ~55–60% steady-state, not "cooldowns").
- **Battery delta** — `UIDevice.batteryLevel` before/after a full episode, unplugged (feeds the
  §9.5 per-episode budget table).
- **Jetsam survival** — background the app mid-processing and confirm playback + the process survive
  (the "playback never dies to jetsam" criterion).

## Required entitlements (wire from day one — PRD §9.6)

- `com.apple.developer.kernel.increased-memory-limit`
- background audio (`UIBackgroundModes: audio`)
- `com.apple.developer.background-tasks.continued-processing.gpu` (only if a foreground/BGContinued
  GPU path is tested; ANE path doesn't need it)

## Output

Writes a JSON matching `EpisodeRunRecord` (with `thermalNote` + `peakResidentBytesOverall` filled
from real device counters) so device numbers merge into the same decision record as the Mac harness.

## Build note

Reuses `HarkCore` verbatim — the mock engines get replaced by real adapters in
`Sources/HarkCore/Engines/`. This is why the pipeline is a Swift package, not app-target code:
one implementation, measured on both Mac and device.

## Scope

~1 screen, a "Run" button, a results table, a "share JSON" button. Do **not** gold-plate it — it's a
dynamometer, not a product surface.
