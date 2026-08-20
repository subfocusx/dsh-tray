# Manual toast-debug harnesses (internal)

Ad-hoc scripts used while debugging the v1.8.0 "toast hangs on screen forever"
fix. They dot-source `..\..\dsh-tray.ps1` in `DSH_TRAY_TEST_MODE=1` (or with a
real tray `NotifyIcon`/`DebugLog`) to verify that toasts actually fade in, hold,
fade out and auto-dismiss.

They proved the fix and are kept for future toast debugging. They are **not** part
of the automated Pester suite (`..\dsh-tray.tests.ps1`).

- `toast-harness.ps1` .. `toast-harness5.ps1` — successive iterations.
  The final one (`toast-harness5.ps1`) drives a *real* `Close-Toast` (no
  interception) and samples `Opacity`/visibility to confirm the fade-out runs.

- `toast-harness6.ps1` — v1.9.0 stacked-toast harness. Fires real `Show-Toast`
  events (Info/Warning/Error, a rapid same-kind pair, and more than `ToastMax`
  events) inside a message loop and asserts, at the end:
  `maxConcurrent=4` (stack cap enforced, oldest trimmed), `sawInPlace=True`
  (rapid same-kind toast updated in place instead of duplicated), `noOverlap=True`
  (toasts occupy distinct vertical slots), and a final `visible=0` (everything
  auto-dismissed, no zombie toasts).
