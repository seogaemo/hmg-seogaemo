Status: current — NEMESIS packaging facts, implemented package layout, USB/update behavior, extraction-mode audit.

# NEMESIS packaging for HMG-Seogaemo

Paths and line references below are relative to `tmp/`. Describes NEMESIS 1.16.4 source/docs.

## Verified facts

### Package and descriptor

A package is a zip with `NEMESIS.data` at its root; NEMESIS unpacks it under `/data/nemesis/apps/<id>/` and records packages/services in `/data/nemesis/*.db`. The USB stick has a *different* root `NEMESIS.data` that points to `packages/<id>.zip`. `hmg_nemesis/04-Packages.md:9-19,196-214`; `hmg_nemesis/Sources/native/pkg.c:258-263`.

The zip descriptor's `[nemesis]` requires `id` (up to 64 characters; letters/digits/`.`/`_`/`-`, no leading `.`/`-` or `..`). Recommended fields: `version=1.1` (descriptor version, not app version), `name` (defaults to id), `type` (comma list; legacy `types` fallback), dotted-numeric `package-version`, and `short-desc` (at most 64 characters). Optional: `detailed-desc` (at most 256), `depends`, `os`, `models`, and the four hook paths. Missing descriptor version means 1.0; missing `os`/`models` means `any`. `hmg_nemesis/04-Packages.md:27-48`; `hmg_nemesis/Sources/native/meta.c:214-264`.

`depends` accepts `id`, `id@any`, `id@1.2`, `id@>=1.2`, `id@<=1.2`, `id@1.2-1.5`; prefix `!` excludes that id/version. `1.2` equals `1.2.0`. Self-dependency or both need/exclude is invalid. Missing dependencies and conflicts stop install (22/23); an update that breaks a dependent stops (21), and uninstall of a needed package stops (4). `os` and `models` accept comma-separated `*`/`?` globs. OS match gives `full`; OS miss plus model match gives `partial`; both miss gives `incompatible` (20 unless `--accept-risk`). `hmg_nemesis/04-Packages.md:50-82`; `hmg_nemesis/Sources/native/meta.c:57-103,192-211,294-309`.

`preinstall` runs in the staging directory before copy; `postinstall` runs after copy/APK install/service registration in the installed tree. `preuninstall` runs after service stop, before APK uninstall; `postuninstall` is copied to a temporary path before running. Hooks run as root. NEMESIS 1.16.4 rejects any hook, `[app.N]`, or `[service.N]` path with a `..` component, although absolute paths remain allowed; zip extraction also rejects traversal members. `hmg_nemesis/04-Packages.md:41-48,253-264`; `hmg_nemesis/Sources/native/pkg.c:228-284,629-715`; `hmg_nemesis/README.md:82-88`.

`[app.N] kind=apk,path=app/hmg-seogaemo.apk` invokes `pm install -r`. `package=` gives the Android package id for uninstall; `component=package/class` is preferred for Manager Launch, otherwise a launcher activity is used. `[app.N] kind=sh,path=bin/open.sh` makes Launch run a script. `[service.N]` registers `<id>/<name>`: `kind=sh` runs a script (including with Android down); `kind=instance` starts an Android component after Android is up. `uid=root` is default or `uid=system` is UID/GID 1000. `mode=restart` relaunches until five rapid deaths; `background` starts once; `once` waits. `hmg_nemesis/04-Packages.md:86-120`; `hmg_nemesis/Sources/native/svc.c:136-205`.

Backups under `/data/nemesis/backup/<id>/` are **package script policy**, not a generic NEMESIS uninstall guarantee. Upstream packages snapshot live files in `postinstall`, restore in `preuninstall`, and delete their own backup directory only after success; failed restore keeps it. Native uninstall deletes the package tree, but has no backup-directory deletion in that path. HMG-API's note says NEMESIS deletes backups on uninstall; the source/examples show the narrower behavior, so our scripts must own cleanup. `hmg_nemesis/04-Packages.md:184-186,241-249`; `hmg_nemesis/Sources/packages/adb-tcp/scripts/preun.sh:5-13`; `hmg_nemesis/Sources/native/pkg.c:629-680`; `HMG-API/CLAUDE.md:63`.

### APK installation, signing, and root

On these units, `sys.boot_completed=1` makes PackageManager reject non-OEM-allowlisted APK signers with `INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES`, even on first install. NEMESIS temporarily sets it to `0` around `pm install -r`, restores it, and checks output text (`pm` may exit 0 on failure). If an installed package really has a different signer, NEMESIS checks `pm path`, uninstalls, then retries once. Android-down install leaves the APK in the package tree; `pkg-launch` can install it later. `hmg_nemesis/Sources/native/pkg.c:460-549,1067-1079`; `HMG-API/CLAUDE.md:52`.

