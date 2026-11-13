Status: current — implemented AGPL port. Wireless CarPlay with music, Siri and calls is verified working on the car (since 0.1.25, 2026-11-04). Wireless Android Auto and cluster/HUD lane rendering are owner-verified on the car (2026-11-07). Boot-guard recovery still needs on-car evidence.

# Wireless CarPlay and Android Auto: NEEV.KOR.260902 port

Packaging: a bundled raw_shell `.hsm` (`modules/wireless-carplay-and-aa/`: `module.sh`, `strings/`, `ui.txt`, `files/`
with the mod jar, projection reader jar, AAC converter, recipes and feature XMLs; `payload/` holds the sources). It
hooks through the core hook host (`hooks=1`). The record reset is the `ui.txt` button `tbt_reset` (`action tbt_reset`);
the `tbt-reset` verb stays for 0.1.31 apps. Updates from the built-in or the old self-installed wrapper: see
`installable-modules.md` (Core hook host, Bundled modules).

Hotspot: the module starts one only through DiPO's `setWifiApEnabledForConnectivity` (stock `wlan0`, car-verified). When the
`wifi` module publishes a USB CarPlay hotspot (`radio=usb`, read once in the zygote), DiPO skips that call and part
`usb_hotspot` gives the iAP2 server and GPM the adapter's credentials and interface; `status` reports
`info.hotspot_radio`. Without it, part `stock_hotspot` covers units whose connectivity call brings up the normal hotspot
or nothing (phone gets the normal hotspot's credentials, AA sees mode 2, the normal hotspot is started 10 s after an
unanswered request). Rules: contract "Peer info"; details and open car checks: [external-wifi.md](external-wifi.md).

Target: Hyundai Ioniq 5 KOR, `ro.build.product=NEEV.KOR.0000.V039.001.260902`, onebin `neev_kr` (`ro.mobis.onebindir`), Android 4.4.2. Owner confirms HMG-API 1.0.0-beta.5 with its mapping and wireless mod worked on this car (hotspot and wireless CarPlay). The pre-install Car Report at `tmp/car-reports/car-report-neev-kor-260902-20261102-2115.json` has 324 mapped points, 12 by reference, one unrelated ThemeSettings point missing. Its `map.status=none` and `wifi_chip=false` are pre-install observations, not a negation of the owner's working test.

## Dependencies and port choice

| Original HMG-API part | Port |
| --- | --- |
| `feature_flags` generates CarPlay/AA wireless permission XMLs and comments their removal lines; `patches.json` comments the hotspot removal line. | `sg_file_put` only for absent XMLs and `sg_file_replace_line` for exact active lines. Missing removal lines are no-ops, as in the upstream engine; duplicate lines are refused. An existing XML must declare the expected feature. We also add hotspot XML if absent on this KOR build. |
| `persist.ium.support=carplay`; bridge `persist.sys.iap2.wifi=t`, `persist.iap2.iden.wireless=t`. | Same values via `sg_prop_set`; ledger restores live values and `/data/property` existence/content. |
| `Wireless`, `AaTurns`, `dipo/{Dipo,Bridge,CpTurns}` Java hooks DiPO, iAP2, GPM, navigation, USB startService, BtSettings. | Copied with fixed upstream default settings. Upstream changes only US/CAN; ours also covers Korea (see "Phone Projection menu"). |
| Zygote wrapper, Dalvik JNI loader, hook JAR, car hook map. | The core hook host owns wrapper, loader and engine JAR (ledger owner `core-hook`); this module registers its mod jar (`hmgapi.mods.wireless.Wireless`, six apps) with `sg_hook_register`, ships a world-readable parts copy, and the core selects and publishes the verified map. Car-verified 2026-11-07: migration from the self-installed wrapper, wireless CarPlay, status `on`. |
| Native `MemRecipe` on `libautoreceiver_infobank.so`, `libCarPlayCore.so`, `libCarPlayAudio.so`, `libCarPlayUtils.so`. | Same 5 recipes applied **in memory** after exact byte-region verification. Stock libraries stay untouched. No `lpatch` binary or rebuilt OEM APK/odex. KOR CarPlayCore hash `ef49c09b7ab5eb72298f9973443b66b3` is listed as Wi-Fi native; Utils hash `e85385d70194efe82cc8a6d0f66f5115` as converter native. Other builds may reject recipes. |
| `libleafiaaac.so` for AAC/Opus. | Rebuilt from upstream `leafiaaac.c` with local clang/lld and installed through the package API. No manufacturer binary is bundled. |
| Generic settings UI, HMG-API `hmgapid`, mod engine, APK patch transaction, network keeper. | Dropped. The upstream mod declares no network rule; this car's pre-install firewall report is permissive. No Wi-Fi client property or feature is requested. |

The `hmgapi.*` Java namespaces remain internally to preserve the mod's app-part class loading; they resolve only to bundled classes, never to installed HMG-API. `modules/wireless-carplay-and-aa/build/build.sh` calls the packaged `payload/build.sh`, which builds ARM objects with clang/lld and API 19 DEX with `javac`/`d8`. The NEMESIS ZIP includes the latter script and all corresponding hook source. The shared Makefile calls it before packaging and invokes `test/run.sh` in `make test`. The NEMESIS ZIP includes the rebuilt payload bytes; the hook JAR uses a fixed ZIP timestamp so repeat builds are byte-identical. Payload Java source is stored as `.java.src` so the shared APK compile does not accidentally include vendor stubs or hook classes; the module build copies it to temporary `.java` files before compilation. `payload/build.sh`, `payload/native/build.sh`, and `payload/native/syslib-stubs.sh` are host-only build scripts; no payload shell script runs on the car. The on-car root script uses toolbox `md5` and mksh `read` for hash and process parsing.

## Exact car map and firmware guards

The map is `maps/hyundai/ioniq5/kor/260902/{map.json,car.json}` in the core package. It contains 348 resolved point names and all 18 stock-file MD5s reported for this car; the original 324 have on-car reflection evidence and the 24 additions have host evidence only (see car-mapping.md). The module declares 120 point IDs, including owner classes and supporting fields, in `hookpoints.required`. Root precheck requires `map status` to report a verified core map. The zygote loader reads the package API's active pointer under `/data/nemesis/backup/hmg-seogaemo/car-maps/`, checks the exact product, onebin, Android version, boot verification seal, and all map stock MD5s, then loads the published verified entries. The module has no private payload map and installs no map into `/system`. The report has no whole-file hash for `app_process`, `featurexml.cfg`, or native libraries. Native recipes still verify their own byte regions. HMG-API's Dalvik offsets were proven on US EV6; on-car KOR validation remains necessary.

Declared hook points and their exact resolved members on this car:

