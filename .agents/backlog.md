Status: current — open verification and development items.

# Backlog: checks and planned work

**Maintenance rule.** To-do list, not history. Delete an item in the commit that completes it (merged, or verified on the car); record lasting findings in the linked topic doc. New items need enough context and links for an agent without the session.

Car baseline: Ioniq 5 KOR (NEEV.KOR.\*.260902), NEMESIS + HMG-Seogaemo only. The car runs a 2026-11-06/07 main package installed over adb (APK 0.1.31) with every module bundled and wireless CarPlay on the core hook host; check `hmg-seogaemo-root <id> status` for module states before a session. Developer mode on (`persist.hmg_seogaemo.dev=1`); adb at `192.168.0.1:5555` over the CarPlay hotspot, or the router address while the built-in Wi-Fi client is on; `/data/local/tmp/nemesis-d` present (recreate with `adb shell cp /system/xbin/nemesis /data/local/tmp/nemesis-d` if missing).

Local evidence (gitignored, owner's Mac): `tmp/car-sessions/2026-11-04-tbt/` (live logcat, USB export with `diagnostics/tbt/`, `analysis/` reports); `tmp/car-sessions/2026-11-05-drive/` (0.1.28 drive logcat, exports, `drive-notes.txt` with the lane-injection results). Lane injection tool: `tmp/lane-probe/` (`lanes.sh`, `trailer.sh`, `LaneProbe call <method> <ints>`).

## 1. CarPlay turn-by-turn follow-ups

Background: `carplay-tbt-learnings.md`, `carplay-tbt-external-research.md` (0x5204 layout, ManeuverType enum, icon codes), `wireless-carplay-and-aa.md` (observation records, developer toggle `persist.hmg_seogaemo.dev`, Dalvik cross-dex rule), runtime contract "Turn-by-turn observation records and `tbt-reset`".

- [ ] **Maneuver → icon table from field data.** NAVER Map (via CarPlay) sends no exit
  angle; type-based arrows now cover 1/2/47–50. Review the recorded combinations and
  instruction texts (`tbt-icons.txt`/journal in exports) and refine: type 0 with
  junction=1 exit=180 (roundabout, icon 102), 4 U-turn, 13/14 keep, 53, ramps/exits.
  Third-party reference (reference only, do not copy):
  owner upload `nav_mapping.py` (HKMC `Navigation$DisplayType`, 81-byte lane struct
  incl. bitmasks at 0x43–0x50).
- [ ] **TBT icons from firmware (ramps/roundabout); verify on car.** Icon 8 (none) and highway 160–165 are car-verified (`cluster-tbt-icons.md`). Firmware: highway entry/exit use 160–165 (not only 81/82/86), still to be used by `exactIcon`; roundabout has a main family (96/97/99/100/102/104/105/107) and an alternate-side family (192/193/195/196/198/200/201/203). Extending `exactIcon`/ramp/roundabout needs the phone-side driving-side/alt-side selector; verify against firmware analysis and drive logs first.
- [ ] **Verify CarPlay lane output end-to-end on a drive.** Cluster side car-verified parked
  2026-11-06 by frame injection (`tmp/lane-probe/step.sh`): white/blue/grey slots in one
  lane, `updateRemainDis` 300 m / 1.2 km, an empty `0xF1` frame removes strip and box. Still open (needs real phone lane data): `CpTurns`
  (`LaneGlyphs`, `laneValues`, `sendLaneDist`) turns NAVER/Apple lanes into the right
  pairs/colours, only the route arrow is blue, the box tracks the turn distance.
- [ ] **CarPlay altScreen (iOS-rendered cluster video) research record.** Kept separate
  from the junction view: document altScreen (display type 111) declaration,
  negotiation, stream format and what iOS renders, even if this cluster cannot
  consume it, since another surface may. In progress (local):
  `tmp/analysis/carplay-altscreen/` (sources: DiPlay `tmp/DiPlay-src`, offline dump).
  Move lasting findings into a topic doc when done.
- [ ] **Exit angle reset on partial 0x5202 updates (suspected bug).** `Maneuver.read()`
  sets `exit = 0` / `hasExit = false` before parsing, so an update without optional p11
  erases a cached exit angle (absent is now distinguishable from 0° via `hasExit`). Confirm
  against tests/dispatch, then preserve the cached value. Raised independently by the 2026-11-06 external-project comparisons.
- [ ] **Verify CarPlay stock-format guidance on a drive.** Implemented
  ([cluster-ar-view.md](cluster-ar-view.md), [hud-hologram.md](hud-hologram.md),
  [hud-junction-view.md](hud-junction-view.md)); the six guidance map points reflect on the car.
  First drive (2026-11-07, 0.1.36): AR, hologram and junction pictures appear with the right
  direction, but junction lane counts did not match the road (a two-lane picture on a one-lane
  ramp), arrival showed no flag, and a five-lane split (1-3 straight, 4 overpass, 5 right) showed
  a right Y then a left Y. Since then keeps send no stock shape, junction pictures are exits only
  with exact lane counts and exit-edge recommended lanes, and arrival sends the flag.
  Check next: exit junction pictures match the road (lane count, side) and appear often enough;
  destination flag; route search 9 / 10 text (the phone may not send the Loading/Rerouting
  states); 19/20 lane-change exits; the trap bar falls with distance and a real camera record
  takes it over; clears after the maneuver, on reroute, guidance end and disconnect; idle compass
  at the end; `stop()` does not race stock navigation
  resuming its own guidance.
- [ ] **Verify Android Auto lanes on a drive (next beta).** Offline fix, see
  [wireless-carplay-and-aa.md](wireless-carplay-and-aa.md) "Android Auto lanes". With a phone
  that sends lanes (Google Maps; NAVER/T map/Kakao may send none): the strip appears on the
  cluster and HUD and stays (refresh every 750 ms), the route arrow is blue and the other
  arrows/lanes grey, multi-arrow lanes show pairs, the box beside it shows the turn distance,
  everything clears at arrival and when the car's navigation takes over. If no strip: developer
  mode on, pull logcat (`AALANES event 34 [...]` per lane change, `NAVDUMP` the phone's state when the library dumps it) and the USB export.
- [ ] **Verify Android Auto stock-format turns on a drive.** `AaGuidance` (policy in
  [cluster-ar-view.md](cluster-ar-view.md#android-auto-policy)): AR view and hologram near turns,
  U-turns, exits and roundabouts with the right direction; the bar falls with distance and gives
  the stock bar back; 10 during rerouting clears on the new route; destination side / flag.
  Still CarPlay only: HUD junction pictures and lane-change exits 19 / 20 (AA lanes carry no
  recommendation we decode yet).
- [ ] **Map app in observation keys.** Record the route-guidance SourceName (NAVER,
  Apple Maps, Kakao, …) with each observation; apps differ (angles, types).
- [ ] **Status "unknown" with a second DiPO record.** `HmgSeogaemoProjectionRuntime`
  status can report `native.libCarPlayCore.so=registered waiting for library` from a
  second DiPO record in the same boot; base readiness on the process that loaded the
  libraries.
- [ ] **Transient "assets unreadable" during reapply.** `status` reports failed while
  `put_assets` is still writing recipes (seen right after `nemesis install --update`);
  report in-progress instead, or make status wait for the operation lock.
- [ ] **Trip distance vs next-turn distance.** `updateTBTSubInfo` carries remaining
  trip distance (km, 0.1 steps); confirm on the cluster/HUD which field shows the
  next-turn distance and that units switch correctly under 1 km.
- [ ] **Pull the decrypted stock navigation engine from the car (read-only).** `libExSLNavi.so` (and other native libs of `com.mnsoft.navi`, e.g. under `/data/app-lib/`) is missing from the 2026-11-04 offline dump; the official update backup (V031/V036) only has encrypted `enc_libExSLNavi.so`. The car's decrypted copy would show how lane fields (`dir`, `idx`, `valid`) become the 81-byte 0xF1 frame. Locate with toolbox `ls` (no `find`), `adb pull`, no writes.
- [ ] Guard test: no new `hmgapi/mods` class may extend/implement a `hmgapi/hook` type
  other than `MethodHook` (dexdump check in the module test).

- [ ] **CarPlay → Android Auto switch (on car).** With a registered iPhone in wireless CarPlay
  and an Android phone paired, choose Android Auto in Phone Projection / Device Connections. Check
  logcat `HMG-Seogaemo-Wireless` for `Phone Projection connect type=2 transfer=1: stopping`, DiPO's
  `setDipoStatus() mDiPOStatus : 0` and CarPlay closing, then GPM `[HU >> MD] Sent STATUS_SUCCESS`
  rather than `STATUS_PROJECTION_ALREADY_STARTED`. Also confirm that the iPhone stays off while
  Android Auto runs and that choosing CarPlay again reconnects it. After the next drive, the iPhone
  should connect by itself. Check whether Phone Projection sends `connectPP` type 2 automatically
  when the Android phone's Bluetooth connects, because that decides the two-phone behavior. See
  `wireless-carplay-and-aa.md` § Switching.

## 1b. Core hook host and installable modules

- [ ] **Finish the on-car check of the core hook host** (`core/hook/`, contract "Core hook host").
  Car-verified: one hook module alone (`hook-sample`, 2026-11-05: Settings logged
  `[hook-sample] hello from com.android.settings`; revert + restart left stock `app_process`, md5
  `33f79811…`, 9492 B, 0:2000, no extras, no wrapper lines in `dmesg`), and wireless CarPlay on the
  host including the migration from its old self-installed wrapper; turning CarPlay off on the host
  (2026-11-07: stock `app_process` MD5, files removed, `featurexml.cfg` lines and
  `persist.ium.support=carplay` restored; empty asset dirs were left, since pruned in `dfea62c`).
  Still open: Settings → Restore stock state releasing the host, and the boot guard (3 forced zygote
  crashes turn hooks off). Check after each: restart, `app_process` md5 `33f79811…`, no `dmesg | grep hmg-seogaemo-hook` lines,
  `/data/nemesis/backup/hmg-seogaemo/core/hook/status` gone.
- [ ] **Two hook modules on one wrapper (on car).** CarPlay is a hook module, so `hook-sample` next
  to it covers this: both load, and turning either off keeps the other. Procedure: adb ready;
  `make package`, `python3 tools/hsm pack out/hook-sample/module --out out/hook-sample`,
  `python3 tools/hsm push out/hook-sample/hook-sample-0.1.0.hsm`, `hmg-seogaemo-root hook-sample apply`,
  restart; check `logcat -s HMG-Seogaemo-Hook` ("hello from" in Settings and DiPO, CarPlay still
  connects), `/data/nemesis/backup/hmg-seogaemo/core/hook/status`, module status `info.hook_*`.
- [ ] Settings changed while on are applied by revert+apply; the zygote reads them only at
  start (restart needed). Decide whether hook modules should say so in the UI.
- [ ] After the last hook module is off, `sg_core_hook_release` removes only `core/hook/dex`,
  `core/hook/status` and empty `core/hook/mods/<id>`: `core/hook/core-hook.properties`, the empty
  `core/hook/mods/` and `modules/core-hook/{module.log,assets-repaired-boot}` remain; clean up.
- [ ] Status of an installed module that is off or pending restart prints `info.desired=off` twice
  (`core/hsm-module.sh` `hm_status`, then the dispatcher in `bin/hmg-seogaemo-root`); print it once.
- [ ] `tools/hsm pack` without `--out` writes to `./dist/` (not gitignored); default to `out/`.
- [ ] **Phone Projection menu on Korea (on car).** With wireless CarPlay/AA on, Settings > Phone Projection
  should open Device Connections (Android tab, split-view settings), not the wireless page
  (`wireless-carplay-and-aa.md`, "Phone Projection menu"). Check logcat `HMG-Seogaemo-Wireless` for
  `Phone Projection: stock Korean settings screen (region 0)` (confirms `Car.region()` is 0 in `com.android.btsettings`),
  that the entry still behaves while a projection runs (stock popup, no crash), that choosing Android Auto there switches
  from CarPlay, and that module off restores the wireless page.

## 1c. CarPlay connection owner (stage 3: publish only)

Background: [carplay-connection-owner.md](carplay-connection-owner.md) ("Verification" and "Item 9 design"),
[wireless-carplay-and-aa.md](wireless-carplay-and-aa.md) "CarPlay connection owner". Off-car tests pass; nothing ran on a car.
Turn it off with `setprop persist.hmg_seogaemo.owner 0` (restart DiPO's process or the head unit) for the baseline run.

- [ ] One iPhone, fresh boot: `owner: status 1` then `owner: status 3`, once each; Phone Projection lists the phone as connected
  with its name (PP log `requestWLDeviceConnectStatusUpdate ... connectStatus (3) transferType = 1`). A USB CarPlay phone creates no
  row and no status.
- [ ] Unplug or disable the phone: `status 4` only after DiPO is inactive; Phone Projection clears its current device. Start, stop,
  start inside 5 s: one `4`, then one `3`.
- [ ] Delete the Phone Projection row while disconnected, then reconnect: it is added again.
- [ ] Phone Projection's own reaction to 3 and 4: no unexpected popup, no auto-connect of another phone after the end, Android Auto
  still starts. Record any PP log line that changes.
- [ ] Delete the connected phone in Bluetooth settings: expect the stale state until stage 4 (`ProjectionDelete`); note what remains.
- [ ] Kill switch `0`: behaviour identical to 0.1.47-beta.2; logs show `owner: off`.
- [ ] Known gap to confirm: the `device_list` row survives the module's removal (owner decision in the design note).

## 2. Older open items

- [ ] `nemesis root -c` with long commands fails with "daemon write failed"; find the
  limit and keep app/root commands below it (split or script file).
- [ ] Restore stock stops at the first module conflict and leaves later modules
  not attempted; decide whether to continue with the others (`stock-restore.md`).
- [ ] Show "/system stays rw until restart" (remount-ro EBUSY) in the UI/status, not
  only in `module.log`.
- [ ] (With the UI/UX redesign) Wireless ADB shows "확인 불가" / `adbd 상태: stopped`
  when the app polls during the boot re-apply's adbd restart (about 70 s after boot):
  `wireless-adb.sh` status reports `failed` while `init.svc.adbd` is not `running`, and
  the app never re-polls. Report a transient "applying" state and re-poll in the app.
- [ ] (With the UI/UX redesign) Switching Wi-Fi (built-in client) -> CarPlay from the CarPlay row
  refuses with "ADB state unknown" until the Wireless ADB screen has been opened once.
  The plan/precheck uses a stale or unknown wireless-adb status instead of polling it;
  refresh dependents before planning.
- [ ] On-car checks not yet done: wifi-client -> wifi takeover after a USB and an OTA update; USB adapter roles (driver load, client, hotspot); wifi built-in client disable exact restore (+restart);
  both user buttons after restart and after visiting stock settings
  (`user-button-shortcut.md`); full NEMESIS uninstall leaves the unit byte-identical
  (`stock-restore.md`); QuickBoot/ignition-only cycle behaviour (`boot-lifecycle.md`).

## 3. Planned features (owner-approved direction)

Evidence and candidate hooks: `neev-kor-api-inventory.md`.

- [ ] Vehicle firmware OTA blocking.
- [ ] CarPlay per-component switches (audio, TBT, Siri, …).
- [ ] USB ADB role switch.
- [ ] Battery diagnostics, read-only first; any control needs owner approval.
- [ ] EV information to the phone over iAP2 (EV routing).
- [ ] Virtual exhaust / driving sound in the cabin: research the head-unit audio path and the
  vehicle-speed/accelerator signals available to it (and any stock sound feature to reuse).
- [ ] Manual battery preconditioning (start battery conditioning without a navigation
  destination to a charger); find the BMS/thermal request the stock EV navigation sends.
