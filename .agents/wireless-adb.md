Status: current — implemented; the car runs it with `adb connect 192.168.0.1:5555` over the hotspot. The full on-car checklist below (exact restore, uninstall, failure cases) is not done.

# wireless-adb module

Upstream citations are relative to `tmp/`.

## Why it exists

The stock "Enable ADB" switch (Engineering Mode / NEMESIS) sets `persist.service.adb.tcp.enable=1`; init `set_adb_ip`
then gives `eth0` `192.168.0.123`. The hotspot is `wlan0` `192.168.0.1/24`; DHCP replies can leave via `eth0`, so a phone
joins Wi-Fi without an address and wireless projection fails (`HMG-API/CLAUDE.md:56`, `Engine.java:1900`). HMG-API's
`adb` mod is the coexistence fix: force the switch to `0`, set `persist.adb.tcp.port=5555`, restart `adbd`
(`HMG-API/mods/adb/patches.json:3,6`); a restart clears an `eth0` address already assigned (`Engine.java:1914`). Leafia does
the same at install and reverses only recorded changes (`HMG-Leafia-Plus/packages/wireless-carplay-aa/scripts/common.sh:313`,
`post.sh:43`, `preun.sh:10`). NEMESIS `adb-tcp` is the opposite: writes `ro.adb.secure=0`,
`persist.service.adb.tcp.enable=1`, `service.adb.tcp.port=5555` to `/system/build.prop`, removes the ADB-hide feature file,
restarts `adbd` (`hmg_nemesis/Sources/packages/adb-tcp/scripts/common.sh:260,288,307`).

Upstream facts kept for reference:
- HMG-API `adb` has independent USB/TCP parts (USB on: `persist.sys.usb.config=adb` mirrored to `sys.usb.config`; off:
  `host,adb`; defaults USB on, TCP off); intended use `adb connect 192.168.0.1:5555` from a computer on the hotspot
  (`mods/adb/mod.json:10`, `settings.json:4,7`).
- The bundled AOSP daemon uses `socket_inaddr_any_server` (all IPv4 interfaces; stock bind not verified)
  (`third_party/aosp-4.4.4/adb/transport_local.c:165`, `adb.c:1349`); transient-before-persistent port precedence at
  `adb.c:1352-1358`, matching stock KitKat. The `adbd` mod bind-mounts a rebuilt daemon over `/sbin/adbd`; HMG-API says the
  stock daemon does not check ADB keys, so anyone on the hotspot can connect (`mods/adbd/patches.json:3`, `CLAUDE.md:50`).
- No ADB firewall rule or route is declared upstream. The wireless mod has no `network` declaration; some cars
  (Ioniq 6) permit CarPlay ports on `ncm0` but not `wlan0` (`HMG-API/CLAUDE.md:62`, `docs/mod-reference.md:221,236`).
  On this car the hotspot endpoint `192.168.0.1:5555` is reachable with the module on.
- Upstream restore: records originals, restores when a mod no longer owns them (`Engine.java:1691,1720`; `mods/adb/test.sh:43`).

## Behavior

- Owns only `persist.service.adb.tcp.enable` and `persist.adb.tcp.port`. Apply: `sg_prop_set` switch `0`, port `5555`,
  `sg_service_restart adbd` when the effective port changes, `init.svc.adbd` is not running, or the listener is absent.
  Never writes `eth0` or Wi-Fi state. Restart uses the Android 4.4 `ctl.restart` property
  (`tmp/hmg_nemesis/Sources/packages/adb-tcp/scripts/common.sh:300`).
- A nonempty `service.adb.tcp.port` overrides the persistent port; anything but `5555` is a conflict.
- Revert: `sg_revert_all`; keeps the baseline if live property drift or a firmware change blocks a guarded restore. If the
  saved stock switch was `1`, restoring it can bring back the hotspot routing problem; UI warns before disable/uninstall.