This supports a **normal user app** installed by `pm`; there is no need to put our APK in `/system/app` just to use NEMESIS. HMG-API uses v1/JAR APK signing for API 19 and a stable release key (throwaway only for development); the OEM allowlist issue is independent of the digest. Preserve one signing key for HMG-Seogaemo updates because an actual signer change triggers uninstall/reinstall. `hmg_nemesis/04-Packages.md:3,86-100`; `HMG-API/build.sh:103-115`; `hmg_nemesis/Sources/native/pkg.c:493-505`.

For Manager Launch, HMG-API deliberately declares `[app.0] kind=sh,path=bin/open.sh` without `package` or `component`: its script calls `/data/hmgapi/open.sh`, which reinstalls a missing app with the temporary boot-property change, then `am start`. This avoids NEMESIS's automatic `pm uninstall` of an `apk` entry during package update. The `nemesis-shortcut` HMG-API mod goes the opposite direction: it adds *NEMESIS Manager* to HMG-API's menu, not our app to NEMESIS. `HMG-API/install/nemesis/NEMESIS.data.in:15-18`; `HMG-API/install/nemesis/bin/open.sh:1-10`; `HMG-API/install/common/app-open.sh:1-35`; `HMG-API/install/nemesis/README.md:37-43`; `HMG-API/mods/examples/nemesis-shortcut/mod.json:10-26`.

An installed app can invoke `/system/xbin/nemesis root -c '...'` for a command, or `nemesis root 1000 -c '...'` for a system-UID command. Non-root callers go through the watchdog's command socket; its sockets are mode 0666 and **any UID** may use this channel—there is no package/Android-permission allowlist. The privileged service can instead run its shell script as root. Security consequence: NEMESIS itself makes root broadly available, so HMG-Seogaemo should expose only fixed, validated module actions and avoid arbitrary command strings or untrusted input. `hmg_nemesis/Sources/native/main.c:35-55`; `hmg_nemesis/Sources/native/su.c:64-113,229-258`; `hmg_nemesis/02-Debugging-Execution-Interface.md:129-163`; `HMG-API/CLAUDE.md:49`.

