Status: current — implemented architecture; per-module car evidence is in each module doc and AGENTS.md.

# Built-in module architecture

HMG-Seogaemo on Gen5W (Android 4.4.2/API 19, 1920×720 hdpi, English default + Korean), installed by NEMESIS 1.16.4+, target setup NEMESIS + HMG-Seogaemo only (no HMG-API). Built-in modules (`wifi`, `wireless-adb`, `wireless-carplay-and-aa`, `skip-consent-screen`, `user-button-*`; the list is generated from `modules/*`) are compiled into one APK and one NEMESIS package; no third-party loader (installable `.hsm` packages: [installable-modules.md](installable-modules.md)). Wi-Fi client and ADB are independent implementations; wireless projection ports AGPL-covered HMG-API code with attribution ([wireless-carplay-and-aa.md](wireless-carplay-and-aa.md)). Per-module behavior: [wifi.md](wifi.md), [wireless-adb.md](wireless-adb.md), [skip-consent-screen.md](skip-consent-screen.md), [user-button-shortcut.md](user-button-shortcut.md). Interfaces: [module-runtime-contract.md](module-runtime-contract.md).

NEMESIS services: `reconcile` (`background`, boot reconciliation + OTA health) and `watcher` (`svc/watcher.sh`, `mode=restart`; dispatches fixed boot/screen-on watch events, never apply/revert) — see [boot-lifecycle.md](boot-lifecycle.md).

## Module contract

- A `Module` has: stable ID; EN/KO name and description resource IDs; Settings category and optional Home action; `requiresRoot`; typed settings (currently none); `checkCompatibility`, `checkConflicts`, `apply`, `revert`, `status`; restart requirement (`NONE`, `ADBD`, `HEAD_UNIT`). Root status reports state, restart, detail; `ModuleStatus` derives desired/observed from it (last-operation time stays 0).
- Registry lists only built-in modules, generated from `modules/*/module.properties`. `owns_props`, `owns_files`, `owns_lines.N` name what a module may change; `conflicts` lists external owners to detect and refuse; `depends`/`excludes` relate built-in IDs.
- `wireless-adb` does not depend on `wifi` (optional). `wifi` with the built-in client role and `wireless-carplay-and-aa` exclude each other through the app planner and the module's own checks ([wifi.md](wifi.md)); declared exclusions are symmetric even if declared on one side. Enabling a module auto-enables its dependency chain after UI confirmation; disabling auto-disables dependents. Enabling an excluded module prompts with the exact enabled modules that will be turned off (including dependents), then disables them first. Root re-checks dependencies and exclusions and refuses inconsistent states. Boot reconciliation applies in dependency order, reverts in reverse. Implemented and exercised off-car.
- Root scripts check Android/product, owner, chip and stock-file conditions before mutating. Package install checks only API 19 (descriptor `os=any`, `models=any`); every module needs a car map for the exact `ro.build.product` and projection additionally requires this boot's map verification (runtime contract, "Car gate"). NEMESIS 1.16.4+ is the target but not runtime-probed. Unknown variants fail closed where guards require exact evidence. NEMESIS descriptor `os`/`models` narrows installation but doesn't replace module checks. Descriptor `depends=!id` is for package-wide conflicts only; module-only conflicts (including `adb.tcp`) are runtime checks so the rest stays installable. HMG-API/Leafia/NEMESIS ownership checks only detect leftovers and refuse mutation; none is a dependency (`tmp/hmg_nemesis/04-Packages.md:27-80`).

## State, privilege, recovery

