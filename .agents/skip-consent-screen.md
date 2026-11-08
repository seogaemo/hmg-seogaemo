Status: implemented off-car. Owner reports `local.hkmc.factory82` worked on their NEEV KOR 260902 car; HMG-Seogaemo's implementation still needs a car test.

# Startup consent screen

The module skips the driver-safety notice at startup; the driver remains responsible for safe operation. Owner approved the `restore=reboot` class (see AGENTS.md): disabling stops future calls, a full head-unit restart restores the stock notice. No persistent stock file or property changes.

## Reference package

- NEMESIS Manager source defines the Store index `https://portal.xwtk.cloud/nemesis/v1/store/catalog` and descriptors `/store/packages/<id>` (`tmp/hmg_nemesis/Sources/manager/src/com/nemesis/manager/Portal.java`). The host did not resolve when checked (2026-11-03), so no Store descriptor or ZIP was inspected; listing, current artifact and ZIP contents are unverified.
- Likely package: `local.hkmc.factory82`, author `armandodollia`, release 4.2.1, MIT ([repo](https://github.com/armandodollia/nemesis-package-builds), [release](https://github.com/armandodollia/nemesis-package-builds/releases/tag/v4.2.1)); 4.2.1 changes metadata/build only, service stays v4.2. Source descriptor exposes `types=application,service`, a diagnostic shell app, a restarting `apply` service and a preuninstall script; the exact 4.2.1 descriptor and preuninstall script were not accessible.
- Readable [service source](https://raw.githubusercontent.com/armandodollia/nemesis-package-builds/main/packages/hkmc-factory82/svc/watch.sh): polls for startup, screen wake, QuickBoot marker loss and a long resume gap; waits for factory Binder registration and boot readiness; issues `service call com.hkmc.factory 82` with one limited retry for a boot-incomplete exception. Diagnostics in `/data/nemesis/state/local.hkmc.factory82/`, session marker `/data/local/tmp/hkmc.factory82.session`; the diagnostic app exports to USB. No property change, feature XML edit, settings DB key, stock APK patch or stock-file replacement in the readable source (not an audit of the release artifact).
- The package README says only an earlier v4 build was seen dismissing the screen (2022 Kia EV6); 4.2.1 was simulated, not vehicle-tested. Binder transaction 82 is undocumented, a zero Parcel is not proof of dismissal, and uninstall stops future calls without establishing reversal of any persistent effect.

## NEEV KOR evidence and design

- Owner's private Car Report resolves `framework.factory_service.hide_consent_screen` to `IMicomFactoryService.hideConsentScreen()` on `NEEV.KOR.0000.V039.001.260902`. Same point in `core/hookpoints/framework.json` and `maps/hyundai/ioniq5/kor/260902/map.json`; bundled map hashes `/system/framework/framework.odex` as `ffe86fa1540c8dea3b5499b1191bb727`. Owner installed `local.hkmc.factory82` and observed the skip: this shows the reference package's behavior, not ours. HMG-API `docs/vehicle-commands.md` records no known inverse.
- `modules/skip-consent-screen/` declares the core point, `service_calls=com.hkmc.factory:82`, `watch=boot,screen_on`, `restore=reboot`. Apply checks API 19, a car map for the exact `ro.build.product` whose `car.json` names the live framework.odex MD5 (the module holds no MD5 itself), and absence of `local.hkmc.factory82`; no Binder call until the confirmed enable commits desired state. The `watcher` service (separate from boot-only `reconcile`) invokes the module on boot and display off-to-on while enabled. The module waits for boot completion and factory Binder registration, then calls transaction 82 via `sg_service_call` (exact declared pair, 15 s bound, each response/outcome in ledger/export), with one immediate retry for the known boot-incomplete exception.
- Revert sets desired off. If a call happened under the current kernel boot ID, status is `pending-restart head_unit` with `info.desired=off` and the UI keeps the toggle off and explains the restart; after a new boot ID status is off. Effects of the call are undocumented: stock behavior after restart is claimed, not a proven inverse.

## Retry semantics

Boot completion means a successful ledgered factory call, not any attempt. The watcher acknowledges only successful dispatch and keeps a persistent six-attempt budget per kernel boot/event (retry delays 5/10/20/40/60 s). Failed wake delivery stays queued across polls and watcher restarts; a newly observed wake starts a new budget. Failed and successful attempts stay in the ledger. QuickBoot evidence limits: `boot-lifecycle.md` (no reliable same-boot always-awake ignition signal in the private snapshot).

## On-car checks

Also check late Binder registration and transient failure (inspect each ledger attempt; success stops boot retries), that disable and paused stock restore suppress retries, and that a new ignition cycle produces a detectable display transition before claiming QuickBoot coverage.

1. Export the NEMESIS ledger; record product and framework hash. Uninstall `local.hkmc.factory82`, reboot, confirm the stock notice appears.
2. Install a release-signed build; module is off. Enable via `ConfirmDialog`, reboot; notice skipped; inspect the `service_call` ledger row.
3. Screen off/on twice: one call per wake, notice stays skipped. Check service CPU/log growth over a parked session.
4. Disable: toggle off with pending head-unit restart, no calls on wake, stock notice returns after reboot.
5. Re-enable, reboot, uninstall via NEMESIS, reboot: original notice returns. Test a changed framework hash and installed `local.hkmc.factory82` as fail-closed gates. Compare ledgers before/after.