| Point | Resolved member |
| --- | --- |
| `framework.context_impl.start_service` | `android.app.ContextImpl.startService` |
| `btsettings.projection_helper.open_wireless_page` | `com.android.settings2.bluetooth.iP.aQ` |
| `framework.navigation_cluster.update_tbt_info` | `com.hkmc.cluster.NavigationCluster.updateTBTInfo` |
| `framework.navigation_cluster.update_tbt_sub_info` | `com.hkmc.cluster.NavigationCluster.updateTBTSubInfo` |
| `framework.navigation_cluster.update_tbt_sub_info_b` | `com.hkmc.cluster.NavigationCluster.updateTBTSubInfo` |
| `framework.navigation_cluster.update_tbt_sub_info2` | `com.hkmc.cluster.NavigationCluster.updateTBTSubInfo2` |
| `framework.navigation_cluster.update_tbt_sub_info2_b` | `com.hkmc.cluster.NavigationCluster.updateTBTSubInfo2` |
| `framework.navigation_cluster.update_tbt_sub_info_2c` | `com.hkmc.cluster.NavigationCluster.updateTBTSubInfo2C` |
| `framework.navigation_cluster.update_remain_dis` | `com.hkmc.cluster.NavigationCluster.updateRemainDis` |
| `framework.navigation_cluster.update_tp_crossroad_name` | `com.hkmc.cluster.NavigationCluster.updateTPCrossroadName` |
| `framework.navigation_cluster.update_tp_destination_name` | `com.hkmc.cluster.NavigationCluster.updateTPFlexibleDestinationName` |
| `framework.navigation_cluster.update_tp_turn_list` | `com.hkmc.cluster.NavigationCluster.updateTPTurnList` |
| `framework.navigation_cluster.update_tp_turn_list_new` | `com.hkmc.cluster.NavigationCluster.updateTPTurnListNew` |
| `framework.navigation_cluster.update_tp_lane_info` | `com.hkmc.cluster.NavigationCluster.updateTPLaneInfo` |
| `framework.navigation_cluster.update_tbt_trap_info` (optional) | `com.hkmc.cluster.NavigationCluster.updateTBTTrapInfo` |
| `framework.navigation_cluster.update_tbt_trap_info_new` (optional) | `com.hkmc.cluster.NavigationCluster.updateTBTTrapInfoNew` |
| `framework.navigation_cluster.update_clu_data_new_14` (optional) | `com.hkmc.cluster.NavigationCluster.updateCluDataNew_14` |
| `framework.tbt_trap_info` (`.new`, `.bar_graph_level`) (optional) | `com.hkmc.cluster.NavigationCluster$NaviTbtTrapInfo` |
| `iap2.init_info.check_supports_features` | `com.tcc.iap2server.Iap2InitInformationMsg.checkSupportsFeatures` |
| `iap2.service.on_create` | `com.tcc.iap2server.Iap2Service.onCreate` |
| `iap2.service_receiver.on_receive` | `com.tcc.iap2server.Iap2Service$1.onReceive` |
| `gpm.navigation_status.init` | `com.google.android.projection.protocol.NavigationStatus.init` |
| `gpm.navigation_status.next_turn` | `com.google.android.projection.protocol.NavigationStatus.navigationNextTurnCallback` |
| `gpm.navigation_status.next_turn_distance` | `com.google.android.projection.protocol.NavigationStatus.navigationNextTurnDistanceCallback` |
| `gpm.navigation_status.status` | `com.google.android.projection.protocol.NavigationStatus.navigationStatusCallback` |
| `gpm.receiver.send_navigation_focus` | `com.google.android.projection.protocol.GalReceiver.sendNavigationFocusState` |
| `gpm.receiver.destroy` | `com.google.android.projection.protocol.GalReceiver.destroy` |
| `dipo.iap2_proxy.stop_route_guidance` | `com.tcc.iap2.IIap2Service$Stub$Proxy.Iap2SvcStopRouteGuidanceUpdate` |
| `dipo.btcm.register_listener` | `com.broadcom.bt.hfdevice.hfbtcm.HfDeviceBTCMManager.registerHfDeviceStatusListener` |
| `dipo.carplay.session_created` | `com.daudio.app.dipo.telechips.CarPlayService.onSessionCreated` |
| `dipo.carplay.session_started` | `com.daudio.app.dipo.telechips.CarPlayService.onSessionStarted` |
| `dipo.carplay.session_finalized` | `com.daudio.app.dipo.telechips.CarPlayService.onSessionFinalized` |
| `dipo.carplay.iap_message` | `com.daudio.app.dipo.telechips.CarPlayService.oniAPSendMessage` |
| `dipo.utils.is_support_wireless_carplay` | `com.daudio.app.dipo.i.e.isSupportWirelessCarPlay` |
| `dipo.iap2_listener.connected` | `com.daudio.app.dipo.e.g.connected` |
| `dipo.iap2_listener.disconnected` | `com.daudio.app.dipo.e.g.disconnected` |
| `dipo.iap2_listener.notify` | `com.daudio.app.dipo.e.g.notify` |
| `dipo.session_listener.session_details` | `com.daudio.app.dipo.service.q.a` |
| `dipo.iap2.bt_address` | `com.daudio.app.dipo.e.b.K` |
| `dipo.bt.set_carplay_bt_address` | `com.daudio.app.dipo.f.c.o` |

`Car`, `Cluster`, and `NativePatch` consume supporting framework points from the same core map. A library recipe mismatch leaves that stock library unchanged and logs the failure; it does not prove that the corresponding feature works on KOR.

## Complete change/restore inventory

The three exact feature removal lines use `owns_lines.1` through `.3`;
`featurexml.cfg` is not whole-file owned. Runtime composition retains any other
module's distinct line patches on revert. The `wifi` built-in client exclusion remains
for the shared STA/AP radio; shared-file safety is enforced independently.

The package API must baseline each owned path before writing it, record applied bytes and metadata, bind baselines to `ro.build.product`, and verify exact restoration. `sg_revert_all` must preflight **all** targets for drift before the first restore write, refuse if any changed externally, retain baselines/ledger, and abort uninstall. Reapply/update must never replace the first baseline.

| On-car path or property | Apply and restore |
| --- | --- |
| `/system/onebin/<ro.mobis.onebindir>/featurexml.cfg` (`@onebin@` in `owns_lines`) | Comment each exact CarPlay wireless, AA wireless, and hotspot removal line if present. Restore original bytes/mode/owner. |
| `/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml` | Add if absent; restore exact bytes or absence. |
| `/system/etc/permissions/com.hkmc.software.connectivity.androidauto_wireless.xml` | Same. |
| `/system/etc/permissions/com.hkmc.software.wifihotspot.xml` | Same. |
| `/system/lib/libleafiaaac.so` | Put rebuilt converter; restore bytes or absence. |
| `/system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes/aa-tbt-48ee793a.recipe`, `aa-tbt-a0bea1c4.recipe`, `carplay-core-wifi.recipe`, `carplay-audio-formats.recipe`, `carplay-utils-converter.recipe`, `iap2-lane-msgid.recipe` | Put six recipes; restore each exact original or absence and remove newly created empty directories. |
| `/system/framework/hmg-seogaemo-wireless-parts.jar` | Put the mod jar for app parts (apps cannot read the core copy); restore absence. Not rewritten on reapply when identical. |
| `$SG_DATA_ROOT/core/hook/mods/wireless-carplay-and-aa/{hook.jar,entry,processes}` | `sg_hook_register`; restore absence, then `sg_core_hook_release` restores stock `app_process` when no hook module remains. |
| `/system/bin/app_process`, `app_process.hmg-seogaemo-stock`, `libhmg_seogaemo_wireless_hook.so`, `hmg-seogaemo-wireless-hook.jar`, guard files `enable`/`enabled`/`starts`/`disable` | Legacy (0.1.33 and earlier self-installed wrapper): kept in `owns_files` only so apply can restore them exactly before moving to the core host. The core host owns its own `app_process` swap and guard files under `modules/core-hook`. |
| `persist.ium.support`, `persist.sys.iap2.wifi`, `persist.iap2.iden.wireless` plus `/data/property/` backing files | Set `carplay`, `t`, `t`; restore live and backing state, including absent vs empty. |
| Potential `/data/dalvik-cache/system@framework@hmg-seogaemo-wireless-hook.jar@classes.dex` and `/data/data/com.daudio.app.dipo/app_hmg-seogaemo-wireless-dex/` | Android may generate optimized DEX. Package API must track and remove only this module's generated entries and restore any pre-existing bytes. Dalvik can regenerate cleanly after stock restoration. |

Not part of the firmware transaction but removed at revert through the package API
(`owns_generated_dirs`, advisory, never a conflict): the hook's own
`app_hmg-seogaemo-wireless-runtime` diagnostic directory and its
`app_hmg-seogaemo-wireless-dex` Dalvik output directory in each of `com.daudio.app.dipo`,
`com.tcc.iap2server`, `com.google.android.projection.sink`, `com.mnsoft.navi`,
`com.android.btsettings` and `com.daudio.app.phoneprojection`. Running apps rewrite them until the next restart, so the revert
records `restart-cleanup/wireless-carplay-and-aa` and boot reconcile finishes the removal. If the app_process swap has no
ownership record (stock backup or hook `.so`/`.jar` present, or an `app_process`
other than the declared stock MD5 `33f798115689d1859e8d2159dc88e7dc` seen on this car),
status, revert, whole-package restore and uninstall report one conflict naming all of
them and change nothing (`sg_zygote_foreign`). The wrapper's `starts`/`enable`/`enabled`/`disable`
files alone never conflict: restore sweeps them, and while the head unit has not restarted
since the revert the module reports pending-restart (`sg_zygote_guard_sweep`). Projection status uses a root Dalvik reader bounded to 15 seconds;
a timeout, a missing boot class path or malformed output reports `unknown`.