- Root owns `/data/nemesis/backup/hmg-seogaemo/` (0700): desired-state files, per-module baselines, change ledger, update journal, reconcile log. APK preferences hold only UI choices such as language, never enabled state.
- Before the first mutation of an enable session, snapshot each owned persistent property's live value and `/data/property/<key>` existence/content (absent ≠ empty) and each owned file's bytes, existence, mode, ownership. Never overwrite a baseline on reapply/update. On revert restore values and backing-file absence/content; clear the baseline only after verification. An originally absent property is cleared live and its backing file removed; exact boot-state restoration may need a reboot (compare HMG-API's unset path, `tmp/HMG-API/core/runtime/java/hmgapi/engine/Engine.java:2007-2013`).
- Operations take one root lock and journal intent. Apply changes only differing values, verifies readback, commits desired state after success; repeats are harmless. Failure rolls back to baseline when safe, else retains the snapshot and reports an error. External owner or unexpected drift → stop, never overwrite.
- Boot: a NEMESIS root service waits for properties, checks compatibility/ownership, reconciles enabled modules. The APK has no `BootReceiver`.
- Package update: the old `preuninstall` recognizes a valid staged update and preserves state; the new `postinstall` installs the APK; the boot service reconciles preserved desired state. Real uninstall: `preuninstall` reverts every enabled module and verifies restoration before allowing removal, then removes package state and the APK; failed restoration keeps backups and aborts uninstall (NEMESIS runs the old hook on update and stops services first: `tmp/hmg_nemesis/Sources/native/pkg.c:630-680,851-880`; backup cleanup is the package's job: `04-Packages.md:184-186,241-249`). Direct `pm uninstall` of only the APK bypasses the hook: the boot service must detect the missing APK and revert next boot; the UI directs users to NEMESIS uninstall. Whole-package restore/uninstall details: [stock-restore.md](stock-restore.md).
- The UI is an unprivileged APK calling `hmg-seogaemo-root <id> apply|revert|status` (and `set <id> <key> <value>` for installed modules) with registered IDs/verbs, fixed paths/commands, no caller shell fragments or paths, bounded output, `umask 077`. NEMESIS's root socket is open to any UID, so this limits only our own interface (`tmp/hmg_nemesis/Sources/native/su.c:64-103,229-258`).

## Source and package layout

One module = one directory under `modules/`; the module list is generated at build time (no hand-edited list). Layout summary is in AGENTS.md; module directory shape:

```text
modules/<id>/                       # dir name == module id
  module.properties                 # id, class, version, requires_root, restart, owns_props/files/lines.N, depends, excludes, conflicts
  src/com/seogaemo/hmg/modules/<idnohyphen>/<Class>Module.java
  res/values/strings.xml, res/values-ko/strings.xml   # <snake_id>_* only
  root/<id>.sh                      # apply | revert | status | precheck, run as root
  test/                             # off-car script tests
```

Naming: kebab-case module ID `[a-z0-9]+(-[a-z0-9]+)*`; Java package drops hyphens; resources use the snake_case ID prefix; root script `<id>.sh`.

`tools/gen-modules.sh` (POSIX sh + awk, run by `make` before aapt/javac):

1. Scan `modules/*/module.properties` sorted. Fail if `id` ≠ directory, duplicate/malformed ID, `class` missing from `src/`, `root/<id>.sh` missing while `requires_root=true`, or a resource name lacks the module prefix.
2. Parse `depends=`/`excludes=` as comma-separated built-in IDs. Reject unknown IDs, self-reference, cycles, and any dependency closure containing an excluded pair. Symmetrize `excludes`. Emit topological order, lowest ID first among ready modules.
3. Generate `out/gen/com/seogaemo/hmg/module/GeneratedModules.java` (Java 1.7 arrays: instances, ordered IDs, dependencies, symmetric exclusions). `ModuleRegistry` gives read-only copies; switch planning/execution is in `ModuleManager`.
4. Generate `out/package/modules.list` (dependency order) and `modules.graph` (tab-separated `id`, `depends=<csv>`, `excludes=<csv>`), plus `modules.lines` for line claims ([module-runtime-contract.md](module-runtime-contract.md), "Shared text-file line ownership"). Copy scripts to `out/package/modules/<id>.sh`; render each `module.properties` with `VERSION`. The packaged `hmg-seogaemo-root` accepts only listed IDs and fixed verbs.
5. Compile `javac` over `app/src`, `modules/*/src`, `out/gen`; link `aapt package -S app/res -S modules/<id>/res … --auto-add-overlay`, single `R` package `com.seogaemo.hmg`.

`MainActivity` hosts Settings controls, module pages, Logs export, update actions. `HomeView` renders enabled modules' `Module.homeTiles()` after the built-in Settings tile (current modules supply none). `make package` assembles descriptor 1.1 (root shell app entry, one-shot service, API 19 v1-signed APK, USB wrapper); archive names start `hmg-seogaemo-<version>`; release builds need the stable keystore, debug builds a throwaway key. Package behavior: [research-nemesis-packaging.md](research-nemesis-packaging.md). UI sizes (70 dp sidebar, ≥75 dp rows, 60 dp actions): [ui-guidelines.md](ui-guidelines.md); the restart banner shows the requirement but a successful `adbd` restart alone does not claim a head-unit reboot.
