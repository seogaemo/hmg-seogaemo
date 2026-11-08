Status: current — implemented off-car; built-in STA car-verified as wifi-client (2026-11-03); USB roles and the takeover unverified on the car.

# wifi module (former wifi-client)

"Wi-Fi off" has three meanings: the chip/radio, the Android client (STA) and its Settings menu, and the
hotspot (AP) used by wireless CarPlay/Android Auto. The `wifi` module gives each radio one role.

## Roles

Settings (`setting.1`/`setting.2`, changed with `hmg-seogaemo-root wifi set <key> <value>`, which reverts and applies
again while the module is on):

| Setting | Values (default first) | Effect |
| --- | --- | --- |
| `builtin_role` (stock Broadcom `wlan0`) | `client`, `off`, `carplay_ap` | `client`: the former wifi-client behaviour below; `off`/`carplay_ap`: untouched (`carplay_ap` publishes the stock hotspot as the CarPlay hotspot) |
| `usb_role` (Realtek adapter, `rtwlan0`) | `off`, `client`, `carplay_ap` | `client`: driver + `wpa_supplicant -Dnl80211` + `dhcpcd`; `carplay_ap`: driver + `hostapd` (nl80211) + `dnsmasq` on `192.168.50.1/24` + `iptables -t filter INPUT -i rtwlan0 -j ACCEPT` |

- Only one radio may be `carplay_ap`: `setting-ok` (called by the dispatcher before `set` saves), `precheck` and `apply`
  refuse it (conflict).
- `builtin_role=client` without `usb_role=carplay_ap` leaves wireless CarPlay without a hotspot. `apply` and
  `setting-ok` refuse it while `wireless-carplay-and-aa` is desired on; `precheck` only warns (`warn.carplay_active`)
  because the app's plan (`ModuleManager.hotspotConflict`) turns CarPlay off first, and turns `wifi` off when CarPlay is
  enabled under that configuration (the former static `not_with` exclusion, now role-dependent). The CarPlay module
  checks the same on its side: its `apply` refuses, its `precheck` warns (contract "Peer info").
- The default keeps the old behaviour: an updated car with wifi-client on becomes `wifi` on with `builtin_role=client`.

## Built-in client role

- Owns `/system/etc/permissions/android.hardware.wifi.xml` (`owns_files`, `sg_file_put`) and `persist.wifi.state`
  (`owns_props`, `sg_prop_set ... 3`). Claims no `featurexml.cfg` line.
- precheck, status and apply refuse an existing XML or a non-empty `persist.wifi.state` the module did not write.
  HMG-API presence alone is not a conflict (its wireless mod owns neither target).
- `status` reports `info.client_ip` and `info.client_adb_endpoint` for any non-hotspot IPv4 address on `wlan0` (mksh
  builtins only). The PackageManager `android.hardware.wifi` feature separates "applied, awaiting reboot" from
  "observed". Switching the role away while the module stays on reports `pending-restart` without `info.desired=off`.
- Once applied (and after the head-unit restart) the detail offers the stock Wi-Fi screen (`open screen=wifi_settings
  when=builtin_client`). `restart=head_unit`; `persist.wifi.state=3` has no known reader on this firmware.

## USB roles

- Detection is read-only: `/sys/bus/usb/devices/*/idVendor`+`idProduct` against `files/usb-ids.txt`, taken from
  `rtw_usb_id_tbl` of the pinned driver sources for the built chip only (88x2bu: `CONFIG_RTL8822B`, 17 ids; 8851bu:
  `CONFIG_RTL8851B`, 3 ids). The match picks the kernel module; `sg_kmod_load` picks `kmod.<name>.<ro.board.platform>`
  (`tcc803x`/`tcc897x`). Drivers ship in `files/kmod/<platform>/` with `files/kmod/SHA256SUMS`, equal to
  `kernel/usb-wifi/out/SHA256SUMS` (debug info already stripped by `arm-eabi-strip --strip-debug` in
  `kernel/usb-wifi/build.sh`; the module test checks hashes and vermagic). The four drivers make the bundled package
  about 16.6 MB of the 16 MiB extractor cap; another driver needs a per-platform split.
- Every USB effect is a transient runtime record (contract "Transient effects"): gone at a restart, made again by boot
  reconcile (apply) and by the `screen_on` watch (`rerun_on=boot,screen_on`), which also brings a replugged adapter back.
  An absent adapter is not an error (`state=on`, detail "USB Wi-Fi adapter not connected"). A failed USB step runs
  `sg_revert_transient` (module on) or `sg_revert_all` (first enable).
- Client: `usb-wpa.conf` in the module state holds `ctrl_interface=<state>/wpa` and the chosen network. The app's picker
  runs `action wifi_scan` (needs `/system/bin/wpa_cli`, absent on the owner's car; then only "Other network" with a typed
  name works) and `action wifi_join`, which reads the fixed app file `files/wifi/usb-join` (`ssid=<hex>`,
  `psk=<64 hex>|none`; the app derives the WPA key with PBKDF2 so no passphrase reaches root) and restarts
  `usb-wpa`/`usb-dhcp` with `sg_daemon_restart`. DNS and routing beside the stock connectivity stack are unverified.
