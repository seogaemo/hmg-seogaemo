Status: current — USB hotspot with wireless Android Auto owner-reported working on a tester car; replug recovery host-tested, unverified on a car.

# External (USB) Wi-Fi dongle

Goal (owner, 2026-11-06): a USB Wi-Fi dongle works for both the Wi-Fi client (STA) and the
wireless CarPlay hotspot (AP). Order chosen by the owner: driver first, then the CarPlay
hotspot. Implemented (owner-approved flow, 2026-11-07): the bundled `wifi` module (formerly
`wifi-client`) gives each radio one role, `builtin_role` and `usb_role` = `off|client|carplay_ap`,
with at most one `carplay_ap`; design, files and tests in [wifi.md](wifi.md). The CarPlay module uses the
published USB hotspot (see Interface for the CarPlay module below).

Reference: `tmp/HKG_5W_USB_Wlan` (GRT47, no license file: facts only, never copied). It loads
Realtek `88x2bu`/`8851bu` modules built for `3.18.24-tcc` from its package directory, names the
interface `rtwlan0` so stock `wlan0` stays untouched, and runs its own hostapd (stock binary copy,
`driver=nl80211`), dnsmasq, `wpa_supplicant -Dnl80211` and `dhcpcd` with iptables/ip rule glue.
It never writes `/system`; everything it changes is gone after a restart.

Kernel modules (2026-11-07, build-verified only): `kernel/usb-wifi/build.sh` builds `88x2bu.ko`
(RTL8812BU/8822BU, cilynx `04ed700`) and `8851bu.ko` (RTL8831BU/8851BU, fofajardo `9e37e7a`) for
tcc803x and tcc897x in Docker with AOSP `arm-eabi-4.7` against kernel.org 3.18.24, using the car
`.config` verbatim as `autoconf.h` (tcc803x has LPAE, so `dma_addr_t` is 64-bit). Each `.ko` has
vermagic `3.18.24-tcc SMP preempt mod_unload ARMv7 p2v8` and no symbol missing from a vanilla
3.18.24 `vmlinux` built from the same config (modpost + `nm -u`); Telechips-only exports are not
covered. Our patches: `rtwlan%d` names, nl80211, no MP mode, unplug marks the device gone before
netdev teardown, and usbfs hiding (`hide_usbfs=1`: replays the device `remove` uevent so ueventd
deletes `/dev/bus/usb/BBB/DDD` while bound, so Android Auto cannot send AOA requests). Not yet
loaded on a car; the configs are third-party dumps not yet compared with our car's
`/proc/config.gz`. Extra ids from our own patches: `0bda:b831` (8851bu) and `0bda:b81a`/`b820`/`b82b`
(88x2bu). Not ported: the reference's DHCP 67/1067 rewrite, its other extra 8851bu ids and its
`0bda:1a2b` CD-ROM mode switch.

Tester car (2026-11-07 problem report, 0.1.36, tcc803x): the adapter was `0bda:b831` "802.11ax WLAN
Adapter" (then unsupported). The car has `bcmdhd.ko`/firmware and `tcc.wifi.vendor=broadcom` but
no chip: every bcmdhd power-up logs `failed to power up DHD generic adapter` and nothing appears on
SDIO. `wifi` and the Car tab radio check now read that (the preflight `wifi_hw` evidence) as "no
built-in radio", and `wifi` defaults the built-in role to off there.
It also read `persist.wifi.state=3` after a Car tab cleanup and restart although
`/data/property/persist.wifi.state` was absent before the cleanup, so the value comes from boot
files or another package's init; the problem report now lists `persist.wifi` lines from
`default.prop`, `build.prop`, `/data/local.prop`, `init*.rc` and `/system/etc` scripts. One known
source is a `persist.wifi.state=3` line an older Wi-Fi patch leaves in `/system/build.prop`, which
the `hmgapi-wifi` cleanup now removes (runtime contract, "Other packages"); it is not confirmed
for this car. The leftover only blocks the built-in client role. The car has one user USB port (`4-1`), so a report
exported from a USB stick misses the adapter unless a hub is used.