From ADB, the SUID binary may produce *weak* root (adbd's limited capability set). HMG-API documents copying the binary without SUID to `/data/local/tmp/nemesis-d` so the call goes through NEMESIS's full-root daemon. NEMESIS daemon commands inherit `umask 0`; scripts that create files should set `umask 077`. `HMG-API/CLAUDE.md:50-51`; `hmg_nemesis/Sources/native/util.c:670-687`.

### Delivery, updates, and operational constraints

USB: unzip a delivery archive to the stick root as `NEMESIS.data` (`[nemesis] version=1.0,type=install,path=packages/hmg-seogaemo.zip`) plus `packages/hmg-seogaemo.zip`, then confirm on the head unit. `path` is relative and rejects `/`, `..`, and shell metacharacters. With Android down, only a root `NEMESIS.emergency` permits automatic, unprompted install; leave that marker off normal media. CLI/ADB shell: `nemesis install <zip>`, `nemesis install --update <zip>`, `nemesis uninstall <id>`; Manager Store/My Packages offers install/Launch/uninstall. `hmg_nemesis/04-Packages.md:196-249`; `hmg_nemesis/05-Run-Scripts.md:20-52`; `hmg_nemesis/02-Debugging-Execution-Interface.md:129-148`.

Store: submit the **package zip** through xwtk.Portal with an HTTPS repository URL; account approval reserves its id, and updates use the same id with a higher dotted `package-version`. Manager checks HTTPS and SHA-256 for downloads; `nemesis_roots.pem` holds HTTPS trust roots, **not** a package-signing key. The zip's own descriptor controls actual install. No separate cryptographic zip signature is described in the local package/Store flow. `hmg_nemesis/07-Submit-a-Package.md:11-56`; `hmg_nemesis/06-Cloud-Store-API.md:11-31,138-146`; `hmg_nemesis/04-Packages.md:9-11`.

HMG-API's `tools/mkinstallers.sh` builds `hmgapi-<v>-nemesis-package.zip` directly from descriptor/scripts/bin/payload, then `hmgapi-<v>-nemesis.zip` as a USB wrapper containing root descriptor and `packages/hmgapi.zip`; it also makes separate adb/combined USB distributions. Its `preuninstall` detects a staged update and skips removing the live HMG-API installation, while real uninstall restores it. NEMESIS updates stop services, run old uninstall hooks/APK removal, remove old tree, then install the new tree; a failed removal keeps the old package unless forced. `HMG-API/tools/mkinstallers.sh:1-13,42-66,68-90`; `HMG-API/install/nemesis/scripts/preuninstall.sh:1-22`; `hmg_nemesis/Sources/native/pkg.c:851-890`.

Target **NEMESIS 1.16.4 or newer** for the current path validation and service fixes; descriptor 1.1 debuted in 1.16, dependency/conflict behavior improved in 1.16.3. Known field issues: a stale watchdog pidfile may prevent daemon startup; `/system` remount should use `nemesis remount rw|ro` (toolbox remount fails); the unit lacks `tail`; shell scripts need KitKat toolbox-compatible commands. `hmg_nemesis/README.md:82-115`; `HMG-API/CLAUDE.md:50-58`; `hmg_nemesis/04-Packages.md:182`.

### USB reinstall and update route

- Never infer an update from stale staging files or USB presence. NEMESIS 1.16.3+ (including 1.16.4) uses `install --update`: `pkg.c` stages `/data/local/tmp/nemesis/stage/hmg-seogaemo/` before the old hook, and `util.c:run_script` forks and execs sh with the install process as parent; the existing guard preserves state on that route.
- The USB wrapper uses confirmed `type=execute` and a fixed script calling `nemesis install --update` for fresh installs and replacements (cwd = stick root). `type=update` is reserved for NEMESIS core ZIPs. Real uninstall keeps guarded stock restore and APK removal; works when updating an older installed hook. No upstream code copied.
- Old installed stable dispatchers need one fixed NEMESIS USB package refresh. New stable entries delegate to the selected OTA logic, but USB postinstall always uses its fresh tree. Successful APK install (or Android down) retires stale OTA selection/rollback pointers and journal, keeping version directories, baselines, ledger. Failed APK install preserves selection. Host fixtures cover both Android-up outcomes.

## Implemented package

`make package` builds `hmg-seogaemo-<v>-nemesis-package.zip`,
`hmg-seogaemo-<v>-nemesis-usb.zip`, `hmg-seogaemo-<v>-ota.zip`, and an APK asset. A signed release also has a manifest, signature, and `SHA256SUMS`. The USB archive contains root
`NEMESIS.data` and `packages/hmg-seogaemo.zip`. The inner descriptor is 1.1,
`id=hmg-seogaemo`, `name=HMG-Seogaemo`, `type=application,service`, `os=any`,
`models=any` (as NEMESIS's own packages), a root shell app entry, and a root one-shot service.
`postinstall.sh` refuses anything but API 19 before installing the APK; firmware
support is decided per module by the car map. The package includes module scripts, metadata, the shared mutation API,
and boot reconciliation. A real uninstall removes the APK; an update
with a valid staged HMG-Seogaemo descriptor retains it and its app data.
When Android is down, postinstall leaves the APK in the package and Manager
Launch installs it once Android is up. The Android-down path is untested on a car.

## Package design rules

- Build is top-level `make package` (see AGENTS.md); mirrors HMG-API's assembly (`HMG-API/tools/mkinstallers.sh:42-58`); validate with `nemesis pkg-info` before car tests.
- `[app.0] kind=sh,path=bin/open.sh,uid=root` without `package`/`component` preserves app data across NEMESIS package updates (a `kind=apk` entry makes NEMESIS `pm uninstall` the app); follows HMG-API's open/install pattern (`HMG-API/install/nemesis/README.md:37-43`).
- `postinstall`: `umask 077`; copy the APK to a package-owned location readable by PackageManager; install/update when Android is up with the boot-property workaround; save live-file snapshots first. Android-down installs: bounded background install after `sys.boot_completed=1` (HMG-API's pending installer, `install/common/app-pending.sh:1-34`), Launch can reinstall (`install/common/app-open.sh:15-35`).
- `preuninstall`: distinguish staged update from real removal; on real removal restore exact snapshots, uninstall the APK, delete backups only after successful restoration (`install/nemesis/scripts/preuninstall.sh:1-22`; `adb-tcp/scripts/preun.sh:5-13`). `/system` edits need stock checks and `nemesis remount`.
- A `[service.0]` long-running helper only for genuine long-running work; toggles call `nemesis root -c` on demand.

## Extraction modes and execution audit

Verified on the real Ioniq 5 KOR (2026-11-03, v0.1.4 installed with `nemesis install <package.zip>`).
NEMESIS ignores ZIP Unix modes: installed `scripts/*` and `svc/*` are 0755;
all other package files are 0644. `bin/nemesis-client` is 0755 only because
postinstall explicitly creates/chmods it. HMG-API shows the same extraction
pattern and invokes shell payloads with `sh`. Direct execution of
`bin/hmg-seogaemo-root map status` failed with Permission denied; running
`/system/bin/sh <dispatcher> map status` worked, with 324/324 verification.
This verifies the invocation failure and mapper result, not all module behavior.

Audit and resulting rules:

| Caller | Packaged target | Invocation / mode responsibility |
| --- | --- | --- |
| `RootClient` | `bin/hmg-seogaemo-root`: module lifecycle, map, export, stock, uninstall | Fixed allowlisted commands prefixed with `/system/bin/sh`; daemon transport stays the installed `bin/nemesis-client` |
| `UpdateClient.root` | dispatcher `update stage/apply/rollback/status` | Same interpreter prefix and daemon client; verb validation unchanged |
| `NEMESIS.data` | `bin/open.sh`, `svc/reconcile.sh`, `svc/watcher.sh` | All declared `kind=sh`; postinstall additionally chmods the three bin shell entry points as defense for direct Launch execution |
| NEMESIS hooks | `scripts/postinstall.sh`, `scripts/preuninstall.sh` | NEMESIS root hooks; extraction already makes scripts executable |
| postinstall / open | `bin/install-apk.sh`, including OTA current | Explicit `/system/bin/sh` |
| root dispatcher | `core/stock.sh`, `core/hmg-seogaemo-map.sh`, fixed installed `core/update.sh`, `modules/<validated-id>.sh` lifecycle/watch | Explicit `/system/bin/sh`, no executable-mode checks |
| reconcile | updater rollback, OTA current reconcile, dispatcher apply/revert | Explicit `/system/bin/sh` |
| watcher | OTA current watcher, dispatcher boot/screen_on | Explicit `/system/bin/sh` |
| preuninstall / stock library | stock restore, module revert, detached uninstall runner copied outside package | Explicit `/system/bin/sh`; detached runner/common additionally chmod 0700 |
| Wi-Fi / projection module probes | dispatcher projection status / map status | Explicit `/system/bin/sh`; Wi-Fi checks regular file existence rather than `-x` |
| OTA updater | current install-apk, health reconcile, rollback install-apk | Explicit `/system/bin/sh`; extracted scripts need no chmod, including payload-only updates |
| postinstall | native `bin/nemesis-client` copied from `/system/xbin/nemesis` | chmod 0755 on temporary copy before rename; never a ZIP payload executable |
| projection package API | native wrapper installed as `/system/bin/app_process` | `sg_zygote_install` / `sg_commit_file` explicitly commits mode 0755; stock executable copy uses captured stock mode and is checked executable |
| native wrapper | `/system/bin/app_process.hmg-seogaemo-stock` | `execve` of installed baseline copy, never extracted payload |
| projection package API | loader, AAC shared libraries and hook JAR | Explicit 0644 installs; loaded as libraries/classes, never executed as packaged binaries |
| mapper / update verifier | mapper JAR / trusted APK | System `app_process` with CLASSPATH; files need readability only |

Upstream source cross-check: `Sources/native/util.c:420-449` implements
`run_script` by chmod 0755 followed by `execl("/system/bin/sh", "sh", script, ...)`;
`pkg.c:1096-1099` sends kind=sh Launch through it. `svc.c:195` selects the same
interpreter for shell services. The bin chmod is defense in depth, not required
by those upstream interpreter paths.

All `lib/*.sh` inputs are sourced, not executed. Module build scripts and native
compiler helpers are host-only and excluded from device payloads. No packaged
native binary is executed in place. OTA does not run postinstall, so its shell
paths rely on interpreter invocation and native system installs rely on the
same package API modes, independently of archive metadata.

Regression coverage: package fixtures reproduce scripts/svc 0755 and other
entry points 0644; dispatcher/module lifecycle and watch tests run with 0644
inputs; Wi-Fi and projection probes use non-executable fake dispatchers; native
zygote tests install from 0644 payloads and assert both installed executables;
OTA transaction tests exercise staged ordinary files, health checks and rollback.
Java command-string checks cover every root operation. Host fixtures translate
only `/system/bin/sh` to the selected host shell because macOS has no device
interpreter; POSIX sh and, when installed, mksh suites exercise the translated
private copies.