- CarPlay hotspot: SSID `HMG-Seogaemo-<4 hex>` and a 20-hex passphrase from `/proc/sys/kernel/random/uuid`, kept in the
  module state (`usb-ap`); `hw_mode=g`, 2.4 GHz channel 6 (`ap_channel`; 5 GHz channel 36 made hostapd exit on the tester's RTL8831BU), `country_code=KR`, WPA2-PSK CCMP, `rtwlan0` up with `192.168.50.1/24` before hostapd starts, hostapd run as `wifi` in its own run directory. Published with
  `sg_peer_publish` (contract "Peer info").

## UI

`ui.txt` shows one role row per present radio (`choice ... when=builtin_present|usb_present`), the network picker
(`open screen=wifi_networks when=usb_client`), and diagnostics values. Choice values use the module strings
`choice_<setting>_<value>`. The Car tab check adds `wifi_builtin` (present/none) and `wifi_usb` (model, none or not
supported) from `lib/preflight.sh`.

## Takeover from wifi-client

`module.properties` declares `replaces=wifi-client`. The bundled check (`module install-bundled`, run by postinstall
after a USB install and by boot reconcile after an OTA) moves desired state, settings, state directory (baselines,
applied records, transient records), restart-cleanup marker and peer file to `wifi` when both declare the same
persistent targets, then drops the old package and records `module_takeover` in the ledger. No system write happens.
`core/foreign.sh` still recognises `modules/wifi-client` records until then.

## Built-in chip probe

Korean firmware has no Wi-Fi switch, so a unit that never ran Wi-Fi shows no chip on SDIO and a zero
factory MAC. The module's `wifi_probe` button (shown while `info.chip_unknown=1`, after a confirm, only while the
module is on) runs `sg_wifi_probe` ([contract](module-runtime-contract.md)): Wi-Fi on once, wait for the chip,
Wi-Fi back to its previous state. The marker `$SG_DATA_ROOT/wifi-chip` feeds `builtin_missing` (`absent` = no
built-in role), `info.chip` and the car check `wifi_hw` (`seen` = ok, `absent` = block). It is never run
automatically: the owner's NEEV KOR unit shows an empty SDIO with the radio off yet works, so an automatic wake would
restart Bluetooth for nothing there. Not yet run on a car. Reference: korea-projection `wake_wifi`.

## Compatibility gate

- `ro.build.product` glob `NEEV.KOR.*.260902`, `tcc.wifi.vendor=broadcom`, and nonempty regular
  `/system/wifi/bcmdhd.ko` and `/system/wifi/fw_bcmdhd.bin`. Missing/wrong vendor or missing/empty driver/firmware fails
  incompatible before any write, even with live SDIO/WLAN entries.
- Not required: `wlan.driver.status`, a current interface, SDIO enumeration, current firmware mode. Owner's 2026-11-04
  (F6) check found empty `/sys/bus/sdio/devices/` and no `wlan*` while the radio was off on a working unit, so live
  enumeration cannot gate enable. This proves stock software capability only, not a healthy radio.
