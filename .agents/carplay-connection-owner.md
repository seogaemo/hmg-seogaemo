Status: current design, 2026-11-07. Stages are implemented one commit each; the per-stage status lines below say which exist. Nothing here has run on a car.

# CarPlay connection owner (Phone Projection state, delete order, two-phone switching)

Scope: the DiPO part of `wireless-carplay-and-aa` (`Bridge`, `ProjectionSwitch`) and one BtSettings hook.
Reference only: HMG Leafia Plus r8.2 does the same in a patched DiPO/BtSettings (behavior read from its smali, nothing copied;
provenance in `UPSTREAM.md`). Everything below is written from the stock NEEV KOR smali, our own code, and r8.2's observable behavior.
No interface change: no new root verb, ledger field or module property. New catalogue points are optional (not in
`hookpoints.required`); the kill switch is a read-only system property (below).

## Stock facts this rests on (host evidence: stock smali deodexed with baksmali `-a 18`)

- Stock KOR DiPO never calls `requestWLDevice*` or `addPPActionListener`; only GPM (Android Auto) does. Phone Projection (PP)
  therefore has no record, status entry or "current device" for a CarPlay phone, and its UI actions (`connectPP`, `disconnectPP`,
  `cancelConnectionPP`, `runningPP`) reach only GPM's listener and ours (`Bridge.PpListener`).
- `PPManager` (`getSystemService("phoneprojection")`) wraps the `IPPManager` binder. `PPService` does no logic: it range-checks the status
  (0..4) and fans out to `IWLDeviceListener`s. PP's handler (`wireless/service/a.requestWLDeviceConnectStatusUpdate`) **returns at once
  when the record (`device_list` row, looked up by address, serial, user) is missing**; it never compares the row's transfer type with
  the request's. Status 2 (wireless) writes `on_off`, `auto_connection`, `last_connection`; 3 sets PP's in-memory current device
  (type, name, address, serial, status, transfer type of the *request*) and no DB write; 0/4 clear that current device when it
  matches, and reason 2 (UI delete) deletes the row there.
- `DiPOManager.isDiPOActivated()` is `getDiPOConnectStatus() == 4`; stock DiPO sets 4 through `DipoService.af(I)` (`dipoActivated()`),
  and PP's "connectivity active" (`d.dV()`) is DiPO-activated or GPM-activated or MirrorLink or Carlife.
- `BtSettings aW.l(String)` (device deleted in the Bluetooth list): if the address is the connected CP/AA phone, `ch()` ->
  `sendDisconnectPPFromBT(addr)`; then immediately `onWLDeviceDeleteDB(addr, null, user)`. PP, when `dV()`, posts the delete 300 ms
  later and returns false, and deletes regardless of whether the session has ended.
- `CarPlayService` (unobfuscated) callbacks: with `nonBlockingMode == true` (always on this path) `onSessionCreated/Details/Started/
  Finalized` are posted to the service's main-thread handler in arrival order; our existing hooks on them run on the caller's thread,
  *before* that post. `onSessionDetails(deviceID, mac, model, name[], osBuild, sourceVersion)` is the first place the native session's
  device id is known; DiPO's own `q.a(...)` hook sees it later on the main thread, so it cannot be ordered against our
  created/started/finalized hooks. `connectCarPlay(String)` / `disconnectCarPlay()` return `CarPlayReturn` (`OK` / `ERROR`).
- Unconfirmed by evidence (host only): the native thread that calls `onSession*`; the meaning of DiPO status 1..3; PP's tail for
  statuses 0/1/4; whether the DB write of a record added by DiPO survives a PP restart as r8.2 assumes. See "Verification".

## Failure paths in our code, per item

Item 9 (state mismatch)
- 9a. Choosing wireless CarPlay in Phone Projection does nothing unless the phone is "held": `ProjectionSwitch.request(connect, CarPlay)`
  returns IGNORE without a hold. PP never gets a CarPlay record or `3`, so its current device stays empty while the head unit shows CarPlay;
  a wireless Android Auto `connectPP` is still told "connectivity active". Nothing ever reports `4` for CarPlay.