- Head-unit `pending-restart` only while `eth0` has `192.168.0.123`; an adbd restart does not clear that address.
- Status info lines: `info.effective_port` (nonempty transient `service.adb.tcp.port` overrides `persist.adb.tcp.port`; applied properties with another effective port → conflict), `info.adbd_state`, `info.adb_listener=listening|absent|unknown`. Status: overridden = conflict, stopped = failed, else configured with adbd running. EN/KO rows show effective port and
  daemon state. `/proc/net/tcp` and `tcp6` are checked for local `:15B3` LISTEN (`0A`); absent listener → failed and
  reapply restarts adbd (waits ≤4 s for async listen); unreadable tables → unknown. LISTEN does not prove remote reachability.
- Network info: `ifconfig wlan0`, falling back to `netcfg`; IPv4 validated before printing. `wlan0` is the hotspot when the
  address is `192.168.0.1` or `init.svc.hostapd=running`, else offered as a client address. The SSID is in binary
  `/data/misc/wifi/softap.conf` (`DataOutputStream.writeUTF`, AOSP `WifiApConfigStore`); the shell module does not decode it,
  omits `info.hotspot_ssid`, and the runtime renders `—`.

## Pane and enable rules

- The pane shows the car hotspot (`info.hotspot_ip`, `info.adb_endpoint` = `<hotspot ip>:5555`; `info.hotspot_ssid` omitted, see above) with a note that ADB works for a computer joined to that hotspot, plus the action "Connect to another Wi-Fi" = `enable module=wifi`. When `wifi` is on with the built-in client role it also shows `info.client_ip` and `info.client_adb_endpoint`. Independent of `wifi` (no `depends`). Off by default; fixed port 5555; `192.168.0.1:5555` applies only while the hotspot runs.
- Block enable if NEMESIS `adb.tcp` is installed (opposite switch value; edits `/system/build.prop`: `tmp/hmg_nemesis/Sources/packages/adb-tcp/NEMESIS.data:1-12`, `scripts/common.sh:288-300`). Also detect leftover HMG-API `adb` ownership and Leafia's `wireless.carplay.aa` ADB marker (`tmp/HMG-Leafia-Plus/packages/wireless-carplay-aa/scripts/common.sh:313-335`); ambiguous ownership → conflict, no change.
- Stock adbd has no key authentication: anyone able to reach the TCP port may connect. Owner accepts this for the stock daemon; the separate `wired-adb` module ([wired-adb.md](wired-adb.md)) runs its own key-checking daemon over a USB cable. USB ADB through the stock USB mode (`persist.sys.usb.config`) is out of scope (it can disrupt wired phone projection and USB drives; needs its own design).
- Do not infer success from property readback alone.

## Restart rule

adbd picks its TCP port at process start, and no inspected init rule resets it, so equal property strings do not prove a TCP listener. Apply and reapply therefore restart adbd when the listener is absent, even when properties already read 5555 (vendor reset or startup ordering is not proven). No Wi-Fi-up wait is needed for an INADDR_ANY listener. The test models props=5555, adbd running without LISTEN, so status reports failed, apply restarts, and LISTEN becomes healthy (also IPv6).

## Tests

`sh modules/wireless-adb/test/run.sh`: fake helpers/properties/interface tools in a disposable dir under
`modules/wireless-adb/test/`; restricted PATH with failing stubs for tools absent on the unit (test fails if invoked).

## On-car checklist

Save the two live properties, their `/data/property/` backing file presence/content, and `ro.build.product`. Confirm the
hotspot gives a computer DHCP and CarPlay works. Enable; confirm switch `0`, port `5555`, `eth0` lacks `192.168.0.123`
after any required full reboot, `adb connect 192.168.0.1:5555` works while CarPlay and DHCP continue. Repeat apply, then
disable and compare properties and backing files byte for byte. Also test: existing old `eth0` address, external ADB owner,
failed adbd restart, firmware change, package uninstall.
