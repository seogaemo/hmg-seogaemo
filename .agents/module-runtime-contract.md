Status: current — normative interface between the shared module runtime, modules, the app and the updater.

# Module runtime contract

Topic docs hold the rest: installable modules → [installable-modules.md](installable-modules.md); boot, watch, deferred APK install, map-verification retries → [boot-lifecycle.md](boot-lifecycle.md); stock restore, uninstall, restart verb → [stock-restore.md](stock-restore.md); OTA dispatch and rollback guards → [ota-implementation.md](ota-implementation.md); projection runtime records, zygote upgrades, `app_process` guards → [wireless-carplay-and-aa.md](wireless-carplay-and-aa.md); packaged-executable invocation → [research-nemesis-packaging.md](research-nemesis-packaging.md); shell tool profile → [android44-shell-audit.md](android44-shell-audit.md).

## Root side: module invocation, mutation API, status

`hmg-seogaemo-root <id> apply|revert|status|precheck` runs `modules/<id>.sh <verb>` as root with:

- `HMG_SEOGAEMO_BASE`: installed package root (contains `lib/`, `bundled/`, `modules/`, `modules.list`, `modules.graph`; the lists hold only the `package-compat` entry kept for older installs' OTA checks, see installable-modules.md).
- `HMG_SEOGAEMO_MODULE_DIR`: `$HMG_SEOGAEMO_BASE/modules/<id>.d` = packaged copy of `modules/<id>/payload/`
  (extra files: jars, `.so`, XML, APK patches). Absent if the module has no payload.
- `HMG_SEOGAEMO_STATE`: `/data/nemesis/backup/hmg-seogaemo/modules/<id>` (mode 0700, survives updates,
  removed only after a verified uninstall restore).
- `umask 077`, Android 4.4 mksh/toolbox only (no Bash-only features or `tail`;
  `readlink -f` is supported, but shell parameter trimming avoids spawning it).

Dependencies and exclusions are enforced by `hmg-seogaemo-root`/`ModuleManager`, never inside a
module script. A module script must assume its dependencies are already applied.

Module scripts start with `. "$HMG_SEOGAEMO_BASE/lib/common.sh"`.

**Modules never modify the system themselves.** Every write goes through the package API below,
which baselines, writes, records the applied state and appends to the change ledger in one step.
Module scripts may only *read* directly (`getprop`, `cat`, `ls`, `grep`, `pm list features`,
`ifconfig`/`netcfg`, `ps`, `dumpsys`). `make test` lints module root scripts and fails on direct
mutations: `setprop`, `mount`/`umount`, `cp`, `mv`, `rm`, `dd`, `ln`, `chmod`, `chown`, `sed -i`,
output redirection to absolute paths outside `$HMG_SEOGAEMO_STATE`, `nemesis remount`,
`pm install|uninstall|enable|disable`, `settings put`, `start`/`stop`, `iptables`, `ip6tables`,
`ip addr|link|rule|route|...`, `insmod`, `rmmod`, `modprobe`, `kill`, `nohup`, `am`, and the
runtime-internal `sg_tool_*` and transient revert helpers.

Mutation API (each call: validate target against the module's `owns_props`/`owns_files`/`owns_lines.N`,
baseline on first touch, perform, verify, mark applied, append ledger; non-zero on failure):

| Function | Meaning |
|---|---|
| `sg_prop_set <key> <value>` | set a persistent/live property (must be in `owns_props`) |
| `sg_file_put <path> <payload-rel-src> [mode] [owner:group]` | create/replace a file from `$HMG_SEOGAEMO_MODULE_DIR/<src>` atomically (path in `owns_files`); handles `/system` remount |
| `sg_file_replace_line <path> <exact-old-line> <new-line>` | replace exactly one line that must match exactly once (e.g. comment a `featurexml.cfg` entry) |
| `sg_file_delete <path>` | remove a file (baseline keeps its bytes) |
| `sg_bind_mount <target> <payload-rel-src>` | non-persistent bind mount, recorded; reapplied by reconcile at boot |
| `sg_service_restart <name>` | `stop`/`start` an init service (allow-listed per module in `module.properties` `services=`) |
| `sg_wifi_probe` | confirmed owner action only (module action `wifi_probe`): if no chip is on SDIO, turns Wi-Fi on once with the stock `svc wifi enable`, waits up to 60 s for the chip, then puts the Wi-Fi switch back (`svc wifi disable` when it was off). Leaves only the marker `$SG_DATA_ROOT/wifi-chip` (`seen`/`absent`) and a ledger row; a probe cut off with Wi-Fi on is undone by the next probe via `wifi-probe-pending`. Returns 0 chip seen, 10 none appeared, 1 failure. Wi-Fi, Bluetooth and USB may restart briefly, so the app confirms first |
| `sg_service_call <service> <code>` | fixed Binder call, only if the exact `service:code` pair is listed in `service_calls=`; validates both arguments, enforces a 15-second timeout and records every attempted result in the ledger |
| `sg_zygote_install <wrapper-rel-src> <loader-rel-src> <jar-rel-src>` | guarded transaction for `/system/bin/app_process`, its `app_process.hmg-seogaemo-stock` copy, the loader and JAR, and `enable`/`enabled`/`starts`/`disable` state; all eight paths must be in `owns_files`. Only the core hook host (`sg_core_hook_ensure`) calls it now |
| `sg_owned_dirs_prune <dir>...` | remove empty directories under `/system/etc/hmg-seogaemo` that are ancestors of this module's `owns_files` and that an earlier build left without a directory baseline; one ledger row each |
| `sg_hook_register <jar-rel-src> <entry-class> <process>...` | register this module's hook jar with the core hook host (`$SG_DATA_ROOT/core/hook/mods/<id>/{hook.jar,entry,processes}`, ledgered as the module's files); a `hooks=1` manifest owns these three paths implicitly. Follow with `sg_core_hook_ensure`; after `sg_revert_all` call `sg_core_hook_release` |
| `sg_dex_cache_track <system-jar> <app-package>` | track the Dalvik cache entry for an owned `/system/framework/*.jar` and the package's `app_hmg-seogaemo-wireless-dex` files; these two derived cache namespaces are the sole exception to explicit `owns_files` listing |
| `sg_kmod_load <name>` | load a payload kernel module listed in `kmods=` (see [Transient effects](#transient-effects)) |
| `sg_daemon_start <name>` | start the fixed `daemon.<name>=` command detached; idempotent while it runs |
| `sg_bin_derive <name>` | make `$HMG_SEOGAEMO_STATE/bin/<name>`, a private copy of the `derived_bin.<name>=` stock program with one fixed string replaced; `sg_daemon_start` calls it for a daemon whose executable is that stock program |
| `sg_net_rule <n>` | insert the exact `net_rules.<n>=` iptables rule or `ip rule` once per boot |
| `sg_iface_addr <iface> <a.b.c.d/prefix>` | add an IPv4 address to an interface matching `owns_ifaces=` and bring its link up |
| `sg_revert_transient` | undo only this module's transient effects, newest first, and drop them from `changes`; files and properties stay applied |
| `sg_daemon_restart <name>` | stop our running `daemon.<name>` (if any) and start it again, e.g. after rewriting its state-directory config |
| `sg_peer_publish [key=value...]` | replace this module's published facts (see [Peer info](#peer-info)); no argument removes them |
| `sg_revert_all` | undo every change this module made, newest first, with the guarded restore rules below; clears baselines only after every item verified |

Read/report helpers: `sg_log <msg>`, `sg_owner_present <name>` (`nemesis-adb-tcp`, `hmgapi`,
`leafia`, `local-hkmc-factory82`), `sg_applied <path|key>` (0 if our applied state is current), `sg_status <state> <restart> [detail]`,
`sg_kmod_loaded <name>` and `sg_daemon_running <name>` (0 while our effect of this boot is live),
`sg_peer_info <module> <key>` (a value another module published).
`sg_print <line>...` writes each argument literally with a newline; `sg_write <text>`
writes exactly one argument without adding a newline. Both preserve backslashes and
option-looking text. They use mksh `print -r --` / `print -rn --`; host POSIX sh
uses a bounded here-document through `dd` for exact bytes, with `echo` for newlines.
Never route binary files or property backing files through shell variables: copy them.

Internal (not for modules): baseline capture, applied-copy marking, remount, ledger writes.

`/system` returns to read-only through `sg_remount_ro`, which treats a failed `remount ro` as a warning in
the module log, never as a failed change: replacing the running `app_process` or removing a loaded JAR leaves
the old file open, so `remount ro` fails with EBUSY until the next restart, and failing the change would leave
a written but unledgered file that blocks revert, stock restore and the next apply.

Directories created under `/system` for a payload file (`sg_mkdir_target`) are mode 0755 even though module
scripts run with umask 077: hooks run as the system user inside DiPO and need to read and traverse them.
State directories keep the private mode.

`watch=boot,screen_on` may declare only these fixed events. The package's single `watcher` service (never apply/revert) invokes `root/<id>.sh watch <event>` only while the module's desired state is on, under the root operation lock, and never passes arbitrary event names or arguments. Details and retry budgets: [boot-lifecycle.md](boot-lifecycle.md).

`restore=reboot` is reserved for modules whose only non-reversible effect is
transient until a head-unit restart. Disable stops future watch calls. Until the
next kernel boot, status is `pending-restart`, `restart=head_unit`, with
`info.desired=off`; after reboot it is `off`. Apply/revert writes its desired
state through the root dispatcher. The UI treats `info.desired=off` as off for
toggle planning and explicitly tells the owner in the confirmation dialog that
disabling requires a head-unit restart to restore stock behavior. This class
must not own persistent stock-file or property changes. The transient APIs
below are allowed with it; a module that uses only them reverts exactly and
needs no `restore=reboot`.

**Change ledger.** `/data/nemesis/backup/hmg-seogaemo/ledger/` holds an append-only `ledger.tsv`
(`time, module, op, target, before-ref, after-ref, result`) plus, per change, the original bytes
(`before/`), the bytes we wrote (`after/`), file metadata, and property before/after values. It is
never pruned while any change is active; after a verified uninstall it is kept as a final
export-able record until the package directory is removed.
Binder calls record the exact allow-listed pair, time, bounded Parcel summary,
and outcome in this same ledger; export includes them.

The zygote transaction copies the original executable to `app_process.hmg-seogaemo-stock` and
verifies that backup before replacing `app_process`. The wrapper must always exec that stock
path, including when its 3-start/120-second preload guard trips. A failure rolls back via the
same full preflight and guarded restore as uninstall. `starts` is a dynamic decimal counter;
its final value is captured in the ledger before restore. Dalvik cache entries in the two
derived namespaces are captured before activation and again at revert, then restored to their
original bytes or absence. `sg_revert_all` checks every owned path for drift before its first
restore write. `make test` also runs optional `modules/<id>/build/build.sh` hooks before APK
packaging and every `modules/<id>/test/run.sh`.

**Export.** `hmg-seogaemo-root export usb|adb` copies the ledger, all original and modified files,
property before/after values, `ro.build.product`, package version and module desired states into
`HMG-Seogaemo-export/<timestamp>/` on the first mounted USB drive (`usb`) or into
`/data/local/tmp/hmg-seogaemo-export/<timestamp>/` readable by the adb shell user (`adb pull`).
**Other packages (foreign).** The supported setup is NEMESIS + HMG-Seogaemo only. Evidence and
the full artifact list: `tmp/overlap-inventory.md` (2026-11-06, upstream source only, not car).
- `hmg-seogaemo-root foreign status` is read-only. It checks a fixed catalogue and prints
  `info.item_<n>=<item-id>,<class>` plus `info.count`, and writes the same lines to
  `<data root>/foreign/report`. `svc/reconcile.sh` runs it every boot (after install too).
  Classes: `remove` = an installed NEMESIS package (or a standalone HMG-API install) whose own
  uninstall restores its stock; `delete` = harmless leftovers (logs, state, temp) with exact
  catalogue paths; `report` = leftovers whose stock original we cannot prove (orphan backups,
  /system residue, `app_process.*-stock`); these are never touched, only shown.
- `hmg-seogaemo-root foreign clean <item-id>` (item id `[a-z0-9-]+` from the catalogue, and it
  must be found again at call time). It refuses (`conflict`) while any of our modules that
  overlap that item is desired on, because foreign restores overwrite without checking.
  `remove` runs `nemesis uninstall <id>` without `--force`, dependents first (`hmgapi.*` before
  `hmgapi`, `projection.cardata` before `wireless.carplay.aa`), or `/data/hmgapi/uninstall.sh`
  for a standalone HMG-API, then reports `pending-restart`/`head_unit`. `delete` removes only
  the catalogue paths. Every step is a ledger row (`foreign_remove`/`foreign_delete`).
  `hmgapi-wifi` (`delete`, overlaps `wifi`): with no HMG-API installed and no `wifi` record (or
  `wifi-client`, its id before the takeover), `android.hardware.wifi.xml` byte-identical to the `wifi` payload and/or
  `persist.wifi.state=3` are HMG-API Wi-Fi client leftovers (NEEV KOR stock has neither; seen on a
  migrated car 2026-11-06). Clean backs up the XML, deletes it under remount, clears the property
  and its `/data/property` file, then requires a restart. `wifi` reports these leftovers as
  `conflict` pointing to the Car tab.
  `report` items are refused. Calling `nemesis uninstall` from our root verb is unverified on
  the car. The app shows the findings on the Car tab and cleans them only after a confirm.

Problem report form: `export usb|adb all|ours` adds `diagnostics/logs/logcat.txt` (last 512 KiB of
`logcat -d -v time`; `ours` keeps only lines matching hmg-seogaemo, nemesis, dipo, iap2, projection,
carplay or AndroidRuntime), `logs/nemesis.txt` (`nemesis log dump`, 128 KiB),
`app/app-state.txt` (the app writes `files/report/app-state.txt` first: version, statuses it showed,
recent failures) and `summary.txt`; the same redaction applies, and it works before any ledger
exists. The app's Support page and every failure dialog offer it as 문제 보고용 내보내기.

`/system` left read-write: when `remount ro` fails (EBUSY), `sg_remount_ro` once per boot appends
to `$SG_DATA_ROOT/system-rw.log` the `/system` mount line and every process that still maps a
deleted `/system` file or holds a `/system` file descriptor open for writing (`map|fd <pid> <comm>
<path>`; capped at 64 KiB). Read-only. Every diagnostics export copies it to `logs/system-rw.log`.
Read-only for the system; bounded size; refuses if no target. Exposed in Settings (Logs) as
"Export changes to USB" and documented for adb:
`adb shell /data/local/tmp/nemesis-d root -c '/system/bin/sh /data/nemesis/apps/hmg-seogaemo/bin/hmg-seogaemo-root export adb'`.

Status block on stdout (one `key=value` per line, ASCII, detail ≤ 200 chars):

```
state=off|on|pending-restart|conflict|incompatible|failed|not-implemented
restart=none|adbd|head_unit
detail=<short reason>
```

Optional extra lines `info.<key>=<value>` (`[a-z0-9_]` keys, ASCII values ≤ 200 chars) carry
read-only facts the module wants shown in its Settings pane (e.g. `info.hotspot_ssid`,
`info.hotspot_ip`, `info.adb_endpoint`). `status` must be cheap and side-effect free. A pending disable reports
`info.desired=off`; the UI uses this for its off toggle and disable restart text.
A successful revert may return `pending-restart`, `restart=head_unit`, and
`info.desired=off` for either exact file restore (PackageManager still caches a
removed feature) or `restore=reboot`. The dispatcher commits desired off in
both cases. Pending enable retains the on toggle and distinct enable text.

Exit codes: `0` ok, `1` failed, `3` conflict, `4` incompatible, `2` usage.

Module tests (`modules/<id>/test/*.sh`, run by `make test`) use a fake `common.sh` and fake
`getprop`/`setprop`/file roots under a temp dir; they never touch the host system.

Status strings are ASCII; `sg_clean` preserves ASCII semicolons in detail text.

## Transient effects

Kernel modules, daemons, network rules and interface addresses vanish at a head-unit restart.
They never baseline a file or property and are not bound to `ro.build.product`: each record in
the module state directory starts with the boot id (`/proc/sys/kernel/random/boot_id`) it was
made in. A record from an earlier boot is stale: nothing of it is left to undo, it never makes a
live effect ours, and the next apply creates the effect again. Boot reconcile re-runs apply while
desired on; there is no separate reapply pass (an unplugged dongle must not fail the dispatcher).
Every call validates its arguments and the manifest declaration, refuses a declaration that
another module claims (any module in the catalogue, enabled or not), records itself in
`changes` before acting, and appends a ledger row. Return codes: 2 undeclared or invalid,
3 conflict, 4 incompatible (kernel release), 1 failure.

Manifest keys (each value checked at build time by `tools/module-ownership.py`, at package
install by `core/module.sh` through `sg_transient_decl_ok`, and again at call time; only
packages bundled with HMG-Seogaemo may declare them):

| Key | Value |
|---|---|
| `kmods=<name>[,<name>]` | kernel module names `[a-z0-9][a-z0-9_]*`; two modules never declare the same name |
| `kmod.<name>.<platform>=` / `kmod.<name>=` | payload-relative `.ko`; `<platform>` is `getprop ro.board.platform` (e.g. `tcc803x`, `tcc897x`), the plain key is the fallback; every listed name needs one |
| `kmod_params.<name>=` | up to 16 space-separated `key=value` (`key` `[a-zA-Z_][a-zA-Z0-9_]*`, value `[a-zA-Z0-9_.,:+-]+`) |
| `daemons=<name>[,<name>]` | daemon names `[a-z0-9][a-z0-9_-]*`, each with one `daemon.<name>=` |
| `daemon.<name>=` | `/system/bin/<x>`, `/system/xbin/<x>` or `@payload@/<rel>`, then up to 15 tokens of `[a-zA-Z0-9_./:=,+@!-]`; `@payload@` / `@state@` (once per token, followed by nothing or `/...`) expand to `HMG_SEOGAEMO_MODULE_DIR` / `HMG_SEOGAEMO_STATE`; no other `@`; two modules never declare the same command |
| `net_rules.<n>=` | `n` `[1-9][0-9]{0,3}`; `iptables [-t nat|mangle|filter] <chain> <rule spec>` (no command or table options in the spec, no `--modprobe`) or `ip rule <selector and action>` (no `add`/`del`/`flush`/`show`, no options); same token charset without `@`; two modules never declare the same rule |
| `owns_ifaces=<glob>[,<glob>]` | interface names or `*` globs `[a-z0-9][a-z0-9_.*-]*` (e.g. `rtwlan*`); globs of two modules never overlap |
| `daemon_user.<name>=wifi` | the daemon drops root for `wifi` (uid 1010) by itself (Android `hostapd`); it starts in `run/<name>` (owned by 1010, mode 700) and each whole `@state@/<file>` argument becomes a 1010-owned mode-600 copy there, passed as `<file>`. Not ownership, like `derived_bin` |
| `derived_bins=<name>[,<name>]` | derived program names (daemon-name rules), each with one `derived_bin.<name>=` |
| `derived_bin.<name>=` | `/system/bin/<x>` or `/system/xbin/<x>`, an absolute path string in it (`/[a-zA-Z0-9_./-]`, 4-128 bytes, no `..` or `//`) and a file name `[a-zA-Z0-9_.-]` (not starting with `.`) no longer than that string. Private state-directory files, so not ownership: replacing a bundled module that is on ignores these keys |

No value may contain `*`, `?`, `[`, tabs or newlines except interface globs; values are split
on spaces as argv, never evaluated. Tools are fixed absolute paths `/system/bin/insmod`,
`rmmod`, `iptables`, `ip`.

- `sg_kmod_load <name>`: refuses (3) when `/proc/modules` lists the name without a current
  record of ours; requires the `.ko` to contain `vermagic=<osrelease> ` (read with `grep -a`;
  otherwise 4); records, `insmod <ko> <params>`, verifies `/proc/modules`; ledger `kmod_load`.
  Revert: `rmmod` only while loaded and recorded this boot, verified gone; ledger
  `kmod_unload` (`absent` when nothing was left).
- `sg_bin_derive <name>`: reads the stock program (never writes it) and, in a root `app_process`
  running the package helper `core/hsm/hmg-seogaemo-hsm.jar` (`HmgSeogaemoBinPatch`, 60-second
  limit), writes `bin/<name>` (mode 700) with every occurrence of the path string replaced by the
  file name padded with NUL bytes to the same length, so no offset moves and the program opens that
  file relative to its working directory. A stock program without the string is copied unchanged.
  `bin/<name>.source` holds the stock MD5 and both strings; the copy is rebuilt only when they
  change. Ledger `bin_derive` (`failed` with the helper's exit code).
- `sg_daemon_start <name>`: executable must be a regular non-symlink file; a `/system` executable
  named by a `derived_bin.<n>=` runs as `bin/<n>` (made by `sg_bin_derive` first); starts
  `( cd <dir> && exec argv ) </dev/null >>daemon.<name>.log 2>&1 &` with `<dir>` the state directory, or
  `run/<name>` for a `daemon_user` daemon (log emptied at a start beyond 64 KiB),
  records boot id and PID plus the expected `/proc/<pid>/cmdline` bytes (each argument followed
  by NUL; the executable must not rewrite its argv, so payload shell scripts do not qualify),
  then waits up to 5 seconds for an exact match, else fails, logging why in `module.log`
  (`exited <status>`, or still running with another command line, which it then kills). Running means
  current record, live PID and identical cmdline. Revert: TERM, up to 5 seconds, then KILL and
  another 5 seconds, only while it still matches; a reused PID is never signalled; ledger
  `daemon_start` / `daemon_stop`.
- `sg_net_rule <n>`: Android 4.4 iptables cannot be trusted to have `-C`, so the boot-bound
  record says whether the rule is ours: inserted once per boot (`-t <table> -I <chain> ...` or
  `ip rule add ...`), the exact applied text stored in the record. A current record with a
  different manifest rule conflicts. Revert deletes the stored text (`-D` / `ip rule del`);
  if that fails within the same boot someone else changed the table: conflict (3), record kept,
  a restart clears it. Ledger `net_rule_add` / `net_rule_del`.
- `sg_iface_addr <iface> <a.b.c.d/prefix>`: the interface must match `owns_ifaces` and exist in
  `/sys/class/net`; an address already present without our current record conflicts. Records
  whether the link was down (`flags` IFF_UP clear), runs `ip addr add`, and `ip link set up` if
  it was down; verifies via `ip addr show`. Revert removes only that address and sets the link
  down only if we brought it up; a missing interface (unplugged dongle) or stale record is
  success. Ledger `iface_addr_add` / `iface_addr_del`.

`daemon.<name>=/system/...` executables are looked up below `HMG_SEOGAEMO_TOOL_ROOT` when set (the host-test seam of
the `sg_tool_*` wrappers); on the unit it is unset.

`sg_revert_transient` undoes `kmod`, `daemon`, `net` and `addr` records like `sg_revert_all` and rewrites `changes`
after each item, keeping persistent kinds. A module backs out a failed transient step with it without restoring
stock files.

Restore preflight applies the `ro.build.product` guard only when the module holds persistent
material (property, file, line, bind, dex or directory records) or a build marker; transient
records alone never need it, so a firmware update cannot strand them.

## Peer info

A module publishes facts for other modules with `sg_peer_publish key=value...`: the whole set replaces
`<data root>/peer/<module id>` (directory 0700, root only). Keys `[a-z][a-z0-9_]*`; values must survive `sg_clean`
unchanged (letters, digits, space and `();.,:_/+=-`), else 2. No argument removes the file. Readers call
`sg_peer_info <module id> <key>` (prints the value; 1 when not published, 2 on a bad argument). Peer files are not
restore material and are not exported.

The `wifi` module publishes the active CarPlay hotspot on apply, watch and revert (removed on revert):

| Key | Value |
| --- | --- |
| `radio` | `usb`, `builtin` or `none` |
| `interface` | `rtwlan0` (usb), `wlan0` (builtin), empty |
| `ip` | `192.168.50.1` (usb), `192.168.0.1` (builtin), empty |
| `ssid`, `passphrase` | the generated USB hotspot credentials; empty for builtin (Android's `WifiManager` config) |
| `channel` | `36` (usb), empty |
| `ready` | `1` while hostapd and dnsmasq run this boot, `0` otherwise, `stock` when Android runs the built-in hotspot |

Hooks in system-uid processes cannot read `<data root>`. A consumer either copies what its hooks need from its
root script, or (`wireless-carplay-and-aa`) reads the peer file once in its zygote entry, which still runs as root
before apps fork, and keeps the values only in its own loader's statics (never in properties or app-readable files);
such a snapshot follows a role change after the next head-unit restart.

`wireless-carplay-and-aa` consumes it as follows:

- It starts a hotspot only through DiPO's `WifiManager.setWifiApEnabledForConnectivity` call (its Bluetooth bridge,
  `ensureHotspot`). With `radio=usb` in the zygote snapshot (valid `interface`, `ip`, `ssid`, `passphrase`; `ready` is
  ignored because the zygote starts before this boot's reconcile) that call is skipped and the hook part
  `usb_hotspot` (no map points; runtime record `part.usb_hotspot`) loads in `com.tcc.iap2server` and
  `com.google.android.projection.sink`. Anything else, including a missing or unreadable file, is the stock path.
- `status` prints `info.hotspot_radio=usb|builtin|none`: `usb` for a published USB hotspot; `none` for `radio=none`
  with `wifi` setting `builtin_role=client`; otherwise `builtin` when the stock Broadcom radio exists
  (`tcc.wifi.vendor=broadcom`, non-empty `bcmdhd.ko` and `fw_bcmdhd.bin`), else `none`.
- `apply` refuses (conflict) while `wifi` is desired on with `builtin_role=client`, `usb_role` not `carplay_ap` and no
  published `radio=usb` (the root-side `ModuleManager.hotspotConflict`); `precheck` only prints `warn.wifi_client=1`,
  because the app's plan turns `wifi` off before that apply. It reads `wifi`'s `desired` and `settings` files,
  read-only, as `wifi` reads the CarPlay desired state.

## Settings check and module takeover

`hmg-seogaemo-root <id> set <key> <value>` first runs `module.sh setting-ok <key> <value>` for a bundled `raw_shell`
module (read-only). Exit 0 or 2 (no such check) saves the value; any other exit refuses with `state=conflict` and the
module's detail, so a value that clashes with another setting is never saved.

`replaces=<old id>[,<old id>...]` (bundled packages only) renames a bundled module or merges several into one. When
the bundled check installs the new id and any listed `installed/<old>.properties` exists, every present old package
must be bundled and must not own lines, and the persistent ownership (`owns_props`, `reassert_props`, `owns_files`,
`owns_generated_dirs`, `services`, `service_calls`, `restore`, `hooks`, `owns_lines.*`) of every present old package
must also be declared by the new one, item by item (comma lists are split; `owns_lines` compare by value), so no
baseline loses its owner; the new one may own more. Otherwise conflict and the old modules stay. Old ids that are not installed are skipped; the new one is recorded as removed
only when every listed old id was removed by the owner (`bundled-removed/<old>`) and none is installed.
Merging state: `modules/<old>/` entries move into `modules/<new>/`; an entry that already exists stays when it is
byte-identical, `changes` gains the missing lines, `module.log` is appended, and any other clash is a conflict found
before anything moves. `desired/<new>` is `on` when any old one was on. `settings/` (only one old id may have
settings), `restart-cleanup/` and `peer/` move from at most one old id; two would conflict.
`replaces_setting.<old>=<key>:<value>` sets the new module's setting `<key>` (declared by `setting.N`) to `<value>` when
`<old>` was on, so a merged module keeps what each old one did. The takeover writes
`<data root>/migrate/<new>` (journal: old id), moves `modules/`, `desired/`, `settings/`, `restart-cleanup/` and
`peer/` entries from the old id to the new one, publishes the new package in the old one's catalog position, deletes
the old packages and appends one `module_takeover` ledger row per old id (module = new id, target = old id). It never writes the
system: baselines and applied records move with the state directory and keep their meaning because the targets are
identical. An interrupted takeover finishes at the next bundled check (the journal also forces it). If the owner had
removed the old module (`bundled-removed/<old>`), the new one is recorded as removed too. Earlier ledger rows keep the
old id.

## Module shells keep globbing on

A module script must not run with noglob (`set -f`, `set -o noglob`, or `f` in a
`set -efu` flag cluster): library cleanups such as `sg_baseline_clear` rely on globs,
and noglob makes them silently match nothing. Rules:

- `tools/lint-module-root.py` rejects any `set -f`, `-f` in a `set` flag cluster and
  `noglob` in `modules/*/root/*.sh`. The only accepted form is a one-statement word
  split on a single line: `set -f; set -- $x; set +f`.
- The runtime does not rely on that. Every glob-dependent body in `lib/common.sh`
  (`sg_baseline_clear`, `sg_restore_material`, `sg_restore_preflight`,
  `sg_reapply_binds`, `sg_dex_cache_track`, `sg_dex_finalize`, and every subshell
  helper that globs state) runs with globbing on, and the caller's options are left
  unchanged (`sg_glob_on` for brace functions, `set +f` first in subshell functions).
- `sg_changed` appends a `kind<TAB>target` line to `changes` only when the exact
  line is not already there, so repeated applies do not grow the file.

## Shared text-file line ownership

`owns_files=` grants exclusive whole-file ownership. No other module may claim
that path through either `owns_files` or `owns_lines`, even with exclusions.
Put, delete, bind mounts and zygote installation require `owns_files`.

Declare one `owns_lines.N=/absolute/path:<exact stock line>` per entry, with a
unique positive decimal N (no leading zero). Split at the first colon only:
commas, colons, equals signs, backslashes, leading/trailing spaces and an empty
stock line are literal, without escaping or trimming. Paths use letters, digits
and `/._+-`, with no `..` or `//`. Lines contain no control characters (including
NUL, CR, LF and tab). Duplicate keys and duplicate `(path, stock line)` claims
fail generation, including within one module. `restore=reboot` cannot own lines.
The generator emits `modules.lines`, a graph companion in generated module order:
tab-separated module ID, entry number, and literal `path:stock`. Packaged manifests
retain these declarations.

`sg_file_replace_line <path> <stock line> <new line>` requires that exact claim
or exclusive whole-file ownership. New text has the same control-character
restrictions. For line ownership, old always means the stock line on repeat
apply. Each claimed stock line must occur exactly once in the baseline. Match
patches against stock input, never another patch's output; compose in generated
module order. Preserve each input line's newline, including an unterminated last
line. Reapplying the same patch is harmless. Exclusive whole-file callers retain
their existing baseline/restore behavior.

Shared state is `shared-lines/<MD5-of-path>/` under the runtime data root: immutable
stock `bytes`, `meta` (mode, numeric UID/GID), `existence=present`, `path`, `build`;
immutable `versions/` snapshots with composed bytes and per-module patches; an
atomic `active` pointer; and a `pending` journal naming a fully prepared next
snapshot. A missing file has no matching line and is refused. Module-local
`line.<MD5-of-path>/ready` markers expose partial applies to lifecycle recovery.
Existing whole-file baselines must be reverted before using line ownership; never
adopt their applied bytes as stock. This expands the pre-deployment interface;
it does not convert active whole-file baselines.

Before apply/revert, product, current bytes and metadata must match the recorded
build and last composed state (stock when no snapshot is active). External edits
and firmware changes return conflict (3) and retain backups. Runtime also rejects
a claim held by a different enabled module or an active patch for the same stock
line, independently of generator validation.

Prepare next bytes, patches and audit events before atomic target replacement.
Interrupted preparation/write leaves stock or the previous composed file intact.
Recovery accepts only previous or fully prepared next bytes with stock metadata:
previous cancels the uncommitted transaction; next completes ledger/pointer
publication. Unknown bytes fail closed. Ledger publication is at least once across
interruption (audit rows can repeat). There is no force/adopt-external-content path.

Revert preflights every module target before its first restore. Recompose without
that module's patches, retaining other modules' patches. After the last patch,
verify stock bytes, mode and owner before clearing shared state. Line-only partial
applies are reverted at boot and preflighted on uninstall. `sg_applied <path>`
checks this module has active patches and the entire composed file matches.
Ledger `line_patch`/`line_revert` rows reference exact old/new line text files;
`line_compose` references before/after file bytes with toolbox MD5 hashes, product
and stock metadata. Ordinary ledger export includes these records.

The `wifi` module (built-in client role) and wireless projection never claim the same
`featurexml.cfg` line. Their exclusion is functional and role-dependent (the built-in
radio cannot be a client and serve the stock hotspot), see [wifi.md](wifi.md); file
safety is independent of it.

## Ownership of work areas

| Area | Owner worktree |
|---|---|
| `app/src/com/seogaemo/hmg/module/` (RootClient, ModuleManager, RootBackedModule), `nemesis/package/lib/common.sh`, `hmg-seogaemo-root` dependency/exclusion enforcement, payload packaging in `Makefile`, generic module rows in Settings UI | module runtime |
| `modules/wifi/**` | wifi |
| `modules/wireless-adb/**` | wireless-adb |
| `modules/wireless-carplay-and-aa/**` | wireless-carplay-and-aa |
| `app/src/com/seogaemo/hmg/core/update/**`, `nemesis/package/core/update.sh`, the `update` verb in `hmg-seogaemo-root`, `.github/workflows/release.yml` OTA parts | updater |

Module worktrees touch only their own `modules/<id>/` directory (plus their own `.agents/<id>.md`
notes). Anything outside needs a note in the final report instead of an edit.

## Reasserted user-button properties

Owner-approved `reassert_props=<csv>` explicitly permits reasserting and restoring
listed properties despite external value drift. Each entry must be a valid,
uniquely listed member of `owns_props`; `restore=reboot` is forbidden. Other
properties/files retain guarded compare-before-restore semantics. Product/build
guards remain mandatory, including for drifted values. Current users are only
`user-button-shortcut` / `persist.sys.key.swrccustom` and
`user-button-head-unit` / `persist.sys.key.custom`. Their confirmation warns that
HMG-Seogaemo wins over stock settings while enabled; turning the module off
restores the original baseline, overriding any intervening choice.

Exact-restore modules may declare `watch=boot,screen_on` when they declare
`reassert_props`. Initial confirmed apply captures the original baseline once;
subsequent `sg_prop_set` calls preserve it and record reassertions in the ledger.
Watch must require desired on, an existing baseline, and matching product; it must
never capture a new baseline. Read-only status reports pending reassertion while
desired on and drifted, using `state=pending-restart`, `restart=head_unit`, and
`info.desired=on`. This is a queued repair, not a request to restart the head unit.

On each active watcher poll (normally 5 seconds), enabled modules with
`watch=screen_on` and `reassert_props` are checked against their saved applied
property values. A ready baseline and applied marker are required. A mismatch
reuses fixed `watch screen_on` dispatch under the existing root lock and desired/
paused-state guards, even when the boot ID and dumpsys power state did not change.
No new event or root argument is exposed. Matching properties cause no call or
write. Disabling stops dispatch. Failed reassertions retry on subsequent polls;
physical timing after QUICKBOOT_POWERON still needs on-car verification. The
existing 300-second idle sleep can delay noticing the first newly enabled watch
module; once active the watcher uses its ordinary 5-second interval.

Restore preflight and property restore accept external drift only for explicitly
owned reassert_props. They still fail on product mismatch and retain backups on
failure. Restore ledger before bytes for these properties describe the observed
live drifted value, while the immutable baseline remains the first-apply value.

## Empty restore and diagnostics

A module with no restore material is already stock: sg_revert_all succeeds without
requiring a build marker. Restore material includes property/file/line ready
markers, bind records, changes, dex.cache, directory references (dir.* and
dir-order). Any such material retains the firmware, drift and metadata guards.
A stale saved desired=on is cleared only after a successful revert receipt.
Preflight conflicts expose the stage and target through detail output, and
whole-package restore includes that diagnostic in its final receipt.
File and directory metadata guard failures emit `info.restore_conflict` with
`file preflight: <path>` or `dir preflight: <path>` during restore preflight.
Direct restore and apply/delete guards identify their own stage in the same
field. These diagnostics keep the conflict return code (3) and retain all
baselines; they never authorize a mutation or weaken an existing guard.

## Payload metadata and directory transactions

Whole-file applied markers include `applied-meta` (four octal mode digits,
numeric UID and GID). Guards compare bytes and metadata and reject symlinks
at the target or any ancestor. A marker without metadata is backfilled
only after its bytes verify.
`sg_commit_file` accepts numeric owners (and normalizes `root:root` to `0:0`)
and verifies mode/UID/GID before rename.
Same-byte external chmod/chown is a restore conflict. Property backing baselines
also retain metadata.
Bind sources must be regular, non-symlink, public 0644 root-owned files; the
runtime refuses unsuitable sources rather than changing packaged inodes.

`sg_payload_dirs <owned whole-file path>` reconciles its ancestors through the
runtime. Existing stock ancestors outside `/system/etc/hmg-seogaemo` are checked
for symlinks but never adjusted. Created ancestors and project namespace dirs
are journaled before mutation, then set to 0755 root:root and verified. Module
namespace operations are restricted to `<namespace>/<module-id>/...`; the shared
namespace root has central baseline/applied metadata and per-module references.
The global operation lock serializes references. Last reference out restores or
removes the shared parent. Directory changes append ledger records. `ls -ldn`
provides fixed mode/UID/GID fields on KitKat; the parser handles toolbox's absent
link-count field and host listings without stat or text-processing tools.
Payload mode lint rejects literal private `/system` file modes, including simple
path-variable assignments, unless the call has an inline
`# payload-mode: allow -- <specific reason>` justification.

Directories use immutable existence/original metadata, a ready marker and a
pending intended metadata record before mutation. Recovery recognizes only the
original or intended/applied metadata; unknown metadata conflicts. Revert checks
all directory metadata before file restoration, then restores directories deepest
first. Created dirs are removed only if empty and still match; nonempty dirs
conflict and retain journals/backups. A retried restore accepts already-restored
original metadata or absent created dirs. Before restoring existing metadata,
the runtime durably publishes `restore-pending` (original metadata) and
`restore-intermediate` (current mode with original UID/GID). Guards accept those
known states after interruption; unknown metadata still conflicts. Reapply clears
restore intent only after its applied metadata is verified.
Existing dirs without a directory journal (including 0700
ancestors) are conservatively pre-existing with current metadata as baseline;
file-put provenance does not prove directory absence. Restore returns that
metadata and does not delete them, except the empty project-namespace directories removed by
`sg_legacy_dirs_cleanup` (Uninstall residue). No guessed absent baseline.

CarPlay apply reconciles recipes and ancestors before its already-applied return.
When assets are initially unreadable, repairs record the current boot before
their first mutation and remain pending-restart through that boot, because DiPO
reads recipes when registering native patches. Marker publication failure stops
repair before mutation; an interrupted repair retains the restart intent even
if all assets are already readable on retry. Read-only status
checks world-read file bits and world-search ancestor bits using permission
digits directly (leading-zero arithmetic differs between POSIX shells and
Android mksh). It reports failed with an assets-unreadable detail and does not
claim native patch success merely from
zygote loader presence. Boot reconcile already invokes desired apply, so it also
repairs ancestors after OTA. NativePatch keeps one attempt per process:
a failed native write may be partial, so retrying it is unsafe; restart is required.

Export publication makes only its dedicated container and descendants public:
0755 directories and 0644 regular files. Symlinks are refused; USB mount roots and
private runtime state are never chmod targets.

## Interrupted-write leftovers

Power loss during an atomic write leaves `<name>.hmg-seogaemo.<digits>` next to
the target (`sg_commit_file`), which would keep a created directory non-empty
and fail its `rmdir` (rc 3). Restore removes, with a ledger row
(`temp_sweep`): (1) in a directory the journal created (absence baseline) before its
`rmdir`, every regular, non-symlink entry whose name is exactly `<name>.hmg-seogaemo.`
plus digits; (2) after an owned file is restored, the same temporaries of that exact
file. Look-alikes (`.12a`, no digits, another suffix, directories, symlinks) are not ours
and still block. `zygote-prepare.<digits>` and `zygote-retired.<digits>` directories
directly inside the module state directory are removed by `sg_zygote_sweep` (at the start
of a payload upgrade, at the end of baseline clearing, and by `sg_revert_all` when there
is nothing to restore).

## Uninstall residue

Three kinds of generated or legacy leftovers are removed through the package API,
never by a module directly and never with a caller-supplied path:

- `owns_generated_dirs=<csv>` in `module.properties` declares exact
  `/data/data/<package>/app_hmg-seogaemo-<name>` directories that a loaded hook creates
  with `Context.getDir` (the wireless module declares the `-wireless-runtime` and the
  `-wireless-dex` directory of its six fixed packages; for `com.daudio.app.dipo` the dex
  files are additionally tracked by `sg_dex_cache_track`). The generator rejects anything
  else. `sg_generated_dirs_remove` is advisory and never fails a revert, restore or
  uninstall: hook processes keep writing until the head unit restarts, and every stock byte
  is already back by then. For each declared directory without a symlink anywhere in its
  path it removes the plain regular files (up to 64, names `[a-zA-Z0-9_.@-]`) and then the
  directory when empty, one `generated_dir_remove` ledger row per directory; symlinks,
  subdirectories and other entries are left untouched. If anything is left, or the revert
  just recorded a pending restart (`sg_restart_pending`), it writes the cleanup marker
  `<data root>/restart-cleanup/<module id>` (content: boot id), else it deletes the marker.
  Modules call it after `sg_revert_all` (the wireless `revert`), and `lib/stock.sh` calls it
  for modules with no restore material. `svc/reconcile.sh` retries markers at boot, before
  its pause check (the cleanup removes only our own diagnostic files), under
  `operation.lock`, through `sg_restart_cleanup_run`: markers of the current boot are
  skipped (hooks may still write), markers of unknown modules or odd names are dropped, a
  module that is desired on or holds restore material again is left alone (marker dropped),
  and any other module runs `sg_generated_dirs_remove` with its own declarations, which
  deletes the marker when everything is gone and rewrites it with the current boot id
  otherwise. After a full package uninstall nothing retries it: those few diagnostic files
  stay in the app data until the owner clears app data; they affect no stock behavior.
- After every module is restored, `lib/stock.sh` runs `hmg_seogaemo_stock_residue` (best
  effort, ledger row `stock_residue` ok/partial, never a conflict): `sg_legacy_dirs_cleanup`
  (`rmdir` only, in passes, of the directories between each owned path under
  `/system/etc/hmg-seogaemo` and the namespace, skipping any directory with a directory
  journal; this removes empty project-namespace directories at whole-package restore),
  `sg_legacy_dex_cleanup` (regular files in `/data/dalvik-cache` named
  `data@nemesis@apps@hmg-seogaemo` or `data@nemesis@backup@hmg-seogaemo@update` plus an
  optional `@...` middle plus `@core@map@hmg-seogaemo-mapper.jar`,
  `@app@hmg-seogaemo.apk` or the projection reader jar path, ending `@classes.dex`) and
  `sg_vm_cleanup` (the private `core/vm` cache and `core/vm.status.<digits>` scratch caches). Each removal is a ledger row.

## Dalvik cache of removed update versions

`sg_legacy_dex_cleanup` (stock restore and uninstall) already removes
`data@nemesis@backup@hmg-seogaemo@update@<anything>@<our jar suffix>@classes.dex`,
which covers `update@versions@<v>@...`. `sg_update_dex_prune <versions dir>` runs after a
successful OTA (`phase=healthy`) and after a failed stage removed its directory: it
removes exactly `update@versions@<digits.dots>@<our jar suffix>@classes.dex` whose
`versions/<v>` directory no longer exists. No ledger entry; failures never fail an update.

## Export flush and verification

The head unit mounts USB sticks write-back: a directory entry can reach the stick
before its data does.
`hmg-seogaemo-root export usb|adb` and `map export` therefore finish with
`sg_export_seal <dest> <usb|adb> [key...]` after the last write and the public chmod:

- writes `MANIFEST` (`<size><TAB><relative path>` for every exported file, sizes from
  toolbox `ls -ln`), then runs `sync`;
- for `usb`, re-reads every listed file and requires the recorded size, and requires
  each key file to match its source size (`<relative>=<source>`) or be non-empty:
  `ledger/ledger.tsv`, `package-version`, `ro.build.product`, `desired/*` for the ledger
  export, `<layout>/map.json` and `car.json` for the map export;
- a mismatch prints `state=failed`, `detail=USB write not flushed` and exits 1; only a
  sealed export prints `state=on`, `detail=<dest>`, `info.export_safe=usb|adb`.

The app shows "it is safe to remove the USB" (`export_usb_done`, KO "USB를 빼도 됩니다")
only for `info.export_safe=usb`. The check compares sizes the kernel reports; it cannot
prove the medium, so the instruction to the owner is still to wait for the dialog.

The app allows 10 minutes for ordinary USB export and `map export`, including
copying, diagnostics, manifest creation, sync and verification. These operations
must not use the 150-second module-write or 30-second map-status deadline. On
2026-11-06, each v0.1.30 USB export contained 1,798 files and took 145 seconds
from its destination timestamp to MANIFEST's modification time, before the USB
verification pass. The 150-second app deadline could expire while the daemon
continued exporting. Evidence: `tmp/car-reports/usb-20261106/`. The longer deadline
is covered off-car; completion of the fixed build still needs car verification.

## Diagnostic export

Ordinary USB/adb exports add diagnostics through lib/diagnostics.sh. Collection
is read-only except for writing its dedicated export destination. Each artifact
is capped at 64 KiB, with a 32-log (2 MiB) budget. Status probes have separate
64 KiB/10 second limits; owned-path metadata is capped at 8 KiB per module,
and properties at 64 KiB. A manifest reports omissions, truncations and probe exits.
Owned files and payload directories contribute ls -ldn metadata only, never
contents. Only fixed log/result paths are copied; Wi-Fi configuration and
secret-named properties are excluded/redacted. Optional runtime diagnostics
use the fixed HMG_SEOGAEMO_DIAGNOSTIC_RUNTIME_DIRS list relative to SG_DATA_ROOT
(initially runtime); only .log, .txt, result and module-output files qualify.
Export publication retains 0755 directories and 0644 files.

## Core car mapping

`hmg-seogaemo-root map status|run|verify|export` accepts exactly these fixed verbs.
`hmg-seogaemo-root recorder status|enable|disable|tick`, `preflight run` and `report digest` are further
fixed verbs (no arguments); see [reports-recorder.md](reports-recorder.md).
`status` hashes the catalogue's stock files and compares product, onebin, Android version,
and every stock MD5 with bundled or generated `car.json`; it is read-only.
`run` scans the full catalogue in a separate root `app_process` and reflects over the
mapped classes and members. `verify` repeats the reflection check for a matching map.
Both write only to package-allocated private scratch, then call `hmg_seogaemo_map_publish`.
`export` writes `maps/<make>/<model>/<region>/<firmware>/map.json` and `car.json`
to USB when mounted, otherwise the adb export directory. The existing `export usb|adb`
also includes the active PR-ready map folder.

The package API owns `hmg_seogaemo_map_work`, `hmg_seogaemo_map_publish`, `hmg_seogaemo_map_work_cleanup`, and
`hmg_seogaemo_map_export`. Publish validates fixed scratch filenames, product and hash IDs,
copies the verified map to an immutable directory under
`/data/nemesis/backup/hmg-seogaemo/car-maps/<product>/<stock-hash-id>/<map-id>/`,
records pointer and content changes in the ledger, then atomically replaces the
`car-maps/active` pointer file. The pointer is the only path consumers select;
there is no write to a stock file. A failed publish leaves the previous pointer.
The boot ID is included in the map ID and verification seal, so a new boot needs
reflection verification again.
The zygote hook gate (`HmgApi.zygoteInit`) checks only the first two lines of the `verified` seal
(product, stock hash ID), not the boot ID: the zygote starts about two seconds after boot while this
boot's verification finishes one to three minutes later. Every stock file is
still compared with the MD5s in `car.json` before the map is used. Module `hookpoints.required` IDs must all survive
resolution and reflection before publish. `map.json` exposes only verified points.
Generated maps and the ledger are package-local state retained for export until
package removal; module revert never removes them. The app invokes map commands
through `RootClient.map` on a worker thread, with fixed arguments and bounded output.

### Verification seal identity

The verified seal retains its product, stock-file hash ID and boot ID as the
first three lines, then appends an MD5 identity of the selected map/car bytes and export layout,
catalogue JSON files and packaged required-point manifests. A changed map,
catalogue or requirement invalidates cached status even within the same boot;
legacy three-line seals require verification once. Bundled verification binds
the original bundle inputs even when optional failures are filtered from the
published map; generated verification binds its published map/car. The immutable
map ID also includes the complete published car metadata and layout to avoid collisions.
The stock hash ID is unchanged. Zygote still accepts the first two seal lines
and checks exact identity and stock MD5s independently, allowing a previously
verified projection map to load before boot reconciliation completes. Optional
new points do not expand any module's required set.
The stock-guidance catalogue also exposes `framework.navigation_cluster.update_tbt_trap_info`
(17 ints, argument 12 is barGraphLevel), `update_tbt_trap_info_new` (one
`@framework.tbt_trap_info`), and `update_clu_data_new_14` (five ints), all returning void.
`framework.tbt_trap_info` names NavigationCluster's NaviTbtTrapInfo; `.new` is
its no-argument constructor and `.bar_graph_level` is its instance int field.
These six optional IDs have exact-stock host evidence; on-car reflection is pending.
Map IDs include the complete published car metadata and layout; optional reflection failures prune `by_reference` too; generated verification preserves export layout, binds the filtered published result and selects the active generated map before historical directories. Real-JVM fixtures cover these paths, static/reference signatures, required failure, stock mismatch and boot changes. The 18 v1.0.1 and six stock-guidance additions: [car-mapping.md](car-mapping.md).

## Java side
- `RootClient.run(String moduleId, String verb)` → `RootResult` (state, restart, detail, exit code).
  Fixed argv, bounded output, no shell strings from callers.
- `abstract class RootBackedModule implements Module`: implements `apply/revert/status` through
  `RootClient`; a module class extends it and only supplies metadata (`id`, string res ids,
  settings category, owned props/files, restart requirement) and optional pure-Java
  compatibility hints.
- `ModuleManager.plan(String id, boolean enable)` → `ModulePlan` (ordered enable/disable list incl.
  dependencies, dependents and exclusions, for the confirmation dialog); `ModuleManager.execute(ModulePlan)`.
  `ModuleManager.requestEnable(String id, String resumeIntent)` persists an intent that survives the
  head-unit reboot (used by the updater for `wifi`).
- Generic Settings rows (toggle, observed state, restart banner, confirmation dialog) are built by
  the runtime from module metadata. Modules do not edit UI code.
- Every module write, including `ENABLE_MODULE` from a declarative Settings action or Home tile,
  passes through the shared `ui.ConfirmDialog` after `ModuleManager.plan` and read-only `precheck`.
  The dialog lists ordered steps and active warnings; it disables Confirm on submission and shows
  progress until the operation finishes. Navigation-only actions remain direct.
- Module-specific pane content is declarative:
  - `Module.infoRows()` → `InfoRow[]` (`labelResId`, `infoKey`): runtime shows the value of
    `info.<infoKey>` from the last `status`, or "—".
  - `Module.notes()` → string res ids shown as plain text under the rows.
  - `Module.actions()` → `ModuleAction[]` (`labelResId`, `type`, `target`). v1 types:
    `ENABLE_MODULE <id>` (goes through `ModuleManager.plan` + confirmation),
    `OPEN_STOCK_WIFI_SETTINGS` (starts the stock Settings Wi-Fi screen).
- Pre-enable warnings belong to the module being enabled: `Module.enableWarnings()` returns
  `Warning[]` (`checkKey`, `messageResId`); the runtime asks the root side
  `hmg-seogaemo-root <id> precheck` and shows each warning whose `warn.<checkKey>=1` line is present,
  inside the same confirmation dialog. `precheck` is read-only and uses the status-block format.

### Home screen tiles

`HomeView` renders module-provided tiles selected by the runtime. Settings is always first; currently no built-in module supplies a Home tile.

- Home is a horizontally paged row of tall vertical cards (ccNC style), NEMESIS-scale touch targets.
- `Module.homeTiles()` → `HomeTile[]` (`id`, `labelResId`, `iconResId` or glyph, `ModuleAction action`,
  `int order`). Tiles appear only while their module is enabled (or always, if `alwaysVisible`).
- The runtime builds the tile list: the built-in **Settings tile is always first on page 1**; module
  tiles follow, sorted by `order` then module id; overflow continues on the next page with page dots
  and swipe/arrow navigation. Tiles per page is a layout constant (not per module).

### Settings layout and module pages

- Sidebar, top to bottom: core categories (General first, then e.g. "Modules", Logs, About),
  a divider, then one entry per module ("module settings"), in generated module order.
- **Modules** (working name; KO "모듈 관리"): one large row per module with ON/OFF toggle, observed
  state and restart banner; toggling goes through `ModuleManager.plan` + confirmation dialog.
- **Module settings pages**: each module gets its own page. Reusable components live in the core app
  (`com.seogaemo.hmg.ui.settings`): `SettingsPage` builder with `section(titleRes)`,
  `info(labelRes, infoKey)`, `toggle(labelRes, settingKey)`, `choice(labelRes, settingKey, valuesRes)`,
  `action(labelRes, ModuleAction)`, `note(textRes)`, `warning(textRes)`, `statusHeader()`.
  Modules compose their page in `Module.buildSettingsPage(SettingsPage page)`; they never create
  Android views themselves. Default implementation (in `RootBackedModule`) renders
  `statusHeader()` + `infoRows()` + `notes()` + `actions()`, so declarative modules need no code.
- Components follow `ui-guidelines.md` (NEMESIS-scale rows, EN/KO).

Pane/precheck decisions per module live in [wifi.md](wifi.md) and [wireless-adb.md](wireless-adb.md). Strings: modules add only `<snake_id>_*` resources in their own `res/values{,-ko}/strings.xml`.

## Restore-on-uninstall guarantees (owner priority)

- Every `/system` or `/data` change made by a module is baselined before the first write and
  restored byte-exactly on revert/uninstall. Nothing outside baselined paths/props may be written.
- Restore is guarded: only undo what we wrote. If the current content is neither our applied copy
  nor the baseline (e.g. an official firmware update replaced `/system`), do not write stock bytes
  from an older firmware; report conflict, keep backups, and let the uninstall fail closed.
- Baselines are bound to `ro.build.product`; a different firmware build invalidates them (conflict).
- Uninstall aborts (non-zero preuninstall) rather than leaving a half-restored system.

## Names and paths

Application ID and Java base package `com.seogaemo.hmg`; built-in modules `com.seogaemo.hmg.modules.*`; NEMESIS package ID `hmg-seogaemo`; root dispatcher `hmg-seogaemo-root`; installed under `/data/nemesis/apps/hmg-seogaemo`, state under `/data/nemesis/backup/hmg-seogaemo`; USB wrapper contains `packages/hmg-seogaemo.zip`. Root environment: `HMG_SEOGAEMO_BASE`, `HMG_SEOGAEMO_STATE`, `HMG_SEOGAEMO_MODULE_DIR`; the `sg_*` prefix is the stable runtime API. Package and OTA APK entry `app/hmg-seogaemo.apk`; wireless assets `/system/etc/hmg-seogaemo/`, `/system/bin/app_process.hmg-seogaemo-stock`, `/system/lib/libhmg_seogaemo_wireless_hook.so`, `/system/framework/hmg-seogaemo-wireless-hook.jar`; derived Dalvik cache names follow the JAR and the `app_hmg-seogaemo-wireless-dex` directory.

Example export: `adb shell /data/local/tmp/nemesis-d root -c '/system/bin/sh /data/nemesis/apps/hmg-seogaemo/bin/hmg-seogaemo-root export adb'`.

## Shell tools on the head unit

Hard rule in AGENTS.md; compatibility authority is `tools/android44-shell-profile.json` checked by `tools/lint-android44-shell.py` during `make test`; evidence and waivers in [android44-shell-audit.md](android44-shell-audit.md). Stock userland is toolbox + mksh only (`tmp/hmg_nemesis/01-DSP-OTA-troubleShooter.md:121`, `05-Run-Scripts.md:101`).

- Usable: mksh builtins (`case`, `read`, `${var#…}`, `${var%…}`, `print`, `echo`, `test`, arithmetic); toolbox `cat cmp cp dd grep ls mkdir mv rm rmdir ln chmod chown touch sleep ps kill md5 mount umount sync date id ifconfig netcfg route getprop setprop start stop log dmesg`; system binaries `pm am settings service app_process logcat dumpsys wpa_cli /system/xbin/nemesis`.
- Absent: `printf`, `awk`, `sed`, `tail`, `head`, `cut`, `tr`, `wc`, `sort`, `uniq`, `xargs`, `find`, `stat`, `timeout`, `which`, `seq`, `basename`, `dirname`, `sha256sum`/`sha1sum`, `tar`, `unzip`, `busybox`, `toybox`.
- KitKat has BSD `grep` (`-E -F -q -x -c`) and `readlink -f` (via `realpath`; unused). `cat` and `sleep` resolve to mksh builtins first (`HAVE_SELECT`); sleeps are integer seconds. R43 has no `set -o pipefail`; don't infer features from the newer host mksh. Parse with `while read`, `case`, parameter expansion. Toolbox `mv` has no options (plain rename replaces). Toolbox `md5` needs filenames; hash a text pipe via `/proc/self/fd/0` and check the exit status. Never store binary baselines in variables.
- The profile is a conservative reviewed subset, not a promise that every unlisted AOSP tool is absent. Host-only payload build helpers are excluded from archives; every shipped shell member, including generated modules, is checked. Dynamic arguments must be data, paths, or values of literal options, never option bundles or command text. Fixed project helpers are checked at their definitions; literal `sh -c` and trap bodies and command substitutions are checked recursively. Waivers apply to one physical line and need manual review of the whole line. The lexer does not prove data flow, service responses, kernel behavior or vendor binaries; keep byte-exact restore tests and on-car validation separate.