- Provenance (original checkout's gitignored dumps): `tmp/car-sessions/2026-11-04-devdump/runtime/root/rootfs_init.tcc803x.rc.txt`
  imports the Broadcom init file (line 4), writes `/system/wifi/fw_bcmdhd.bin` to `/data/misc/wifi/firmware_path`
  (lines 105/203); `rootfs_init.tcc803x.wifi.broadcom.rc.txt` sets `tcc.wifi.vendor=broadcom` (line 2), declares disabled
  one-shot `wpa_supplicant`/`p2p_supplicant` for `wlan0`, does not insert the driver at boot; strings in
  `system/lib/libhardware_legacy.so` name `/system/wifi/bcmdhd.ko` and
  `iface_name=wlan0 firmware_path=/data/misc/wifi/fw_bcmdhd.bin`; dump holds the nonempty driver and firmware;
  `runtime/cmd/getprop.txt:516` and `tmp/car-sessions/2026-11-03-baseline/props/getprop.txt:516` report
  `tcc.wifi.vendor=broadcom` (`tcc.wifi.firmware.mode=softap`, `wlan.driver.status=ok` are active state, not capability).

## On-car facts (NEEV.KOR.0000.V039.001.260902, verified 2026-11-03)

- Stock `featurexml.cfg` has no `android.hardware.wifi.xml` removal line; the XML is absent;
  `pm list features` lacks `android.hardware.wifi`.
- Stock `HKMC_WifiSettings` has `WifiClientSettings`/`WifiClientModeEnabler` and gates on `hasSystemFeature`
  `android.hardware.wifi`.
- No file under `/system` or init scripts contains `persist.wifi` or `wifi.state`. No `wpa_cli`.
- adbd listens on `0.0.0.0:5555`; iptables INPUT policy ACCEPT, empty `fw_wlan_INPUT` while the AP is up (STA rules
  unverified).
- Owner: a prior HMG-API install gave the stock hotspot menu and wireless CarPlay after reboot, but no client menu.
- Pre-install Car Report (`car-reports/car-report-neev-kor-260902-20261102-2115.json:5-16,64-96,110-118,2196-2236`):
  `wifi_chip:false`, 90 features incl. `com.hkmc.software.wifi.module`, no `android.hardware.wifi`, no `wlan0`/`p2p0`,
  `load_iptrules`, zero HMG-API rules. HMG-API detects chips via SDIO or a remembered marker
  (`HMG-API/core/runtime/java/hmgapi/engine/SystemCheck.java:136-152`), so `false` is a probe false negative, not
  evidence of no Wi-Fi (the owner's wireless CarPlay worked later).
- IPv4/IPv6 filter policies were `INPUT ACCEPT`/`OUTPUT ACCEPT`, `fw_wlan_INPUT` and `oem_out` empty; STA DHCP/DNS should
  need no new rules, but no connected-STA packet test exists. If post-install rules differ, trace counters and add only
  the demonstrated rule.

## Client and AP limits

- A working client needs more than flags: `wifi_on` requests active STA; supplicant edits concern P2P and may not be required for STA. It also needs the supplicant service/config and STA-capable driver firmware/NVRAM. A reboot is needed to validate feature changes; a live property may not reload PackageManager or restart WifiService.
- AP concurrency: the CarPlay bridge uses the head unit's `WifiManager` AP APIs. In AOSP, enabling STA while AP is on stops the AP first and a running AP rejects supplicant start. Hyundai's vendor mode 3 may differ; simultaneous operation is unverified. Enabling STA may stop the CarPlay AP, hence the mutual exclusion. Record AP state, `wlan0`/`p2p0`, driver interface combinations, channel and Wi-Fi logs around a STA toggle.
- Hotspot is `wlan0` `192.168.0.1/24`; the stock ADB switch can assign `eth0` `192.168.0.123`, breaking hotspot DHCP (see [wireless-adb.md](wireless-adb.md)).

## Tests

`modules/wifi/test/run.sh`: fake `common.sh` for files and properties over the real runtime for transient effects; fake
`getprop`/`setprop`/`pm`/`ifconfig`/`netcfg`, fake `insmod`/`rmmod`/`ip`/`iptables` and daemon executables under
`HMG_SEOGAEMO_TOOL_ROOT`, fake sysfs USB ids, fake `wpa_cli`; restricted PATH with failing stubs for tools absent on
the unit. Covers the former wifi-client cases (apply/reapply/revert, gates, drift, owner, warnings), role exclusivity,
adapter detection, USB client apply/scan/join/watch/revert, USB hotspot apply/credentials/peer info/revert, stale
records after a restart, failed driver load and the built-in hotspot role. Takeover: `tools/test-module-install.py`
`test_replaces`. Picker request encoding: `tools/WifiNetworkTest.java`. Plan rule: `tools/test-module-switch.py`.

## On-car checklist

1. Read-only baseline over adb (full-root NEMESIS if needed): `getprop ro.build.product ro.mobis.targetdir
   persist.wifi.state tcc.wifi.vendor`, `settings get global wifi_on`, `ls -l` the wifi permission XMLs and
   `featurexml.cfg`, `/data/misc/wifi`, supplicant/hostapd/dhcp processes, `ifconfig`/`netcfg`/`ip route`, `iptables -S`,
   `ip6tables -S`, `logcat -d -s WifiStateMachine WifiService WifiController wpa_supplicant WifiHW`, `dumpsys wifi`,
   `pm list features`, driver/firmware presence, SDIO/WLAN evidence, exact bytes/mode/owner of both files, AP/CarPlay and
   DHCP baseline. Toolbox may lack `ip`/`dumpsys wifi`; fall back to `netcfg`; never assume `tail`.
2. Check no leftover HMG-API/Leafia/NEMESIS owner claims the files.
3. Enable, inspect the planned diff and XML, reboot fully, confirm the stock Wi-Fi menu appears, scan/join a test network,
   verify DHCP/DNS and `info.client_ip`. Log interfaces, routes and firewall counters on any failure.
4. Confirm the plan lists `wireless-carplay-and-aa` and its dependents when turning on Wi-Fi with the built-in client
   role, and `wifi` when turning CarPlay back on; `wireless-adb` is independent.
5. Repeat apply+reboot, disable, update, uninstall; compare restored files byte for byte (XML absent if originally absent);
   verify menu/AP/CarPlay behavior. Test with CarPlay active and with unrelated file drift (warning, restore refusal). Keep
   backups on restore failure.