## Constraints

- The tester is remote with app screen + USB only (no adb). The car has no HMG-Seogaemo yet,
  possibly another package; first install is the release `-nemesis-usb.zip`, then the Car tab
  cleanup handles foreign traces. Only release-signed builds go on that car.
- No adb means recovery is the app's Restore stock state or a USB reinstall; keep every test
  build reversible through the ledger.
- Owner decision (2026-11-07, supersedes the separate `usb-wifi` module of 2026-11-06): driver,
  USB client and USB hotspot are roles of the `wifi` module; the CarPlay module consumes the
  published hotspot and owns any hooks (through the shared core hook host), implemented in
  `modules/wireless-carplay-and-aa` (CarPlay side below).
- 0.1.33 cannot load a diagnostic `.hsm` (`raw_shell` is refused), so evidence collection ships in
  the core problem report.

## Evidence the problem report collects

`diagnostics/wifi-usb.txt` (redacted, 64 KiB): `/proc/version`, `/proc/modules`, every
`/sys/class/net` interface with its sysfs path (USB or SDIO), driver link, operstate and device
`uevent`; every `/sys/bus/usb/devices` entry with `idVendor`/`idProduct`/class/product/speed and
`DRIVER`/`PRODUCT`/`MODALIAS`; driver/firmware directory listings; `wpa_supplicant`/`hostapd`/
`dhcpcd`/`iw` binaries; permissions listing; Wi-Fi lines of `/init*.rc`; Wi-Fi/USB properties;
Wi-Fi/USB kernel log lines. `diagnostics/kernel-config.gz` copies `/proc/config.gz` (256 KiB cap)
to show whether cfg80211/mac80211 and the dongle's driver could load.

## Open questions (answer from the tester's report)

- Dongle chip and whether the kernel already has its driver (built in, `.ko` on the system, or none).
- A matching `.ko` builds (see Kernel modules above); whether it loads and runs on our car is open.
- Interface name, and whether the stock HAL (`libhardware_legacy`, `wifi.interface`) can drive it.
- Whether `hostapd` can run AP mode on the dongle for the CarPlay bridge.

## CarPlay/AA hotspot path (read-only analysis, 2026-11-06)

Full report: `tmp/external-wifi-carplay-ap.md` (stock code from the NEMESIS US 260507 dex build
via jadx; KOR 260902 equivalence still needs mapping).

- Our bridge starts the AP: on iPhone SPP connect, DiPO calls
  `WifiManager.setWifiApEnabledForConnectivity(getWifiApConfiguration(), true)`; below that,
  system_server/netd/hostapd on `wlan0` (bcmdhd, `192.168.0.1/24`) are stock (AOSP-inferred).
- iAP2 credentials: `com.tcc.iap2server` `OnSendWifiInformation()` reads
  `getWifiApConfiguration()` ConnectivitySSID/ConnectivityPSK and security in its own process; no
  channel, BSSID or IP. Not hooked by us today.
- Android Auto (GPM) reads the same SSID/PSK but finds host IP and BSSID by the hardcoded name
  `wlan0` (port 40515): the main blocker for a dongle.
- Unknown: which interface CarPlay Bonjour/AirPlay binds (native), and whether the car firewall
  (`iptrules`) drops `rtwlan0`.
- Chosen design: the `wifi` module owns driver, hostapd, DHCP and the firewall rule and publishes the
  hotspot; the CarPlay module reads it (`sg_peer_info wifi <key>`) and hooks
  `WifiManager.getWifiApConfiguration` (iap2server, GPM), GPM's interface lookup and DiPO's stock
  AP start. Decide by actual radio presence, not car model: the reference lists Ioniq 5 as having
  no built-in Wi-Fi, while the owner's KOR Ioniq 5 runs a `wlan0` hotspot.

