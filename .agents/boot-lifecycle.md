Status: current — implemented off-car; on-car checks at the end.

# Boot lifecycle

Upstream references are in the shared checkout's gitignored `tmp/hmg_nemesis`, not copied here.

## Service model

- NEMESIS `Sources/native/svc.c:136-207` forks shell services, creates a session, disconnects inherited descriptors; only
  `once` waits for exit. Startup loop (`:284-292`) skips `once`; supervisor loop (`:303-335`) skips completed `background`
  services. So `reconcile` is `background`: one asynchronous start per service-manager startup unless alive, no restart after
  completion. Package install still starts every registered service (`pkg.c:595-604`, called at `:713-714`), keeping
  desired-on reapply after USB install/update.
- Framework readiness = `sys.boot_completed` only (`util.c:709-715`); reconcile also checks `pm path android` before
  interpreting an absent app as removal.
- `reconcile` (`svc/reconcile.sh`, boot only) vs `watcher` (`svc/watcher.sh`, `mode=restart`): the watcher only dispatches
  fixed `watch` events for modules whose desired state is on, never apply/revert.
- Readiness retries back off 2, 4, 8, 16, then 30 s (cap, no permanent timeout). OTA health is finite: six waits, then fail.
- Desired-on modules are reapplied on the install/update path.

## Automatic intent recheck

After acquiring `operation.lock`, reconcile re-reads desired state and APK presence before journaling or running module code.
Automatic apply needs desired on and an installed APK; automatic reverse revert needs desired not on or a missing APK. If that
no longer holds it returns success with `state=not-implemented`, `restart=none`, `info.skipped=true`, current `info.desired`,
`detail=Automatic module intent changed`. This receipt describes skipped work, not module state; it does not rewrite desired
state, invalidate stock receipts or invoke the module. Explicit user calls keep their confirmed intent. Confirmed app plans run
their reviewed steps without replanning.

## Map verification and deferred application

- Reconcile checks the packaged nonempty `hookpoints.required/<id>` before applying desired-on modules. It needs map status
  `state=on`, else tries fixed `map verify` once per pass. Unverified modules and their transitive dependents stay desired on
  and are deferred; independent modules continue. Pause, APK presence, desired state and selected payload are re-checked
  after verification. Reverse restore discovery includes every restore-material class, including directory-only partial applies.
- The NEMESIS once service and OTA health return after the initial bounded pass; map deferral is not a health failure (real
  module failures still fail).
- One private, deduplicated detached worker retries deferred IDs every 30 s: ignores HUP, disconnects stdio via internal exec
  redirection, `cd /`, clears the OTA health flag. Its root-owned `reconcile-retry` marker holds the child PID, launcher token and
  canonical payload identity. Stale/interrupted claims are reclaimed after ≤5 one-second publication polls; a changed payload may
  replace an old claim (the old worker checks exact ownership before applying and cannot remove the replacement marker). Workers
  end on stock pause, missing APK, payload selection change or no remaining desired work. No public root verb added.
- Existing map verification retries stay detached and re-read desired state, stock pause, app presence and payload selection
  before applying. Each pass costs two JVMs, so waits back off 30, 60, 120, then 300 s and stop after eight passes per boot
  (logged exhausted); a later boot starts fresh.
- Mapper `status` is bounded to 15 s, `verify` to 30 s (plus ≤9 s operation-lock wait); timeout/signal terminates and reaps the
  actual `app_process` child and cleans lock/scratch state. A confirmed full `run` is bounded to 590 s, inside the app's 600 s
  root-call window. Later successful verification is observed by the deferred worker.
- Every root-spawned Dalvik process other than the module's loaded hook (mapper, update verifier, projection reader) uses
  `sg_bounded_wait` and a private `ANDROID_DATA`: `<data root>/core/vm/dalvik-cache` (0700, `sg_vm_prepare`) for mapper and
  update verifier, the module's `vm/` tree for the projection reader. Update verifier bound: 240 s. They export a validated
  `BOOTCLASSPATH` (`sg_bootclasspath`) if the environment lacks one; nothing of ours writes `/data/dalvik-cache`. `map status`
  is read-only: uses `core/vm` only if present, else scratch `core/vm.status.<pid>` removed by the dispatcher on exit; only
  `map verify`, `map run` and the update verifier create `core/vm`. Restore residue and the uninstall hook remove it.

## Watch events

- `watch=boot,screen_on,usb_change` are the only events. The watcher invokes `root/<id>.sh watch <event>` only while the module's desired state is on, under the root operation lock, waits for `sys.boot_completed=1` with a slow sleep and no hard exit, re-reads desired state every loop, and never passes arbitrary event names or arguments. Boot is dispatched once per module per kernel boot (marker `watch/boot.<id>`
  holding `/proc/sys/kernel/random/boot_id`). Screen-on = display off→on transition read from `dumpsys power` every 5 s
  (keys `mWakefulness=`, `mDisplayPowerRequest.policy=`; `mScreenOn=`/`mInteractive=` also accepted); uncertain readings do not
  trigger. With no enabled watch module the watcher idles on a 300 s sleep (can delay noticing a newly enabled one).
- Receipts are published only after successful dispatch. At most six attempts per boot/event, delays 5, 10, 20, 40, 60 s
  (uptime clock); reservations survive watcher restart. A new observed screen off/on edge or USB signature starts a fresh event budget; failures
  stay queued while the screen stays on. Disable, stock pause and the dispatcher intent lock suppress calls. Every Binder attempt
  uses `sg_service_call` and its ledger; the consent module treats only `sg_service_call_ok_this_boot` as boot completion.