- 9b. `Bridge` flags are our own copy of the truth (`sSession`, `sCpClient`, `sCpWireless`, `sCpConnected`) and follow native callbacks
  only. A queued job (`scheduleSppConnect`, `onSppUp` post, `onUsbGone`) for a phone the user has since disconnected can still run
  and leave `sSession` true (nothing rolls it back); a DiPO status that has not dropped yet is not looked at at all.
- 9c. Once anything publishes (a precondition of 10 and 11), the order of `4` against DiPO's inactive state decides whether PP can
  start the next device: PP starts the pending device on the old device's `4`; a `4` while DiPO is still activated makes the next
  `connectPP` hit a still-active DiPO and be dropped.
- Not established: that stock code stores a wired CarPlay phone with transfer type 0, or that any such row disagrees today. Without
  records the mismatch only exists after we publish (item 9 creates the rows); the "remembered connection type" wording in the request is
  therefore handled by publishing only when native session, bond and `isDiPOActivated()` agree, and never rewriting `transfer_type`.

Item 10 (deleting the connected device)
- 10a. After item 9 a row exists. Stock order in `aW.l`: disconnect request, then `onWLDeviceDeleteDB` at once (PP defers 300 ms and
  deletes). The session ends later (`BT_DETACHED` -> iAP2 -> CarPlay finalized -> DiPO inactive -> our `4`), so the row is gone when
  `4` arrives and PP's handler returns at the missing-record check: PP keeps a stale "connected" current device. So item 9 alone
  introduces this regression for a delete of the connected phone; item 10 must ship with it.
- Today (no rows) deleting only unpairs; `PpListener.disconnectPP` already stops and holds the bridged session.

Item 11 (two phones)
- 11a. `Bridge.onSppUp(B)` overwrites the single `sAddr` while A's wireless session runs (`sSession` false after the CarPlay-channel
  handover, `sCpClient || sCpWireless` true): the assignment precedes the `sCpClient || sCpWireless` return. Later uses take the wrong
  phone: `startCpClient` (serial = `sAddr`) if the handover has not happened yet (default: on first channel data), and
  `onCpSessionFinalized -> onUsbGone` re-attaches B, never A, 3 s after A's session ends.
- 11b. `onProjection` ignores the request's address: a wireless `disconnectPP(CarPlay, B)` for a phone that is not connected stops and holds
  A (`SWITCH.request(..., iphone = sAddr, ...)`).
- 11c. After a session ends, `onUsbGone` re-attaches the same phone after 3 s unless held; there is no "blocked" notion for a phone the
  user disconnected from the BT side, cancelled, or un-paired. Delayed jobs are not tied to a decision (no token).
- 11d. PP's own switch (disconnect A, wait for A's `4`, then `connectPP(B)`) cannot work: no `4` (9a), and `connectPP(CarPlay)` is only used to
  release a hold.
- 11e. A second phone's start never aborts a stale attribute of the first: native `onSessionDetails` identity is ignored entirely.

## Item 9 design: `ProjectionOwner`

Pure state machine `hmgapi.mods.wireless.dipo.ProjectionOwner` (Java 7, no android imports) behind an `Env` interface, host-tested with fakes
and a manual clock; Android glue `OwnerEnv` (`PPManager`/`WLDeviceInfo`/`DiPOManager`/`UserProfileManager`/`BluetoothAdapter` through
reflection, all in try/catch, so a different framework only disables the owner).

State: `generation`, `createdSeen`, `nativeStarted`, `nativeFinalized`, `connectedPosted`, `endPosted`, `active` peer, `pendingEnd` (owed end of
a previous generation), `blocked` (`user:ADDR`), `deleted` (ADDR), `known` (`user:ADDR` -> deviceId, mac, name; memory only).
A *peer* is (BT address, CarPlay device id, mac, name, user).

Inputs (all posted to one owner thread, stale items dropped by generation):
- `created`, `details(deviceId, mac, name)`, `started(transport)`, `finalized(transport)` from the existing/new CarPlayService hooks;
- a **poll** instead of a hook on the obfuscated `DipoService.af(I)`: while an end or a connect is waiting for DiPO's activation state, re-check
  `isDiPOActivated()` every 250 ms, giving up after 30 s (log, then publish `4` anyway so PP never stays "connected"; r8.2 has no cap);
