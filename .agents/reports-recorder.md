Status: current - implemented off-car (host tests only); on-car checks at the end.

# USB report recording (HSM-REPORTS) and the car check

Goal: a non-developer who has only a USB drive can send us everything we normally had to ask for
one question at a time (firmware, Wi-Fi hardware evidence, conflicting packages, native library
hashes, module state, boot logs). Developers read the files; users never type a command.

## Behaviour

- Settings > Support has one **Report a problem** button (mockup `tmp/ui-mock/v21.png`). Its dialog offers two
  cards: **Export now** (one problem-report export to USB, all logs) or **Keep recording** (`recorder enable`).
  While recording is on, Support shows one "Recording to USB · Turn off" row (confirmed `recorder disable`).
- The car check runs on the **Car tab**: read-only `preflight run` when the tab first loads and again after
  Recheck or a cleanup. Results are icon rows next to compatibility (✕ block, ! warn, ? unknown, ✓ ok), problems
  first; library and module checks fold into one row each; the root's English messages are not shown.
- **Turning recording on needs a mounted USB drive.** Without one `recorder enable` fails with
  `No USB drive is mounted...` and nothing is written or left on. Once on it stays on across restarts
  (flag `$SG_DATA_ROOT/recorder/enabled`) until the owner turns it off; with no drive mounted it only
  keeps a bounded log stream on the unit and writes to the drive when one appears.
- Output folder on the drive: `HSM-REPORTS/<ro.build.product>/boot-NNNN/` plus `HSM-REPORTS/README.txt`
  (English and Korean). `NNNN` is a per-recorder counter persisted in `recorder/seq`; a folder that
  already exists on the drive without this boot's id in `.boot` is never reused (reused sticks).
  The newest 20 boot folders are kept; the current one is never pruned; other folders are untouched.
- Per boot folder: `facts.txt` (props, selected kernel command line words, buses, interfaces, features),
  `check.txt` (car check), `status.txt` (map and module status), `dmesg.txt` (filtered kernel log),
  `logcat.txt` (filtered log stream window), `runtime/` (the hook's per-process records and log ring,
  same fixed area as the changes export), `reconcile.log`, `modules/<id>/module.log`, `events.log`.
- The folder header (`README.txt`) and the write test run when a drive appears or was swapped, never
  per tick: a tick that has nothing to flush writes nothing to the drive.
- Cadence: status snapshot at the first tick of a boot, when a drive appears and every 10 minutes;
  logs every 2 minutes (`HMG_SEOGAEMO_RECORDER_SNAPSHOT`/`_FLUSH` override for tests); one `sync` per write.

## Design decisions

- **Where it runs.** The recorder is not a new NEMESIS service. OTA updates do not register new NEMESIS
  services, so the existing `watcher` service starts a detached, locked `recorder tick` each loop while
  `recorder/enabled` exists (loop interval capped at 60 s, below the 120 s log flush). A slow USB drive can never delay a module's
  watch events. `tick` is not an app verb.
- **Log stream.** The main log buffer holds seconds, so a `logcat -f ... -r 128 -n 2` process with a fixed
  tag list (`*:S` plus our tags, Wi-Fi tags, `AndroidRuntime:E`, `*:F`) runs while recording is on
  (`recorder/logcat.pid`, validated against `/proc/<pid>/cmdline` before any kill). Disable and the
  uninstall hook stop it.
- **One redaction pass for everything that leaves the car** (`sg_redact` in `lib/common.sh`): the
  recorder and the changes/problem export share it, not per collector: lines with serial, Bluetooth address, Wi-Fi address (`wifimac` becomes `EMPTY`/`SET`),
  SSID, passwords, tokens, IMEI/IMSI/ICCID, VIN, hardware addresses or any `xx:xx:xx:xx:xx:xx` are replaced
  by `[redacted]`. (A kernel-log filter once leaked the unit serial through the boot command line; the
  collectors now never copy that line and the pass would still remove it.)
- **No new write verbs.** Verbs: `recorder status|enable|disable|tick`, `preflight run` and `report digest`,
  fixed, no arguments, no paths. It writes only under its own state directory and `<usb>/HSM-REPORTS`.
- **Issue digest.** `report digest` is read-only: product and versions, each module's desired/status, car
  check results that are not ok, ledger rows whose result is not ok (whole ledger), the last lines of each
  `module.log`, `reconcile.log`, `watcher.log` and `update/log`, then the last ledger rows. Before/after
  record names are dropped; every line goes through `sg_redact`. Output is `info.log_NNN=` lines capped at
  7000 bytes (the app reads 8 KiB). Support → Report a problem → Export as a GitHub issue packs it with the
  app's own state and recent errors into the QR link (`IssueLink.withLog`: raw deflate, base64url, `HSR1.`
  prefix, leading lines that fit). `.github/workflows/issue-log.yml` decodes it into an issue comment with
  `tools/decode-issue-log.py`. logcat and NEMESIS logs stay USB-only (phone names are not redacted).
- **No system change, no radio power.** The car check never powers the Wi-Fi radio.

## Car check (`lib/preflight.sh`)

One line per check: `id|level|evidence|message`, level `ok|warn|block|unknown`, evidence `observed|inferred`.
Checks: firmware (ok with a car map for this product, otherwise warn: map this car first), Android, onebin (warn when unusable for `@onebin@`), boot, ADB over network
switch, other packages (one catalogue:
`core/foreign.sh status`, the same findings the Car tab cleans; harmless leftover logs are not reported
as a constraint), **Wi-Fi hardware**, Wi-Fi driver state,
five native library hashes (against the `native <md5>` lines of the wireless recipes), and each module's own
`precheck`. Wi-Fi hardware is `ok` only when a device is on the SDIO or `mmc1` bus; `block` (observed) when the
kernel log shows failed power-up tries; otherwise a guess (`warn` with an empty factory Wi-Fi address,
`unknown` without). The first Ioniq 5 report with no Wi-Fi chip is the reference case: powered radio, no SDIO
device, `failed to power up DHD generic adapter`, empty `androidboot.wifimac`.

Not implemented (not in the pinned 4.4 toolbox profile): firewall policy (`iptables`), free space (`df`).

## Tests and open checks

`tools/test-recorder.py` (host): check results, enable needs USB, redaction, tick follows USB and boots,
disable stops the stream and keeps reports, pruning and reused sticks, fixed dispatcher verbs.
On-car checks still open: that `logcat -f -r -n` with the tag list behaves on the 4.4 toolbox and stays within
its bounds for a day; that watcher ticks do not disturb module watch events; that the USB drive survives being
pulled while writing; flush cost on a slow stick; the SDIO/mmc1 paths on a unit with a working Wi-Fi chip
(the reference run for "chip present").
