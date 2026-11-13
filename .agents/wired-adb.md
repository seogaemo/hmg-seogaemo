Status: current — implemented and built off-car (module, key import, payload programs); nothing is verified on a car in this form. The technique itself is car-verified in the contributor's standalone package (below).

# wired-adb module

## Why it exists

Stock ADB on these units has no key check, and its Wi-Fi switch interferes with the hotspot
([wireless-adb.md](wireless-adb.md)). `wired-adb` gives a developer ADB over a USB cable that
needs no Wi-Fi, leaves the stock adbd and its properties alone, and accepts only keys the owner
imported. It works next to wireless Android Auto and CarPlay because it never touches the radio.

## How it works

- The head unit is a USB host. An Apple Silicon Mac plugged into a data USB port presents Apple's
  NCM network function (`05ac:1905`). The tcc803x config dump has no `cdc_ncm`; the tcc897x dump has
  it, yet on the CN7 unit the Mac's interfaces were free to claim (`kernel/usb-wifi/configs/*.config`).
  Both have TUN, so the link is made in user space and does not depend on a kernel NCM driver.
- `files/cable-link` (Go, static ARM) is a transient runtime daemon (`daemons=cable-link`). It scans
  `/sys/bus/usb/devices` for the Mac, claims the NCM control/data interfaces through usbfs, creates
  its own non-persistent TAP `sgncm0` (`owns_ifaces`), gives it `192.168.2.249/24` (skipped when
  another interface already routes that subnet) and `fe80::c7ad:b/64`, and bridges NTB16 frames
  both ways. `192.168.2.0/24` is the subnet of macOS Internet Sharing (`bridge100`, Mac at `.1`);
  the link-local address works without it.
- While a link is up it runs `files/cable-adbd`: AOSP 4.4.4 adbd with
  `payload/adbd/cable-adbd.patch`. The supervisor opens the only listener (port 5556, bound to
  `sgncm0` with `SO_BINDTODEVICE`) and passes it as fd 3. The adbd reads the key file once as
  root, then always becomes the shell user (uid 2000, the stock adbd groups); `root:`, `tcpip:`
  and `usb:` are refused, there is no on-screen enrollment, and the JDWP control socket stays with
  the system adbd. The capability bounding set is left as inherited, like a debuggable stock build.
- The package extractor writes payload files without execute permission. `sg_daemon_start` makes
  the daemon executable mode 700; the supervisor copies the adbd to `cable-adbd.run` (mode 700) in
  the module state directory and runs that copy.
- Nothing persistent changes: no property, no file under `/system`, no USB mode. Turning the module
  off stops the daemon (`sg_revert_all`); a head-unit restart alone also returns the unit to stock.

## Keys (owner supplied)

- No key is bundled. The owner copies the computer's `~/.android/adbkey.pub` to `HSM/adbkey.pub`
  on a USB drive (the same `HSM/` folder as module packages) and confirms **Import ADB key from
  USB** on the module screen (`button name=import_key`, root verb `wired-adb action import_key`;
  the module must be on).
- `module.sh` checks the whole file first (regular non-symlink file, at most 8 KiB and 8 keys;
  each key exactly 700 base64 characters, the size of adb's RSA-2048 public key structure; one
  extra non-base64 byte from a CRLF line ending is dropped; a `user@host` label is kept only when
  it is plain `[A-Za-z0-9@._-]`, at most 64 characters), then writes `<state>/adb_keys` in one
  redirection (mode 600) and restarts the daemon so a live link uses it. A refused file changes
  nothing. Import replaces earlier keys; **Remove ADB keys** empties the file.