## Runtime API

Implemented in `lib/common.sh` (off-car host tests only, `tools/test-transient.py`): `sg_kmod_load`,
`sg_daemon_start`, `sg_net_rule`, `sg_iface_addr`, with the read helpers `sg_kmod_loaded` and
`sg_daemon_running`. Manifest keys, validation, ownership and revert rules are normative in
[module-runtime-contract.md](module-runtime-contract.md#transient-effects). Added for the `wifi` module:
`sg_revert_transient`, `sg_daemon_restart`, and peer info (`sg_peer_publish`, `sg_peer_info`, contract
[Peer info](module-runtime-contract.md#peer-info)). The owner reports the USB hotspot with wireless Android Auto
working on a tester car, but unplug/replug left it disconnected while status stayed on. Recovery now uses
`usb_change` watches and boot/ifindex generation checks, stops stale daemons/address/firewall effects while keeping
the driver loaded, and republishes readiness after bring-up. Both driver load and unload have a 15-second bound;
a timeout retains restore records and blocks later operations until restart. Recovery and bounded-call behavior
remain unverified on a car.

## Interface for the CarPlay module

The hotspot to project over is published by `wifi` (root side; contract table "Peer info"): `radio`
(`usb|builtin|none`), `interface`, `ip`, `ssid`, `passphrase`, `channel`, `ready` (`1|0|stock`). The USB hotspot is
`rtwlan0`, `192.168.50.1/24`, DHCP `192.168.50.10-99`, 2.4 GHz channel 6 (5 GHz channel 36 failed on the tester's
RTL8831BU: hostapd exited within seconds), WPA2-PSK, SSID `HMG-Seogaemo-<4 hex>`; `rtwlan0` is up with its address
before hostapd starts. Stock hostapd (NEEV KOR, MD5 `27f00af8...`) hard-codes the stock hotspot's station list
`/data/misc/wifi/all_sta.list` (written only when a station joins or leaves), so `wifi` runs a private copy
(`derived_bin.hostapd`) that writes `usb_sta.list` instead. Stock hostapd drops root for `wifi` (uid 1010) at start
(the running stock hotspot hostapd is user `wifi`), so 0.1.43 exited 1 on its root-only config; it now starts in a
`wifi`-owned run directory with a private config copy (`daemon_user.usb-hostapd=wifi`), no `ctrl_interface`.
When hostapd fails, `module.log`
says why it stopped and `daemon.usb-hostapd.logcat.log` keeps its logcat lines (both in the problem report);
credentials stay fixed across boots. `radio=builtin`, `ready=stock` means the stock hotspot as today.

## CarPlay side (implemented off-car, 2026-11-07)

Normative rules: contract [Peer info](module-runtime-contract.md#peer-info). In `modules/wireless-carplay-and-aa`:

- `Wireless.zygoteInit` reads `<data root>/peer/wifi` as root in the zygote (`UsbHotspot`); only `radio=usb` with valid
  values counts, and the credentials stay in the mod loader's statics (runtime record: `hotspot.radio`, `hotspot.reason`,
  never the passphrase). A changed role takes effect after a head-unit restart, as both modules declare.
- DiPO `Bridge.ensureHotspot` skips `setWifiApEnabledForConnectivity` and the attach goes on.
- Part `usb_hotspot` (iAP2 server and GPM, framework/libcore hooks, no map points, so no KOR hookpoint mapping is needed):
  `WifiManager.getWifiApConfiguration()` returns the published SSID/passphrase in `SSID`/`preSharedKey` and, where the
  framework has them, `ConnectivitySSID`/`ConnectivityPSK`, with only `KeyMgmt` bit 4 (`WPA2_PSK`, which the iAP2
  server logs as such). That `getAuthType()` returns it assumes AOSP 4.4 logic; the car's framework source is not available.
  In GPM only, `NetworkInterface.getName()`/`getDisplayName()` report the adapter as `wlan0` and a real `wlan0` as
  `wlan0-builtin`, so GPM's host locator (first site-local IPv4 interface named `wlan0`; BSSID from its MAC) picks
  `rtwlan0`/`192.168.50.1`. A failed part shows in the module status; it never disables other parts.
  Also in GPM only: `WifiManager.isWifiApEnabled()` and `getWifiApMode()` answer true / 2 while the hotspot is serving:
  `/sys/class/net/<iface>` has `IFF_UP` and a process has the argument `usb-hostapd.conf` (the module brings `rtwlan0` up
  before it starts hostapd, so `IFF_UP` alone is true too early; hostapd runs as `wifi` in its run directory, hence the
  relative argument). Every hook that follows uses the same check.
  The same two answers in PhoneProjection (`com.daudio.app.phoneprojection`, registered as the sixth app of the module): its
  wireless service decides on `a/f.getWiFiApMode()` = `isWifiApEnabled() ? getWifiApMode() : UNKNOWN` and starts a wireless
  connection only for mode 2 ("CONNECTIVITY"; mode 1 "HOTSPOT" is the other accepted one), silently doing nothing otherwise
  (stock smali `wireless/a/f.j` and `b`; upstream log "getWiFiApMode ... APMode.UNKNOWN"). It also cycles the stock AP around a
  connection (`a/f.l` turn off, `a/f.k` turn on = `setWifiApEnabledForConnectivity(config, false/true)`); that call is a
  no-op returning true there while the USB hotspot serves (`turnOnWiFi` is already a no-op once the AP reads as enabled).
  `renewWirelessPasskey` and `isNewWirelessKey` read `getWifiApConfiguration`, which returns the fixed USB credentials, so the key
  never looks new. PhoneProjection gets no map point and no other hook. GPM's start request (`WirelessExplorer.handleStartRequest`, stock smali) calls `isWifiApEnable()`
  = `isWifiApEnabled() && getWifiApMode() == 2` first and answers the phone `STATUS_WIFI_DISABLED` otherwise, so with the
  stock AP off (the tester car has no built-in chip) the phone showed the Android Auto popup (0.1.44) and never went on:
  no Wi-Fi credentials were sent. The first override is logged once per process (`GPM isWifiApEnabled answered for the
  USB hotspot`) in the module log ring. Same symptom upstream: HMG-Leafia-Plus issue 171
  (`wifiManager.isWifiApEnabled() = false`, `APMode.UNKNOWN`, stuck at "Connecting").
  GPM's version request (`WirelessExplorer.sendVersionRequestMessage`, stock smali) hard-codes
  `CHANNELS_5GHZ_ONLY` with 5745 and 5180 MHz (the older protocol path only the type), so a phone would not look for the
  2.4 GHz hotspot either. While the interface is up, the `WifiVersionRequest$Builder` hooks (by class name in GPM's loader, no
  map point) set `CHANNELS_24GHZ_ONLY`/`CHANNELS_5GHZ_ONLY` from the published `channel` and replace 5745 by the hotspot's
  frequency (2437 MHz for channel 6) and drop 5180; a missing or invalid `channel` falls back to 6. `WifiData.setSupportedChannels`
  (stock 5745/5180) is read by `CarWifiStub`, which builds the `CarWifiCredentials` for the phone over the projection
  channel, so that hook returns `{hotspot frequency}` too. The BT Wi-Fi info response (SSID, PSK, BSSID, security) carries
  no channel list. The
  HMG-Leafia-Plus r8.2 package does the same in its patched GPM (`aaVersion`: type from the frequency, one frequency).
- Without a published USB hotspot nothing loads or changes: the stock `wlan0` path is the car-verified one.
- Root: `info.hotspot_radio` and the built-in client refusal in `apply` (warning in `precheck`).

## Reference: korea-projection (checked 2026-11-08)

`StopDragon/korea-projection` (AGPL-3.0, a NEMESIS package around a fork of the HMG-API wireless mod) does not support
USB Wi-Fi adapters: it starts the stock `hostapd`/`dnsmasq` on the built-in `wlan0` (5 GHz channel 149, 40 MHz) and says
cars without the Wi-Fi part are unsupported. Its Android Auto step (mod 2.2.0, `AaWifi`) is the same idea as our GPM and
PhoneProjection hooks: `isWifiApEnabled()` true, `getWifiApMode()` 2, `setWifiApEnabled*` and `setWifiApConfiguration` skipped
while the system property `sys.kp.aa_ap` is 1 (set by its shell script while its hostapd runs); SSID/PSK come from
`getWifiApConfiguration`, host IP and BSSID from `wlan0`. Differences from ours: the serving gate (property versus our
`IFF_UP` plus the `usb-hostapd.conf` process check), and it also no-ops `setWifiApConfiguration` and `setWifiApEnabled`.
Behaviour only; nothing was copied. It reports wireless Android Auto working on built-in-radio Korean cars, so it does
not settle the USB-adapter path.

Its other finding (`svc/hotspot.sh`): on KOR 260902 Niro `DEPEHEV` (car-verified there), Sonata DN8 `DN822HEV`, Grandeur IG
`IGPE`/`IGPEHEV` and Veloster N `JSN` (reports, not verified) `setWifiApEnabledForConnectivity` brings up no hotspot,
while stock `hostapd` on `wlan0` works. `softap.conf` there is version 3 with `writeUTF` strings: normal hotspot SSID,
connectivity SSID, one more, connectivity passphrase. It runs its own `hostapd` with the connectivity SSID/passphrase
(5 GHz 149, HT40+; 20 MHz did not let the iPhone rejoin after a restart), which needs `svc wifi enable`, taking
`wpa_supplicant.conf` (owner root, crc32 file removed) and killing `wpa_supplicant`, and yields to any stock `hostapd`.
An owner report for Grandeur IG says instead that the unit brings up the normal hotspot (`Kia_hotspot_xxxx`), and that
giving the normal hotspot the connectivity SSID/passphrase by hand makes wireless CarPlay connect.

Ours (`wireless-carplay-and-aa` part `stock_hotspot`, contract "Peer info", 0.1.51) covers both without writing anything:
the iAP2 server and GPM hand the phone the normal hotspot's SSID/passphrase while the normal hotspot serves (enabled,
mode not 2) or nothing does, GPM and PhoneProjection see mode 2 while the normal one serves, and 10 s after a
connectivity request that left the hotspot disabled or failed, `setWifiApEnabled(null, true)` starts the normal hotspot.
A unit whose connectivity hotspot comes up is unaffected. Unverified on such a car: whether the normal hotspot starts
there (Grandeur IG reports #52/#53 in korea-projection: `wlan0` never appears), the AP state and mode values those
units report, and that the phone then joins. The DiPO and PhoneProjection logs say which case a car is in.

## Still unverified on a car

1. USB recovery after unplug/replug (including a quick replug while the display stays on), daemon release before
   reprobe, truthful readiness/status and wireless Android Auto reconnection without restarting the head unit.
   The owner reports the initial USB hotspot/Android Auto connection working. The iPhone joining with the credentials iAP2 sends, and whether
   CarPlay Bonjour/AirPlay (native) binds or advertises on `rtwlan0`.
2. Android Auto reconnecting after the hotspot returns. The zygote caches only stable interface/credentials/channel;
   `UsbHotspot.apUp()` rereads flags and hostapd argv each call, so a new hostapd PID requires no hook reload by static
   review. Actual reconnection still needs a tester-car run.
3. Whether the car firewall (`iptrules`) still drops anything on `rtwlan0` beyond the `wifi` module's INPUT accept rule.
4. That Dalvik hooks on `NetworkInterface` getters and `WifiManager.getWifiApConfiguration` take effect in those apps
   (trivial getters could be inlined if a caller is compiled before the hook; hooks install at app load).