No stock app APK/odex, manufacturer native library file, `build.prop`, Wi-Fi client state, ADB property, firewall rule, or service is changed. Android user data created during phone sessions is outside this firmware transaction.

## Shared API integration

- `sg_zygote_install <wrapper-rel-src> <loader-rel-src> <jar-rel-src>`: one guarded ledger transaction. Validate the three relative payload paths and ownership, preserve original `/system/bin/app_process` to `/system/bin/app_process.hmg-seogaemo-stock` before replacing it, install the wrapper, loader and JAR with exact modes/owners, establish `enable`/`enabled` boot state, and prepare the 3-start/120-second guard. On any failure, roll back using the first baselines. `sg_revert_all` restores all six paths and guard state after full drift preflight. The wrapper always execs preserved stock even when preloading is disabled. The API must capture/export dynamic `starts` updates. The merged shared `common.sh` implements this transaction and records the dynamic `starts` counter before restore.
- `sg_dex_cache_track <system-jar> <app-package>`: before enabling, baseline any existing optimized artifacts attributable to this JAR globally and in the app's `app_hmg-seogaemo-wireless-dex` directory; record generated paths/bytes in the ledger after activation; `sg_revert_all` restores only them. The module calls it before `sg_zygote_install` for `/system/framework/hmg-seogaemo-wireless-hook.jar` and `com.daudio.app.dipo`. If tracking cannot be safe, fail the install before modifying `app_process`.

No direct `cp`, `mv`, `rm`, `setprop`, remount, service restart, or cache deletion occurs in this module root script. The module-local fake in `test/run.sh` checks the module sequence; the shared `tools/test-runtime.py` exercises the real transaction and restore implementation.

## Android Auto turn-by-turn UTF-8 length helper

The `aa-tbt-*` recipes carry a segment function (offset `0x17a`, 32 bytes, same in both stock variants; `r0` = bytes, `r1` = count, returns the count to pack, at most 96, clobbers `r1`-`r3`) that sizes the destination/turn strings packed into the NavigationStatus callbacks. Upstream HMG-API (1.0.2) walked back over trailing continuation bytes even for strings under 96 bytes, so the last Hangul syllable reached the cluster service as its lead byte alone (`우회쀀`, `U퀀` on the cluster/HUD). Now: up to 96 bytes the count is returned unchanged; longer, a character straddling the 96-byte boundary is dropped whole. Source `payload/recipes/aa-utf8-len.s` (assembled with clang, thumbv7) is the 32 bytes in both recipes. `test/aautf8/test.py` (run by `test/run.sh`) runs the recipe bytes and the old bytes in a small Thumb interpreter over every Hangul syllable, ASCII, mixed and 95-98-byte boundary strings and compares with a host model and Python's UTF-8 decoder. The recipes' `patched md5` header comment still names the upstream generation. Not verified on a car: the cluster/HUD display after this change.

## Android Auto lanes

Native (`aa-tbt-*.recipe`, source `payload/recipes/aa-lane-routes.s`, applied by `payload/recipes/apply-aa-lane-routes.py`): on NavigationState (msg 0x8006) the segment parses `steps[0]`; field 3 repeats the lanes, each lane's field 1 repeats the directions (`shape` varint 1, `is_recommended` varint 2). Up to eight lanes and three arrows per lane go into next-turn event 34 as `nn` lanes then `bbaaaaaa` per lane (lowercase hex): `bb` = mask of the arrow slots whose direction is recommended (bit k: slot k; upstream wrote 1, or 2 when any direction was recommended), `aa` = direction classes through the segment table (shape 1 straight 1, 2 slight left 8, 3 slight right 2, 4 left 7, 5 right 3, 6 sharp left 6, 7 sharp right 4, 8 and 9 U-turn 5; the same 1..8 as `CpTurns.laneIcon`; shape 9 used to drop out). A lane with no usable arrow is left out; no lanes sends `""`. The tail of the segment holds the extra code (the arrow store moves there); the segment grew by 28 / 26 bytes.

Java (`AaTurns.sendLanes`, `dipo/CpLaneFrame`): the arrows become the cluster's car-verified lane values exactly as CarPlay lanes do (status 2 bits per slot, component glyph pairs and triples from `CpTurns.LaneGlyphs`, [cluster-lane-arrows.md](cluster-lane-arrows.md)): drawn as the equivalent CarPlay lane through the same `CpLaneFrame.lane(arrows, onRoute, status)` (owner decision 2026-11-07: draw what the phone sends, the same on both projections): a lane with a highlighted direction is a CarPlay status 1 lane (the highlighted arrow white, the other arrows of that lane grey), a lane without one is status 0 (every arrow grey) while another lane of the frame is highlighted, and with no highlight anywhere nothing is flagged (status 1, every arrow white, as CarPlay draws a good lane with highlight 1000). Android Auto never produces blue: it has one recommended bit and no must-use level (CarPlay status 2). Upstream sent the raw lane byte (1 or 2) as the status, which draws only slot 0 and no glyph pairs.

**Root cause of "no lanes on the cluster/HUD" (offline; cluster ageing not yet seen on the car):** the lane frame went out once, when the phone sent a NavigationState, and was never sent again, while the turn and distance go out about every second and CarPlay's `CpTurns.refresh` re-sends its lane frame every ~1 s because the car's own navigation calls the cluster every 0.5-0.75 s and the cluster/HUD age out stale data. The same lanes from the phone were also skipped as duplicates. Now `AaTurns.laneTick` re-sends the frame every 750 ms while the route is live (not while rerouting), the lane distance box (`updateRemainDis`, next-turn distance, as CarPlay, owner decision in [cluster-lane-frame.md](cluster-lane-frame.md) 1b) is sent with it, and lanes that arrive before the active status wait for it. Lanes are cleared (empty frame, box back to 65535/15/15) on empty lanes, end of guidance and focus back to the car's navigation. The HMG Leafia Plus package (third party, reference only) reads the same event-34 string and post-processes the frame in Java (colours of a "recommended-lane" mode); its library patch is ours plus a raw NavigationState hex dump, not another lane reader.

**Which step owns the lanes.** The patched library reads the lanes of `steps[0]` only, the same step whose maneuver and distance the callbacks carry, so the lane box (next-maneuver distance) is always the distance to the lane point. HMG Leafia Plus r8.2 takes the first step *that has lanes* (a later step is possible there) and hides its distance box for lanes of a step after the first. We do not do that: the raw NavigationState is not available in Java (only event 34 and the dump `S `/`P ` text), a later step's lanes would sit under the wrong turn and distance, and a native change is a new code cave in a boot-critical library. Whether the phones we use ever send lanes only on a later step is unknown: the car check is in [backlog.md](backlog.md) (Android Auto guidance stability). If it happens, the least risky change is the recipe (steps loop) with the `test/aalanes` emulation, plus an explicit hidden box for lanes of a later step.