- Without a USB drive the owner can write the same lines to the state file as root over wireless
  ADB (screen note `key_adb_note`):
  `adb push ~/.android/adbkey.pub /data/local/tmp/adbkey.pub`, then
  `adb shell "/system/xbin/nemesis root -c 'cat /data/local/tmp/adbkey.pub > /data/nemesis/backup/hmg-seogaemo/modules/wired-adb/adb_keys && chmod 600 /data/nemesis/backup/hmg-seogaemo/modules/wired-adb/adb_keys'"`.
  This skips the import checks; the cable adbd still decodes each key itself. A waiting daemon
  polls the file (`runService`), so the link comes up without a restart; a live link keeps the
  keys its adbd read and needs the module off and on. Car-verified on CN7 KOR `260902`
  (2026-11-14): the link reported `READY` after the write and `adb connect 192.168.2.249:5556`
  was authorized.
- Keys stay across off/on. They live in the module state directory, so package removal clears them.
- Without a key the daemon waits and never starts the adbd; status says so.

## Status

`info.key_count`, `info.has_key=1` / `info.no_key=1`, `info.link=up|waiting`, and while the TAP
exists `info.endpoint=192.168.2.249:5556`, `info.endpoint6=fe80::c7ad:b`. States: `incompatible`
without a car map, Android 4.4 or a TUN device; `conflict` while the standalone NEMESIS package
`cn7.mac.cable` is installed (same USB device and port); `failed` when the payload is missing or
the daemon is not running while desired on. `rerun_on=boot,screen_on` starts the daemon again.

## Connecting from the Mac

```sh
adb connect 192.168.2.249:5556              # with Internet Sharing on (bridge100)
adb connect '[fe80::c7ad:b%en5]:5556'       # without it; use the Mac's USB network interface
```

The serial is that network address, not a USB serial (`adb -s 192.168.2.249:5556 shell`).
`adb root`, `adb tcpip` and `adb usb` are refused; the shell is uid 2000, so use the NEMESIS root
commands from AGENTS.md for root. Only a Mac works as the computer: the head unit is the USB host
and matches Apple's device IDs; a PC that is itself a USB host cannot be attached this way.

## Provenance and build

- Adapted from the contributor's standalone NEMESIS package `cn7.mac.cable` 1.0.1 (Go supervisor
  `cable-watch`, patched adbd), which bundled one Mac's public key and checked the CN7 firmware in
  code. Car-verified there on a CN7 KOR `260902` unit on 2026-11-06: reconnect after another boot,
  stock adbd stopped, Wi-Fi off, wireless Android Auto in the foreground, a 128 KiB round trip with
  matching SHA-256. Changes here: no bundled key, no product check (the car gate applies), the Mac
  is found on any USB port, TAP `sgncm0`, the adbd starts as root and drops to shell itself (the
  module state is root-only, so a shell-started adbd could not reach the program or the keys), keys
  are loaded once at start, JDWP lists stay valid.
- `payload/build.sh` (Docker) builds both programs with the toolchains behind the verified
  binaries: NDK r21e (clang 9.0.9, API 19) in a linux/amd64 container with the compiler flags of
  HMG-API's adbd build at `4fab437`, and Go 1.26.4 in a container of the host's own architecture
  (the x86-64 Go toolchain crashes under emulation; the cross-compiled output does not depend on
  the host). AOSP sources come from `android-4.4.4_r1` `platform/system/core`; every file used is
  pinned in `payload/adbd/sources.sha256`. The hashes were taken from the copy HMG-API vendored at
  `4fab437`, and the 2026-11-10 build confirmed that all 93 files equal AOSP's. Outputs go to
  `files/` with `SHA256SUMS` and the upstream notices in `NOTICE.txt`; the build runs `go vet` and
  the framing and key-check tests (`go test`). A second build on 2026-11-10 gave identical hashes.
  The built programs have never run on a head unit.

## Tests

`sh modules/wired-adb/test/run.sh`: gates, apply/revert/watch, key import and refusals with a
recorder for the transient API and failing stubs for tools absent on the unit.
`tools/test-transient.py` `test_daemon_payload_mode` covers the execute-permission fix.

## Open (see backlog)

First on-car run of this adaptation (root start and
privilege drop, exec from the state directory, key import from a real USB drive, replug, restart);
units other than CN7 (USB port layout, TUN node); behaviour beside wired CarPlay/Android Auto on
the same port; the Mac-side helper that reconnects automatically is not included.