- PP's `runningPP()` (PP UI restarted: republish); `connectPP/cancelConnectionPP/disconnectPP` (stage 3).

Publish rules (spec taken from r8.2's behavior):
- `connected` (`ready 1` then `3`) only when all hold: native started and not finalized, a peer attributed to this native session, that
  peer's BT address is bonded, not `blocked`/`deleted`, no disconnect requested, `isDiPOActivated()`, and no earlier `4` is still owed.
  The record is always `(ppType 1, transferType 1)`; the stored row must match it (same address/user/ppType, serial empty or equal, transfer 1).
  A missing row is added with `requestWLDeviceInfoAdd` (unless the user removed it during this session or the phone is unbonded);
  a row with another transfer type is **not** reported (no rewrite).
- `ended` (`4`) only after native finalization **and** `!isDiPOActivated()` (or the 30 s cap), once per generation. A new session before
  that carries the end (`pendingEnd`) and holds the next `3` until it is sent.
- Wired CarPlay (transport != 1 or `Bridge.sUsb`) and Android Auto are never published.
- Attribution: the native session is credited to the BT address the bridge was bootstrapped for (`Bridge.sAddr` at `created`) only when
  `details` supplies a device id that does not belong to another learned phone. Without attribution nothing is published.

Kill switch and failure behavior: `persist.hmg_seogaemo.owner` (default on; `0` = off, read once per DiPO process start; documented in
`wireless-carplay-and-aa.md`). With it off, with any of the optional points missing, or after any reflection error, `Bridge` runs exactly
as today (the owner is null; every Bridge call site is a null check). Every submitted status is logged with generation and masked address.

New optional hook points (host-mapped for NEEV KOR in the catalogue commit; none in `hookpoints.required`):
`dipo.carplay.on_create`, `dipo.carplay.on_destroy`, `dipo.carplay.session_details` (6-argument `CarPlayService` callback),
`dipo.carplay.connect`, `dipo.carplay.disconnect`. Stage 2 adds `btsettings.pp_bt`, `.request_delete`, `.send_disconnect`.
No hook on `DipoService.af` and no PhoneProjection/services points (those files are not tracked by `car.json`): framework public API is
called by name through reflection, as `Bridge.registerProjectionListener` already does.

Known gap to carry (owner decision needed): `requestWLDeviceInfoAdd` creates a persistent PP `device_list` row (app data, outside the
package ledger). Removing the module leaves the row; it disappears when the phone is deleted in the Bluetooth list (BtSettings calls
`onWLDeviceDeleteDB` for every deleted device). There is no root verb to remove it; adding one would need a free-form target, which
the root-channel rule forbids. Rows are kept while the module is on because the PP switch UI needs them.

## Item 10 design: `ProjectionDelete` (BtSettings `aW.l`)

Hook `btsettings.pp_bt.request_delete` in BtSettings (already a hooked process). Decision logic is a pure class with a fake `PP` in tests:
- Hold only when `isDiPOActivated()`, the address equals `getCPConnectedBTAddress()`, and `getWLDeviceTransferType(addr) == 1`; any other
  case (wired, other phone, AA, anything unavailable) runs stock unchanged.
- Held: call the stock disconnect (`ch()` through `btsettings.pp_bt.send_disconnect`), skip the stock delete (`setResult(false)`), register an
  `IWLDeviceListener` once, and when the matching `4` arrives: wait one binder round trip (`isCPAutoConnectionAvailableDevice("")`, a barrier
  behind PP's fan-out), re-check profile/address/DiPO inactive/row identity, then `onWLDeviceDeleteDB`. A `2`/`3` for the same peer cancels it.
- Our timeout (r8.2 has none for CarPlay): after 15 s without `4`, run the deletion we skipped, so a deleted phone never lingers.
- AA deferral from r8.2 is not ported (off by default there).

## Item 11 design: peer ownership in `Bridge`

Stage 3a (gating, no new connect behavior): the owner becomes the single judge of "which phone, and may it auto-start".
- `Bridge.onSppUp`: the early `sSession` return stays, but `sAddr` is assigned only when no session of another phone is running
  (`sCpClient || sCpWireless || sSession` for a different address leaves it untouched; B is remembered only as "SPP up"); fixes 11a.
- `onProjection` carries the request's address and acts on A only when it names A (or is empty); fixes 11b.
- `allowAuto(addr)` in `scheduleSppConnect`/`onSppUp`: false for a `blocked` (user-disconnected/cancelled), `deleted` (bond removed) or
  held phone, or while another phone owns a live native session. `queueToken()` captured when a delayed job is queued and checked on run
  (`allowQueued`), with rollback of `sSession` / `sCpClient`+`sCpConnected` when the dropped job was the bridge's own; fixes 11c.
- `cpClientAddress(sAddr)`: the CarPlay-channel handover takes the owner's attributed peer.
- Bond receiver (`BOND_STATE_CHANGED`): bond lost -> `deleted`, end that phone's session; re-bonded -> clear blocks.

Stage 3b (explicit switch, the riskiest part, only if 3a is clean in review):
- `connectPP(CarPlay, B)` becomes `ProjectionOwner.connect(B)`: rejected unless B bonded, DiPO not activated, no USB, row present and on. A
  newer explicit connect supersedes one with no native session yet; a 40 s watchdog drops a lock that never produced a session.
  Learned peer (device id seen this boot): `connectCarPlay(deviceId)` through `dipo.carplay.connect`; unlearned: the Bluetooth route
  (`Bridge.onSppUp(B)` / `scheduleSppConnect(B)`), first sending `BT_DETACHED` if another phone's iAP2 attach is live and polling 1 s x3
  for it to clear. A late native session of a cancelled target is ended on `details`.
- This path stays behind a second switch `persist.hmg_seogaemo.owner.connect` (default on only if 3b ships); `connectPP` for a phone whose
  owner is off stays "released hold" as today.

## Stages and commits

1. This note (+ index entry). **Status: written.**
2. Catalogue + KOR map: the five DiPO points and three BtSettings points, host evidence only.
3. Item 9: `ProjectionOwner` + `OwnerEnv` + hooks + kill switch + tests (`test/projectionowner`) + docs. **Status: implemented (publish only; host-tested, not on car).**
4. Item 10: `ProjectionDelete` + BtSettings hook + tests.
5. Item 11a: `Bridge` gating, address fixes, bond receiver + tests. 11b only if time and review allow.
Each stage: full `make test` green; one commit; no push/merge.

## Verification (car, needs two iPhones for item 11)

1. One iPhone, fresh boot: logcat shows one `ready 1` then `3`; PP lists the phone as connected with its name; PP log
   `requestWLDeviceConnectStatusUpdate ... connectStatus (3) transferType = 1`. Wired USB CarPlay creates no row and no status.
2. Unplug/disable the phone: `4` appears only after DiPO is inactive; PP clears its current device. Start, stop, start inside 5 s: exactly one
   `4` then one `3`.
3. Delete the PP record while disconnected, reconnect: re-registered. Delete the connected phone from the Bluetooth list: order
   `sendDisconnectPPFromBT` -> finalized -> `4` -> deferred delete; row gone; CarPlay does not return; withhold the `4` (switch the owner
   off midway) and see the 15 s fallback.
4. Two phones: A connects, B joins Bluetooth: no change, `sAddr`-dependent logs name A; ending A does not auto-start B; disconnect B in PP while A
   runs: A untouched; user-disconnected phone stays off for 30 min of Bluetooth presence; unpair/re-pair A.
5. (3b) Pick B in Device Connections: A ends, about 1 s later B connects, one `3` for B; start-stop-start A inside 5 s; head-unit reboot with both
   present (never both connected).
6. Kill switch `0`: behavior identical to 0.1.47-beta.2.
Log tag: `HMG-Seogaemo-Hook`, message prefix `[wireless-carplay-and-aa] bridge:` for the bridge and `[wireless-carplay-and-aa] owner:` for the owner (every status line carries `gen=`).