- USB change: while any desired-on module declares `usb_change`, each active poll reads physical USB
  `idVendor`, `idProduct`, `devnum` under `/sys/bus/usb/devices` and the `ifindex` of interfaces matching
  that module's `owns_ifaces` under `/sys/class/net`. Link flags are excluded so module link operations cannot
  trigger themselves. Host seams are `SG_USB_DEVICES_DIR` and `SG_SYS_NET_ROOT`. First observation each kernel
  boot and any changed signature queue one event, including unplug, same-port replug with a new devnum,
  and delayed driver interface creation. Per-module `watch/usb-signature.<id>` and `watch/usb.<id>` persist
  observed identity and boot-scoped pending work; `watch/retry.<id>.usb_change` reserves attempts before
  dispatch. Successful dispatch alone clears pending. Restart, disable and stock pause retain signature,
  pending and attempts; calls resume when permitted. USB polling is independent of display state.
- Reasserted properties: each active poll compares saved applied values for enabled modules with `watch=screen_on` +
  `reassert_props` (ready baseline and applied marker required); a mismatch reuses fixed `watch screen_on` dispatch under the lock
  and desired/pause guards. No new event or root argument. Failed reassertions retry on later polls; timing after
  QUICKBOOT_POWERON needs on-car verification.

## QuickBoot evidence boundary

`tmp/car-sessions/2026-11-04-devdump/README.txt`: single read-only NEEV KOR snapshot. `runtime/root/rootfs_init.tcc803x.rc.txt:224-230`
sets `tcc.hibernate.property=reloaded` and `tcc.mobis.AMS.state=late` on QuickBoot; captured `runtime/cmd/getprop.txt` has
`reloaded` and `normal`, `sys.micom_ready=true`. These are states, not monotonic session identifiers; a poller may miss
transitions. `rootfs_init.daudio.rc.txt:99-101` starts `log_summary` at QuickBoot without a session counter.
`analysis/BINDER-SERVICES.md:2354-2388`: `com.hkmc.micom.power` = `IMicomPowerService`; transaction 1 is read-only
`getPowerStatus()`, listener registration 12/13. No value semantics or trace shows an ignition cycle changes the getter while
Android stays awake. No raw vendor power transaction or guessed property trigger was added. Same-kernel QuickBoot preserving
display-on state remains a limitation for consent dismissal; verify ignition off/on traces before choosing a new signal.

## Deferred APK install

- USB postinstall retains the APK and fixed helper under private `app-install/payload/` and atomically publishes
  `app-install/pending`; only that explicit request permits automatic install. Reconcile runs the pending worker before OTA
  delegation and missing-APK cleanup; the synchronous Android-up hook uses the same worker and spends one attempt.
- One worker waits with capped readiness backoff, ≤4 attempts per kernel boot (5/10/20 s delays); reservations survive worker
  restarts; failure retains request and APK for the next boot. It holds the shared operation lock, respects uninstall pending,
  and deliberately ignores `stock/paused` (the request exists only because the owner installed from USB; reconcile runs the
  worker before its pause gate so a failed stock restore can't strand the new APK on an old version).
- USB postinstall clears the OTA selection (`update/current`, `current-path`, `previous-path`, `previous-version`, `journal`; version
  dirs and baselines retained; `stock/paused` never cleared) before any APK step; the worker repeats that clear after a successful
  install, so root verbs and the app never run different versions. Once it sees the app installed it records `seen`; later
  absence cancels the request and removal cleanup proceeds. Success retires the request before deleting retained payload;
  preuninstall cancels it after guarded stock restore. No request ⇒ APK absence always follows removal cleanup (legacy installs too).
  An APK update failure while still registered does not suppress desired-on reapply, including repair in modules already `on`.
- `install-apk.sh` forces `sys.boot_completed=0` around `pm install` (also at boot). pm runs in the background under a 120 s
  watchdog: TERM pm and its `/proc` descendants, 5 s grace, KILL. The property is restored on every exit path (normal, failure,
  watchdog, TERM/HUP/INT) with the original exit status. SIGKILL of the installer can't run a trap, so the watchdog also polls the
  installer pid: when gone it stops pm, restores the saved value and removes staging. If the whole group was killed, the next run
  first restores the property from the `old` file of a dead `install-apk.<pid>` directory. Helper files (pm output, timeout marker,
  saved value, watchdog pid) live in private 0700 `$SG_DATA_ROOT/install-apk.<pid>`; only the staged APK
  `hmg-seogaemo-install.<pid>.<epoch>.<random>.apk` is in `/data/local/tmp` (PackageManager must read it).
- Export diagnostics read logs with 4 KiB `dd` blocks from regular files, write probe output to files (not pipes), and the 10 s
  probe guard stops the probe's descendants so a lingering grandchild can't stall an export. Raw (unredacted) bytes are staged only
  in private 0700 `$SG_DATA_ROOT/diagnostics-tmp.<pid>` (removed on EXIT/HUP/INT/TERM); only redacted, capped files reach the
  export. A SIGKILLed export leaves its directory; the next export sweeps exact `diagnostics-tmp.<digits>` of dead pids. `dd`
  `skip=`/`count=` use POSIX block units; toolbox `dd` semantics unverified — check one truncated log in an on-car export.

## On-car checks

- USB install with Android down; delayed PackageManager readiness; failed install then cold-boot retry; one installer during
  overlapping service launches; no reinstall after APK-only removal; boot property restored after successful and failed PM calls.
- Cold boot launches reconcile without Manager; delayed Android startup eventually reapplies desired modules; install/update still
  reapplies; map-dependent modules wait for verification; interrupted OTA recovery runs; APK-only removal restores baselines.
  Capture service logs and ledger before/after; no automatic calls after a paused restore.
- Delay `com.hkmc.factory` registration: failed boot calls stay retryable, a successful call retires the boot event, every Binder
  attempt is in the ledger, failed wake calls retry while the display stays on.