**Stability (`AaTurns.heartbeat`, `beat` every 1 s while a route is live).** Mirrors `CpTurns.refresh`: when the phone has been quiet for 900 ms the last turn goes out again (a car waiting at a light gets no new distance; the cluster and HUD age out stale data), and the HUD turn list is sent again unchanged after 2 s (CarPlay's HUD froze while only the distance moved). Not while rerouting (`RECALC_ROUTE` stays) and not while the car's navigation has the focus (`stop()`; the next turn event from the phone ends that). Guide-lost watchdog: with no library callback of any kind (turn, distance, trip, lanes, dump, status) for `GUIDE_LOST_MS` = 120 s while a route is live, the guidance is cleared exactly like status 2 (turn, trip, destination, HUD, lanes and box) and the heartbeat stops; if the phone speaks again without a new active status (it was only quiet) its next callback brings the route back, while a real status 2 or `end()` is final. 120 s, not r8.2's 60 s: no AA drive logs are in hand to show what the phones send at a standstill, a long red light can exceed 60 s, and the phone's own end status and the connection ending already clear the common cases; the watchdog only covers a phone app that stops without either. The quiet gaps the trace records tell whether to shorten it.

**Alternating turns (not implemented).** r8.2's `LeafiaTurn` arbitrates a legacy feed that alternates between two maneuvers (flip window 10 s, armed after 2 flips, then keeps the farther of the two fresh turns). Our feed is the same library callbacks (`next_turn`, `next_turn_distance`), so alternation could happen if the phone sends both the legacy NavigationNextTurn messages and a NavigationState and they name different maneuvers; the icon, bar and distance would then flip (`meters` resets on every changed maneuver). No log shows it. Arbitration is not ported until a drive does: the farther-turn rule is only right for r8.2's pattern. Developer mode (`persist.hmg_seogaemo.dev` 1) logs the evidence to logcat tag `AATRACE`: every changed maneuver (`turn ev= side= angle= road=`), `flip n` when a turn comes back within 10 s of another, `status n`, `quiet N ms, ended by <callback>` for gaps of 5 s or more, `quiet for N ms, the route is still live` at 30/60/90 s, `guide lost`, and a `state ...` summary every 5 s (call counts, quiet time, longest gap); at most 600 lines per route (plus the same again of status/flip/guide-lost lines), nothing with the toggle off. The `NAVDUMP` line (the library's `S `/`P ` message dump) is logged as before.

Tests: `test/cpturns` (`AaTurnsTest.lanes`: refresh, colours, glyphs, box, wait for status, clearing; `AaTurnsTest.guard`: heartbeat, watchdog, revival, focus on the car, rerouting, trace on/off/bounds), `test/aalanes/test.py` (patch sites and tail equal the assembled source in both recipes; with the python module `unicorn` it runs the real Thumb code on NavigationState messages and checks the event-34 strings). Not verified on a car: lane strip and box with a phone that sends lanes, the refresh interval, the colours.

## Copied source and AGPL notice

Copied HMG-API paths (destinations relative to this module's `payload/`):

- `mods/wireless-carplay-aa/src/hmgapi/mods/wireless/{Wireless,AaTurns}.java`, `dipo/{Bridge,CpTurns,Dipo}.java` → `src/hmgapi/mods/wireless/` as `.java.src`; `AaTurns` drops an HMG-API-only projection event and adds stock-format turns (our `AaGuidance`, `ApproachBar`).
- `core/runtime/java/hmgapi/hook/{Bridge,Hooks,Points,LoadedApp,MethodHook,ModEntry,ModContext,NativePatch,Car,Cluster,AppPartLoader}.java` → `src/hmgapi/hook/` as `.java.src`; four are trimmed, and new `HmgApi.java` replaces the generic loader.
- `core/runtime/java/hmgapi/engine/MemRecipe.java` → `src/hmgapi/engine/` as `.java.src`, unchanged.
- `core/loader/loader.c`, `core/zygote/zygote.c`, `core/loader/syslib-stubs.sh` → `native/`, modified for HMG-Seogaemo paths and without `hmgapid` spawning.
- `mods/wireless-carplay-aa/native/leafiaaac/{leafiaaac.c,build.sh}` → `native/`; output path modified. `data/libleafiaaac.so` is rebuilt from source, not an upstream binary copy.
- `mods/wireless-carplay-aa/recipes/{aa-tbt-48ee793a,aa-tbt-a0bea1c4,carplay-core-wifi,carplay-audio-formats,carplay-utils-converter}.recipe` → `recipes/`; `carplay-*` unchanged, the two `aa-tbt-*` recipes modified (UTF-8 length helper, below).
- `mods/wireless-carplay-aa/stubs/com/{broadcom,tcc}/...` (six Java compile-time signature stubs and README) → `stubs/` as `.java.src`, unchanged, not in the runtime JAR.

Original headers remain; modified files have a `Modified by HMG-Seogaemo` marker. Root `NOTICE.md` credits HMG-API (VysseCodes), NEMESIS (xwtk), HMG Leafia Plus, and Xposed design lineage. The repository is GNU AGPL-3.0 (`LICENSE`). The core mapper is an independent implementation; `UPSTREAM.md` tracks the HMG-API reference paths.

## Phone Projection menu

Status: implemented, off-car tested only (`test/projectionmenu`); needs the on-car check in `backlog.md`.

- **Stock.** `BluetoothSettings` menu case 8 ("Phone Projection") opens the wireless page
  (`iP.aQ` -> `wireless.WPPSettingsActivity`) whenever the `carplay_wireless` or `androidauto_wireless`
  feature exists, which our feature XMLs add. That page has no split-view option and lists only phones
  registered by PhoneProjection's wireless service, never ours, so on Korea it is effectively empty.
  With the wireless features absent, Korea (REGION 0) skips the Device Connections branch
  (US/Canada only) and calls `iP.aj` (verified in the stock `HKMC_BtSettings` smali).
- **`iP.aj` on this car** (`ih()` true, STEP_OF_SPEC 110): broadcasts `com.daudio.app.phoneprojection.command.launch`
  with `SSEARCH_TAB=1`; PhoneProjection opens `settings.ui.DeviceConnectionSettings` on the Android tab
  (`PhoneProjectionSettingsActivity` when `gb()` is true, or when `ih()` is false the activity directly).
  That is the connection screen where CarPlay/Android Auto is chosen.
- **Hook.** `Wireless.phoneProjectionMenu` on `open_wireless_page` (`ProjectionMenu.target`): Korea calls
  `open_other_page` (`iP.aj`) and swallows the wireless page; US/Canada keep Device Connections (else
  `open_other_page`); other or unknown regions keep the stock choice. Korea does not use
  `open_device_connections` (`iP.a(ctx,1)`): stock Korea never reaches it and it differs from `aj` when `ih()` is false.
  Existing points only, all mapped on NEEV KOR. Failure mode is the stock wireless page; nothing outside the hook changes.
- **Interaction with the CarPlay -> Android Auto switch** (`ProjectionSwitch`, `PpListener`): that listener hangs off
  the `phoneprojection` system service, not off a screen, so it works with either page. The reachable connection
  screen is now the Device Connections page, whose Android Auto/CarPlay choice calls the same `connectPP`/`disconnectPP`.
  Which row a bridged iPhone shows there is not known (the bridge registers no PhoneProjection record).
- Reference: the community HMG Leafia Plus r8.2 build ships the same behavior as a patched `HKMC_BtSettings`;
  only behavior was taken, we write nothing to BtSettings.

## On-car validation and recovery

Apply reconciles already-applied assets before returning
and status checks world-read/search bits. DiPO runs as UID 1000: readable recipe
files under a 0700 ancestor fail registration. HMG-API
`core/runtime/java/hmgapi/engine/LiveState.java` publishes readable recipes and
searchable ancestors; no additional audio properties or policy edits are needed. The upstream one-attempt NativePatch behavior remains: a failed native
write may be partial, so a full head-unit restart is required after repair.

After installing and applying, inspect these exact paths with `ls -ldn`:

```sh
ls -ldn /system /system/etc /system/etc/hmg-seogaemo
ls -ldn /system/etc/hmg-seogaemo/wireless-carplay-and-aa
ls -ldn /system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes
ls -ldn /system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes/*.recipe
ls -ldn /system/lib/libleafiaaac.so
```

Project directories should be 0755 UID/GID 0/0 and the five recipes/converter
0644 UID/GID 0/0; stock ancestors must permit traversal. Then fully restart and
test music, Siri and calls while checking native recipe logs. A readable recipe
and loaded zygote loader cannot prove the patch matched native memory. Existing
legacy directories have unknown creation provenance and retain their observed
metadata as the restore baseline, even if that baseline is 0700. Newly tracked
directories are removed only when empty and unchanged; unrelated contents block
cleanup and retain recovery material.

1. Before enabling, save a fresh Car Report and stock app_process, feature file/XML, three persistent properties plus backing-file presence, four `.odex` hashes, and any existing optimized DEX entries. Verify NEMESIS full-root ADB recovery works while Android is down.
2. Build locally, install through NEMESIS, run `hmg-seogaemo-root wireless-carplay-and-aa precheck` then `apply`. Export/review the change ledger. Confirm the stock ADB switch is `0`, then fully restart the head unit; ignition cycling alone may not restart Android.
3. Stream HMG-Seogaemo-Wireless, DiPO, Iap2, GPM and kernel logs. Test hotspot association/DHCP, wireless CarPlay music/Siri/calls, wireless Android Auto and a USB drive, cluster/HUD guidance, and native recipe messages. Status is `on` only with current validated zygote and all five app records, matching installed payload hashes, ready gates, loaded Java parts and applied native recipes (or GPM's explicit stock exemption). Loader mapping alone proves no readiness. Missing evidence is unknown; an older loaded generation requires restart. Status/export gathers bounded current app records and both log-ring halves through `sg_projection_runtime`; successful revert removes generated root diagnostics. Repeat after another boot and a package update.
4. Revert through `hmg-seogaemo-root wireless-carplay-and-aa revert`, export ledger, fully restart, compare every baseline byte/absence/property, and test stock wired projection. Uninstall NEMESIS package only after restore succeeds. Fake-root drift test must refuse before any partial restore.
5. On boot failure, after three unsuccessful zygote starts the wrapper should stop preloading and still exec stock. ADB/NEMESIS root can call the root dispatcher to revert, inspect/export ledger, then restart. If dispatcher is unavailable, use a saved ledger and stock executable through NEMESIS full-root recovery; never restore an older firmware's `app_process` over a newer one. The runtime owner must provide and test the exact emergency recovery command before release.

Off-car build/fake-root tests cannot prove Dalvik offsets, native recipe matches, wireless sessions or head-unit boot recovery; the on-car checks in this section stay required for each new payload.


## Switching from wireless CarPlay to Android Auto

Status: implemented, off-car tested only (`test/projectionswitch`); needs the on-car check in `backlog.md`.

- **Cause (stock NEEV KOR code, offline dump).** GPM answers a phone's wireless Android Auto start
  request with `STATUS_PROJECTION_ALREADY_STARTED` while `DiPOManager.getCurrentDiPOStat()` is above 0
  (`WirelessExplorer.handleStartRequest`; vtable@19 of `DiPOManager`). The bridge starts iAP2 as soon
  as a registered iPhone connects over Bluetooth, so DiPO's status goes 1 → 4
  (`tmp/car-sessions/2026-11-04-tbt/live/logcat-mac.log`, 22:48:34-39) and stays above 0 while the
  iPhone is near. The stock Phone Projection app asks PPService `connectPP`/`disconnectPP`
  (type 1 CarPlay, 2 Android Auto; transfer 1 wireless), and PPService passes them only to registered
  `IPPActionListener`s. On this firmware only GPM registers one; DiPO has none, so choosing
  Android Auto or disconnecting CarPlay never reached the bridged CarPlay. Upstream (HMG-API 1.0.2,
  Leafia) has the same bridge and no fix; Leafia #143 (CarPlay ignores a profile change, AA does not) is
  the same gap.
- **Behavior now.** The DiPO part registers a listener with `phoneprojection` (`Bridge.PpListener`).
  A wireless `connectPP` for Android Auto, or a wireless `disconnectPP` for CarPlay, while a bridged
  iAP2/CarPlay session is up sends `BT_DETACHED`, and `dipoIgnoreDisconnect` lets that end reach
  DiPO so it closes CarPlay as for a USB phone. That iPhone is then held off: no SPP connect, attach or
  re-attach after the session ends. A wireless `connectPP` for CarPlay releases the hold and connects
  it again. So does its next Bluetooth connection after its link went down (the next drive). While
  `GpmManager.isGpmActivated()` is true, the bridge starts no session. This mirrors GPM's rule:
  one projection at a time.
- **Known limits.** Phone Projection may send a wireless Android Auto `connectPP` by itself
  (auto-connection when an Android phone's Bluetooth connects). With two phones in the car,
  the Android phone may then take the screen from CarPlay. The hold lives in DiPO's process, so a
  head-unit restart also releases it. GPM may receive the phone's start request before DiPO's status
  drops to 0. In that case, choose Android Auto again.

## Wireless CarPlay call state (steering-wheel CALL)

Status: implemented, off-car tested only (`test/callstate`, `test/callkey`); needs the on-car check in `backlog.md`.

- **Cause (stock NEEV KOR code, car log 2026-11-10).** `HKMC_DiPO` `e/b.e(int)` (setStartiAP2Service)
  starts `Iap2SvcNowPlayingStart`, `Iap2SvcTelephonyStartCallState` and `Iap2SvcTelephonyStartUpdates`
  only when the transport is not Wireless (log `setStartiAP2Service transportType[1]` on the bridge).
  DiPO's caller list stayed empty while ringing and in a call (`getCallerList().size() : 0`,
  `CallerList getDirection() uuid is null`). The CALL key still reached DiPO
  (`ModeKeyDispatcher` → `DipoService.onKeyForService` → `performPhoneKey` → `performTelephony HookSwitch`
  press/release) on every press; answer and hang up worked, and an idle press did nothing on the iPhone.
  The `USE_SWRC_CUSTOM_KEY=true` CALL policy depends on that caller state.
- **Behavior now.** After the CarPlay-channel session's identification is accepted, the bridge
  starts both telephony subscriptions itself (`CallState`, `Bridge.startCallState`): once per
  session, 500 ms after the identification, each subscription tracked separately, up to 3 tries,
  stale tries of an earlier session ignored. DiPO's own listener parses the notifications as on USB.
  The result is in the module log (`CarPlay call state: ...`).
- **CALL with no call (car log 2026-11-10).** DiPO sends HookSwitch press/release in every state and
  the iPhone ignores it with no call, also after the call-state subscription. The stock Phone app opens
  CarPlay's Phone app another way: ModeManager starts `DipoActivity` with int extra `CarPlayMode=2`,
  `DipoService.updateDisplay(2)` → `displayPhone()` → `requestUI("mobilephone:")`. The bridge hooks the
  optional point `dipo.carplay.telephony` (`CarPlayService.onTelephony`) and, on a wireless HookSwitch
  release while `DiPOManager` stat is 1 and `DiPOMode` phone call and speech are 0 (phone call is 1 from
  ringing to hang-up), starts that same activity intent (`CallKey`). HookSwitch still goes to the phone.
  Each release is logged (`CarPlay CALL key: ...`). Point unmapped or failed: the key stays stock.
- **Open.** On-car: the subscription log line, the Phone app opening with no call, answer/hang-up
  unchanged, and whether the earlier intermittent "CALL does not answer" recurs. NowPlaying is skipped
  on wireless the same way and is not started here.

## CarPlay turn-by-turn: lane fix, fallback icons, developer toggle

- **Stock-format guidance (always on with TBT).** Inside the approach window (300 m ordinary
  turns, 600 m ramps/exits/keeps/highway changes) `CpGuidance` maps the CarPlay maneuver to the
  stock `DisplayType`/direction, which switches the cluster to its AR view and the HUD to its
  hologram; outside it, or with ambiguous geometry, the projection icon stays. Loading /
  rerouting send stock types 9 / 10. `CpTrapOverlay` (navigation process) lays the approach bar
  over the latest real stock trap record under a 3.5 s lease renewed by DiPO. `CpJunctions`
  picks the HUD junction view from the generated `CpJunctionTable`. Android Auto: `AaTurns`
  applies the same windows through our `AaGuidance` (event + side; no junction pictures) and
  renews the bar lease through `ApproachBar` from GPM. Details:
  [cluster-ar-view.md](cluster-ar-view.md), [hud-hologram.md](hud-hologram.md),
  [hud-junction-view.md](hud-junction-view.md).
- **Lane guidance (our own raw 0x5204 decoder).** Bridge forwards CarPlay-channel bytes unchanged,
  then feeds the bounded, Android-free CpLaneDecoder and posts decoded data through Dipo.post
  to the TBT handler. Link/control messages may be split or coalesced; link/header checksums,
  TLV lengths, scalar widths, eight lanes and sixteen signed angles per lane are checked.
  Invalid messages are ignored with one essential error line per 30 seconds. Description bytes
  are counted only. Wire references: carplay-tbt-external/iap2-protocol.md; this is our own
  implementation, with no third-party source copied.
  CpTurns retains the last sixteen entries keyed by component and LaneGuidanceIndex, since
  lane windows arrive before the route update. Only the current 0x5201 p16 entry is displayed
  while p18 is true and state is nonzero (the maneuver-count/state show gate also applies).
  No fallback to another index or 0x5202 linked lane is used. Missing current entries and hidden
  lanes blank the old frame; state 0, stop, disconnect and source changes clear the cache.
  The decoded lanes produce the 81-byte 0xF1 frame; highlight 1000 means none. Invalid angles
  produce no arrow. A lane's angles
  become distinct direction classes (the `laneIcon` thresholds); one class keeps the plain 1..8
  glyph, two or three use the car-verified component glyph pair/triple from `CpTurns.LaneGlyphs`
  ([cluster-lane-arrows.md](cluster-lane-arrows.md)), whatever order the phone lists the angles.
  A set not in the table is retried with slight/sharp turns snapped to plain left/right; if it
  still does not match (or has more than 3 directions) only the highlighted arrow is drawn as a
  single glyph, else the first. The status byte is 2 bits per slot (`00` blank, `01` white, `10`
  blue, `11` grey), following the arrow each slot shows, and draws what the phone sends per lane
  (`CpLaneFrame.lane`, also used by Android Auto), from its LaneStatus and highlight angle: status 0 (not
  good) every arrow grey; status 1 (good, the recommended lanes) the highlighted arrows white and the
  rest grey; status 2 (preferred, the lane the driver must use for the maneuver) the highlighted
  arrows blue and the rest grey; with no valid highlight (1000, or no angle matches) every arrow
  takes the lane's colour. Blue only comes from phone status 2, by owner decision: NAVER sends
  status 1 on most recommended lanes and status 2 only on the lane that must be used, and that
  difference stays visible (recorded 2026-11-05/07 drives: every status 1 or 2 lane carries a
  highlight equal to one of its angles, every status 0 lane has 1000). A lane with no usable angle sets
  slot 0 only. U-turn + left, status 1, highlight -90: arrows `0a 0e`, status `0x07` (status 2:
  `0x0b`; status 0: `0x0f`). The old `lanes` setting modes (`off`/`rec`/`dim0`/`dim3`) were
  removed. While a frame with lanes shows, `NavigationCluster.updateRemainDis(dist, unit, tenths, 0)` carries the distance to
  the next maneuver (the turn's distance and unit; feet and yards as metres; resent every 2 s,
  `65535, 15, 15, 0` when lanes go away, where the empty lane frame removes the box anyway; no toll-gate flag; the box always shows the next-maneuver distance by owner decision, [cluster-lane-frame.md](cluster-lane-frame.md) 1b). The trailer bytes 0x43..0x50 stay
  zero. Not yet seen on the car with this build. Refresh resends
  the last frame. tbt-lanes records contain raw numeric lane fields, description byte count,
  current index/count and all 81 frame bytes. Developer mode logs entries and index matches.
  0x5204 has no distance; route updates supply it.
  **Keep the stock parser disabled** (redirecting 0x5204 to libiap2session's lane handler crashes
  libIap2Acc.so in convertSubGroup). The unused iap2-lane-msgid.recipe remains
  packaged/owned for compatibility with existing baselines; Wireless.iap2 never applies it.
  No mods class implements a hook interface; the Dalvik cross-dex rule below still applies.
  Physical cluster/HUD rendering, per-app ordering and source transitions need on-car checks.
  Stock navigation's own lane frames are not recorded: the 81-byte layout, status bits, arrow
  codes and trailer bitmasks come from the firmware analysis and car-verified frame injection
  (`cluster-lane-frame.md`, `cluster-lane-arrows.md`). CpTurns.laneIcon is the single
  angle-to-stock-arrow mapping function.
- **No silent skips.** An unmapped maneuver uses
  `fallbackIcon` (direction arrow, else straight) and logs `no exact icon for maneuver type ...` once per combination. A missing maneuver
  still sends HUD distance and trip, and asks the phone to resend (Stop then Start), at most once in 30 s.
- **Developer toggle.** Verbose TBT / iAP2 logs (`TBT ...`, `bridge: iAP2 in ...`, `TBT cluster ...` traces) follow the property
  `persist.hmg_seogaemo.dev`, read every 3 s, so no restart. Off (default) keeps only one-line state and failures. From adb, with full root:

      adb shell cp /system/xbin/nemesis /data/local/tmp/nemesis-d
      adb shell /data/local/tmp/nemesis-d root -c 'setprop persist.hmg_seogaemo.dev 1'   # on
      adb shell /data/local/tmp/nemesis-d root -c 'setprop persist.hmg_seogaemo.dev 0'   # off
      adb shell getprop persist.hmg_seogaemo.dev
      adb logcat -s HMG-Seogaemo-Wireless:*
- `Wireless.NAVI_TBT` also skips the car navigation's `update_lane_info` while a phone guides (its free-drive writes would overwrite our lane frames).
- **Observation records.** `tbt-icons.*` / `tbt-lanes.*` (summary + about 10 MiB of append-only journals, with the phone's instruction texts; kept permanently so the icon table keeps improving) in DiPO's runtime directory, format and the `tbt-reset` verb in
  "Turn-by-turn observation records and `tbt-reset`" below. The module page shows `info.tbt_inexact` / `info.tbt_blank`
  and a confirmed reset. Match kinds: `exact` (table), `band` (types 1/2/47-50 by angle), `angle` (any other type by angle,
  roundabouts by nearest exit icon), `semantic` (type only, e.g. keep left/right, enter roundabout, arrive), `blank` (icon 64: distances, lanes and
  trip still go out). Fallback never uses "straight" for a turn. A 1 s refresh (`CpTurns.refresh`) resends the last state while guidance is active;
  evidence for it: the car's own navigation calls `updateTBTSubInfo` every 0.5-0.75 s, and no keep-alive or handshake call is documented
  in the API inventory (`updateAlive` exists but phone guidance deliberately never claims the cluster).

- **Dalvik cross-dex rule.** The hook classes (`hmgapi.hook.*`) are loaded in the zygote from the
  boot-time jar, while each app's mods are loaded from its own dex copy. A mods class that *implements a new hook-package interface*
  is pre-verified against the copy in its own dex and then fails to link at runtime ("Class resolved by unexpected DEX" →
  `NoClassDefFoundError`), which takes down the whole DiPO part (`part.dipo=failed`, no wireless CarPlay; seen on the car 2026-11-04). Do not add callback
  interfaces in `hmgapi.hook` for mods to implement; use static fields/flags or existing types (`MethodHook`, `Runnable`).
  Check with `dexdump` that no new `hmgapi/mods` class has a `hmgapi/hook` superclass/interface other than `MethodHook`.
- **HUD list resend.** `CpTurns.refresh` resends the unchanged 0xF2 HUD list every 2 s (`HUD_RESEND_MS`),
  independent of phone updates, because the HUD distance (`update_tbt_sub_info_2c`) goes out every push while
  the list is sent only on change with no delivery signal; `hudBlank` clears it. Car-verified at 0.1.28
  (2026-11-05): HUD arrow and road text no longer froze during a NAVER Map drive.

## Runtime contract details

### Zygote payload upgrades

`sg_zygote_install` compares the selected wrapper, loader and JAR on every
apply, including desired-on reconciliation after OTA and NEMESIS USB postinstall.
An applied install may advance only from its recorded applied bytes/metadata;
unknown drift conflicts before any payload write. The stock executable backup
and every original file baseline remain immutable through all generations.
A durable `zygote-upgrade` journal publishes intended bytes/metadata before
mutation. Guards also recognize those intended states after interruption, so
retry converges and stock restore can undo a partial upgrade. A different
selected generation during a pending upgrade is refused; restore or resume the
same selected payload first. The journal remains until all new applied markers
and ledger entries are committed.

Upgrade captures then invalidates tracked Dalvik caches, writes loader and JAR,
and atomically replaces the wrapper last. It records restart-required before
the first mutation; the old running zygote still holds its previous inodes.
Cache deletions remain journaled until their applied-absence markers are
committed, including paths no longer visible in cache globs after interruption.
No zygote service restart is performed. A same-payload reapply makes no payload
or cache writes. Projection reapply reasserts all three owned properties using
`sg_prop_set`; status checks all three.

(OTA rollback and update-health interaction: [ota-implementation.md](ota-implementation.md), "Entry dispatch and damaged-payload recovery". Uninstall always restores ORIGINAL stock, never the previous applied generation.)

### Unrecorded `app_process` swap

`sg_zygote_foreign` is a read-only guard for a module that owns
`/system/bin/app_process`. The swap counts as owned when the module holds a file
baseline for it (or an upgrade journal). Without that record nothing we wrote is
recoverable, so the guard returns conflict (3) when any of exactly these exists:
`app_process.hmg-seogaemo-stock`, our hook `.so` or `.jar`, or an `app_process`
whose MD5 differs from the module's `known_stock.N=<ro.build.product glob>:<path>:<md5>`
declaration for the current product (no matching declaration means no judgment).
Every offender is listed on the single `info.restore_conflict` line.

The wrapper's own guard state in the module state directory (`enable`, `enabled`,
`starts`, `disable`) is not evidence. The live wrapper recreates `starts` after a
revert (its watcher opens it with `O_CREAT`, up to 120 s after the zygote started),
`touch disable` is its documented manual off switch, and a car may hold stale files
of an earlier install. `sg_zygote_guard_sweep` removes exactly those four names
(never anything else, one ledger row `zygote_guard_sweep` each) while the module has
no swap record and `sg_zygote_foreign` passed; a directory in their place is a
conflict. `sg_revert_all` (module revert, whole-package restore, the NEMESIS uninstall
hook), the `lib/stock.sh` "nothing applied" path and the wireless fresh `apply` call it,
so stale guard files are never recorded as stock originals either. Module `status`,
`precheck` and the stock preflight only read.

A revert that restored an applied `app_process` leaves the running zygote on the
wrapper until the head unit restarts. `sg_revert_all` therefore records the
per-module restart marker (`sg_restart_required`, best effort) after such a restore;
while `sg_restart_pending` holds (same kernel boot), the wireless module's `status` and
`revert` and the stock restore report `pending-restart`/`head_unit`, not `off` and not a
conflict, even if the wrapper meanwhile recreated `starts`.

`sg_revert_all` calls the guard first, so module revert, whole-package restore and the
NEMESIS uninstall hook refuse on real evidence; `lib/stock.sh` also runs it in the
all-module preflight and for modules with no snapshots, before anything is reverted.
Module `status`, `precheck` and `apply` report the same conflict. Nothing is modified,
no desired state changes, and the owner resolves it (for example by restoring stock from
the saved copy) before retrying. The wireless module declares the product-scoped
`stock_file.1=NEEV.KOR.*.260902:/system/bin/app_process:33f798115689d1859e8d2159dc88e7dc`
(installed as the same `known_stock.1`; `cars=*`)
(the stock build seen on the Ioniq 5 KOR car before and after HMG-API/this module) and
`stock_file.2=CN7.KOR.*.260902:/system/bin/app_process:<same MD5>` (the same build, read from the
contributor's decrypted CN7 `260902` firmware image on 2026-11-09, not yet seen on a car). CN7N `260319` has
no declaration yet, so the guard makes no MD5 judgment there.
The apply-path orphaned-backup check remains.

### Runtime results and diagnostics

The hook publishes diagnostics independently of loader mapping. Zygote (UID 0)
uses `/data/nemesis/backup/hmg-seogaemo/runtime/wireless-carplay-and-aa/`.
Each hooked app uses `Context.getDir("hmg-seogaemo-wireless-runtime", 0)`, normally
`/data/data/<package>/app_hmg-seogaemo-wireless-runtime/`, owned by that app's UID
(DiPO commonly UID 1000). No app writes into root's private state and no shared
world-writable directory is needed. These are generated diagnostics, never stock
baselines or an authorization channel. Root prepares the private runtime parent
through the package API before enabling the loader. Root reads only the fixed projection app
packages: `com.daudio.app.dipo`, `com.tcc.iap2server`,
`com.google.android.projection.sink`, `com.mnsoft.navi`, `com.android.btsettings`,
`com.daudio.app.phoneprojection` (no parts of its own; it loads `usb_hotspot` with a USB hotspot, else `stock_hotspot`).

Each process writes `p-<pid>-<start_ticks>.txt` atomically via `.txt.tmp`.
UTF-8 `key=value` lines, first `=` is the separator; keys `[a-zA-Z0-9_.-]+`,
no escaping, duplicate keys/control characters/unterminated records rejected.
Values are sanitized to one line. Format 1 metadata: `format=1`, `boot`, `pid`,
`start_ticks` (field 22 of `/proc/<pid>/stat`), `uid`, `package`, `process`,
`payload_jar_sha256`, `payload_loader_sha256`. Payload hashes are captured in
zygote before forks, identifying the loaded generation even after an OTA replaces
disk files. Zygote writes `gate.state=initializing|ready|off` and `gate.reason`
for its identity/map/seal/stock-hash/boot-hook decision. App records inherit
`gate.state`/`gate.reason` from the zygote;
`part.<name>.state=initializing|loaded|failed|off`, `.reason` and `.missing`
describe Java installation. Parts are `dipo`, `iap2`, `gpm_usb`, `gpm_tbt`,
`navigation`, `btsettings`; `.missing` lists absent stable IDs, comma separated.
`native.<library-basename>.state=registered|applied|failed`, `.reason` and
`.errno` describe recipe registration and the single native apply attempt.
Registration is waiting for a library, never proof of application. Errno 0
means no syscall error captured; failures include numeric errno and common
symbolic names (e.g. `13:EACCES`). Errors may follow partial hook/native writes;
restart, never retry native writes in the same process. `event.*` holds bounded
late failures (e.g. iAP2 bind/cluster/callback errors).
For stock GPM turn-by-turn (`stepofspec >= 999`),
`native.libautoreceiver_infobank.so.applicability=stock` and the part reason
explicitly identify why no AA recipe is registered.

Snapshots are capped at 64 KiB, 256 fields, 8192 characters/value. The reader
rejects oversized/malformed records. The process also mirrors Java tag messages
directly into `p-<pid>-<start_ticks>.log`, rotating to `.log.1` at 64 KiB
(each message capped at 2048 characters), preserving them before logcat wraps.
This keeper requires no logcat reader thread or service in zygote. Native startup
messages preceding Java initialization remain logcat-only; native recipe failures
are also recorded through Java. Retain at most eight process stems per directory,
including stale boots and interrupted temporary files; oldest artifacts are pruned
on publication (best effort across simultaneous processes). Files are 0600,
directories 0700; root can include them in a future export. Diagnostic
I/O/permission/storage errors are caught and never stop or enable hooks. Missing
diagnostics therefore mean unknown readiness, never success. Cleanup/export wiring
belongs to the root consumer; app-private files may survive module revert.
At status/export time root gathers only validated current app-private files from
those fixed packages into `$SG_DATA_ROOT/runtime/wireless-carplay-and-aa/apps/<package>/`.
Use bounded reads/copies (64 KiB/file), reject symlinks/nonregular files/incorrect
UIDs, and never trust paths from the record. The collector includes `.txt` and
`.log`; include `.log.1` for the older half of the ring. Across all packages
select at most 32 current files for export. Stale boots/PIDs must not replace
current failures.

Status must check expected boot, live PID/start ticks, expected UID/package/process,
loaded payload hashes versus installed payload, `gate.state=ready`, and all relevant
parts/native results. Absent processes/results are pending/unknown; a gate/part/recipe
failure must not be reported as on. `part.*=loaded` means initialization returned,
not a successful wireless session. In particular Core/Audio/Utils in DiPO and AA
in GPM must be applied (or explicitly deemed inapplicable by the consumer) before
claiming those native capabilities. Reject symlinks, nonregular files and unexpected
ownership; never source/eval the record as shell. These app-owned reports are
diagnostic evidence, not a defense against a compromised OEM app. Seal validation
still checks only `product\nhash-id\n`; additional seal lines remain compatible.

#### Turn-by-turn observation records and `tbt-reset`

DiPO keeps two always-on, bounded turn-by-turn records in its app-private runtime directory,
`/data/data/com.daudio.app.dipo/app_hmg-seogaemo-wireless-runtime/`: `tbt-icons.*` (which icon
each maneuver combination got, with the phone's instruction text) and `tbt-lanes.*` (lane data
seen and the 81-byte frame sent). Purpose: build the maneuver → icon table from real drives (the
iAP2 maneuver list is MFi-only). The data stays on the head unit and leaves it only when the user
exports logs and shares them; instruction texts may contain road names. They are generated
diagnostics: not a baseline, not ledgered, not an authorization channel. Files are UTF-8, 0600,
owned by the app UID.

- **Summary** `tbt-icons.txt` / `tbt-lanes.txt`: `format=2`, `kind=tbt-icons|tbt-lanes`, then one
  line per key `key|detail|count|first_ms|last_ms|samples` (epoch ms; `samples` = up to 3 distinct
  instruction texts joined by ` ¦ `, each at most 80 characters, empty for lanes; `|`, `¦` and
  control characters never occur in a field; key/detail at most 400 characters). Readers also
  accept the 5-field `format=1`. At most 1024 (icons) / 512 (lanes) keys and 1 MiB: at the limit
  the least-used, then oldest keys are evicted. Rewritten atomically (`.txt.tmp`, rename) at most
  every 5 min and at route end; read back at the next start so counts and texts survive restarts.
  Only this summary-sized aggregate is held in DiPO's memory.
- **Journal** `tbt-icons.journal` (+ `.journal.1` … `.journal.5`) and `tbt-lanes.journal`
  (+ `.journal.1` … `.journal.3`), oldest last: every sighting appended as
  `ms|key|detail|sample`, never rewritten, flushed at most every 30 s (sooner past 32 KiB pending)
  and at route end. A shard rotates at 1 MiB and the oldest is deleted, so the journals stay within
  6 + 4 MiB (about 10 MiB in all). A torn last line after a crash is ignored by readers.

Icon key `type=<n> junction=<n> side=<n> exit~<deg rounded to 15>` (plus `state=<n>` for type 12),
detail `icon=<n> kind=exact|band|angle|semantic|blank exit=<exact deg>`, sample
`<instruction>[ -> <road after>]`. Lane key `n=<lanes> [s<status> a[angles] h[highlight]]...`,
detail `sent= marks= frame=<all 81 bytes sent, hex> laneIndex= laneCount= distNext= nextStr=`.
The files are not pruned with the per-process `p-*` stems and are not copied by `status` (too
large for the per-status gather). The exporter (`lib/diagnostics.sh`) copies the fixed names
directly from DiPO's directory into `diagnostics/tbt/`, whole up to 1 MiB + 64 KiB each, outside the
32-log budget and without line redaction (generated data, no credentials). Revert cleanup removes
them as plain regular files of `owns_generated_dirs` (well within its 64-file limit).

Status gains two optional read-only lines, computed by the same bounded reader run that
produces the status (no extra process): `info.tbt_inexact=<N>` (combinations whose `kind` is not
`exact`) and `info.tbt_blank=<M>` (of them, `kind=blank`), digits only, both or neither; absent
when the records cannot be read safely. Old consumers ignore them; the app treats absence as
unknown.

New fixed verb, only for `wireless-carplay-and-aa`: `hmg-seogaemo-root wireless-carplay-and-aa tbt-reset`
(exactly this argv; any other module or argument is `Invalid command`, exit 2). It takes the
operation lock, writes no journal or desired state, and runs `sg_projection_runtime tbt-reset`,
whose root reader deletes only `tbt-icons.txt`, `tbt-lanes.txt`, their `.tmp` and the fixed journal
shard names above in DiPO's runtime directory: every candidate must be a plain regular file owned by the app UID in a directory
owned by it (lstat; symlinks, other types and foreign owners refuse the whole reset before
anything is deleted). Output is the usual three lines (`state=on|failed`, `restart=none`,
`detail=removed N files`); nothing else is touched.

The consumer uses `sg_projection_runtime prepare|status|applying|clear` in the
package API, restricted to the projection owner. `prepare` creates the runtime
parent and module directory as root:root 0700 before loader installation. The
API invokes the packaged API 19 Java reader (SHA-256 through MessageDigest,
KitKat libcore lstat for UID/type); it never executes record contents. Expected
app UID comes from the fixed package's data directory, and proc UID, cmdline,
record process and start ticks must agree. Only the package main process or its
colon subprocesses qualify. Every current record is considered, so a ready
record cannot hide another current failure. Zygote plus all six packages and
their relevant parts/native recipes are required for `on`. Missing evidence is
`unknown`; an apply receipt uses `pending-restart` for missing evidence so the
dispatcher can retain enabled intent. Old loaded hashes mean `pending-restart`.
A fresh apply also records the boot id (`assets-repaired-boot`, the restart marker):
until the boot changes, the running zygote is the stock one, so module status stays
`pending-restart`/`head_unit` even with no or stale records. `unknown` is reserved for
missing evidence after a restart. The app shows the observed state (pill, tiles) and
offers a confirmed head-unit restart on the pending-restart notice.

Collection replaces only generated app copies, never baselines, with at most
32 files of 64 KiB across the fixed packages; malformed, stale, aliased or
incorrectly owned inputs are omitted. Current old-generation records remain
exportable as restart evidence. `clear` removes the generated root module tree
after successful revert (including an already reverted module), and removes an
empty runtime parent. App-private originals may remain. Export probes status
first, then includes the fixed app-copy depth and `.log.1`.
The reader runs with `ANDROID_DATA` fixed to the module's private `vm/` tree,
including its 0700 root-owned `dalvik-cache/`, so executing the reader never
leaves a global Dalvik cache entry. Successful clear removes this generated
cache along with the diagnostic copies.
The fixed reader artifact is checked beneath the canonical selected package
directory, allowing OTA's `update/current` package pointer.

The reader is a root Dalvik process that can hang, so the API never runs it
inline. It requires a non-empty `BOOTCLASSPATH` (the inherited value, else the
`export BOOTCLASSPATH` line of `/init.environ.rc`; the value must start with
`/system/` and use only path-list characters) and otherwise reports
`state=unknown` without starting the VM. It starts the reader in the background
with stdout and stderr in private files directly under the data root, waits with
`sg_bounded_wait <pid> <seconds>` (1-second polls, 15 seconds by default,
`SG_READER_TIMEOUT` for tests, capped at 120), and on expiry kills the reader and
its whole process tree and returns 124. `sg_kill_tree <pid> [depth]` is a subshell
function: it snapshots toolbox `ps` (PID/PPID fields), collects target and all
descendants (default depth 3) before signalling anything, sends TERM to every
member, waits one second and sends KILL to every member, so no member is
skipped when an intermediate process ignores TERM or children are reparented.
The following `wait` on the target returns once KILL is delivered.
Output must be exactly one `state=`, `restart=` and `detail=` line with a known
state/restart pair and a clean exit (1 only with `state=failed`); anything else,
or a timeout, is `state=unknown` (`pending-restart`/`head_unit` for `applying`).
`status` therefore never keeps `operation.lock` longer than the limit. Hang-up, interrupt
and termination of the caller run the `EXIT` trap, which kills the reader's whole tree with
`sg_kill_tree` (also `core/update.sh` and `core/hmg-seogaemo-map.sh` for their VMs, whose
verifier runs as a direct child of the updater shell so the trap can reach it) and removes
`reader.out.<pid>` and `reader.err.<pid>`. A run killed before its trap leaves them behind;
the next run deletes exactly `reader.{out,err}.<digits>` files in the private data root whose
PID is not alive. `clear`
that cannot run the reader (timeout, no boot class path, exit 126 or above)
removes the root-only generated tree directly; a reader refusal (exit 1) still
fails. `sg_bounded_wait` and `sg_kill_tree` are generic and are also used for the
mapper and the update verifier. Callers under `set -e` must write
`sg_bounded_wait ... && code=0 || code=$?`.
