# hmg-seogaemo

## Naming

Project-owned names use `hmg-seogaemo` for paths and artifacts, `hmg_seogaemo`
for snake-case identifiers, `HMG_SEOGAEMO` for environment variables and constants,
`HmgSeogaemo` for Java class prefixes, and `HMG-Seogaemo` for display and log text
(exception: the app header title reads `HMG Seogaemo`, owner choice).
The Java package `com.seogaemo.hmg` and the GitHub repository
`seogaemo/hmg-seogaemo` retain their owner-chosen names. The existing `sg_*`
shell functions and internal variables remain the module runtime API prefix;
renaming the entire API would add churn to all modules and tests without changing
the project identity. New root-side environment variables use `HMG_SEOGAEMO_*`.

HMG-Seogaemo: an app + root package for Hyundai/Kia/Genesis **Gen5W** head units, installed
through **NEMESIS**, made of toggleable modules. Target setup is **NEMESIS + HMG-Seogaemo only**
(HMG-API and HMG Leafia Plus are not installed alongside; they are upstream references).

## Before starting work

1. Read `.agents/README.md` (index + reading order), then the docs it marks **current**,
   at least `module-runtime-contract.md` and `module-architecture.md`. Docs marked
   *historical* explain past decisions; do not implement from them.
2. If `AGENTS.local.md` exists, read and follow it (per-user, gitignored).
3. Upstream references are not in git. Clone them yourself into `tmp/` (gitignored):
   `git clone https://github.com/xwtk/hmg_nemesis tmp/hmg_nemesis`,
   `git clone https://github.com/VysseCodes/HMG-API tmp/HMG-API`,
   `git clone https://github.com/VysseCodes/HMG-Leafia-Plus tmp/HMG-Leafia-Plus`.
   Many `.agents` citations point into `tmp/`. Car reports go in `tmp/car-reports/` (never commit them).
4. Add new findings to `.agents/` (and list new docs in `.agents/README.md`). For mapping work,
   read `docs/mapping-new-firmware.md` and `UPSTREAM.md` as well.

## Reference car (verified facts)

No code is tied to this car by name: the package installs on any Gen5W on Android 4.4 (descriptor
`os=any`, `models=any`), bundled modules declare `cars=*`, and each module needs a car map for the
exact `ro.build.product` (runtime contract, "Car gate"). Other cars are untested on a car.

- Hyundai Ioniq 5, Korea. `ro.build.product` = `NEEV.KOR.0000.V039.001.260902` (glob
  `NEEV.KOR.*.260902`; NEMESIS compares `os=` to `ro.build.product` with globs, so an exact
  `NEEV.KOR.260902` never matches). Its map is the only bundled one.
- onebin `neev_kr`, Android 4.4.2 (API 19, Dalvik), Telechips, display 1920x720 hdpi (density 1.5).
- Owner-verified: HMG-API's car map + wireless mod gave a working hotspot + wireless CarPlay on this
  car; the stock firmware has no Wi-Fi client menu.
- Car-verified: wireless CarPlay music, Siri and calls/mic; built-in Wi-Fi STA (as `wifi-client`, now `wifi`; adb over a router);
  user-button shortcut; boot reconcile and readiness status; 324/324 original map points reflect
  (2026-11-03). Owner-verified 2026-11-07: wireless Android Auto, cluster/HUD lane rendering, and
  the user-button shortcut kept after a restart.

## Hard rules

- **Android 4.4 only:** API 19, Java 1.7, framework views, no AndroidX/Kotlin/Compose/Material.
  Compile against `platforms/android-19`. APK v1 (JAR) SHA1withRSA signing.
- **Head-unit shell = toolbox + mksh.** No `printf`, `awk`, `sed`, `tail`, `head`, `cut`, `tr`, `wc`, `sort`,
  `find`, `stat`, `sha256sum`, `tar`, `unzip`, `busybox`. Hashing on the unit: toolbox `md5`
  (`<hex>  <path>`; filenames required, explicit `/proc/self/fd/0` for a pipe).
  The pinned AOSP `android-4.4.2_r1` profile is `tools/android44-shell-profile.json`.
  `make test` runs `tools/lint-android44-shell.py` on source and packaged scripts,
  checking commands, absolute binary paths, options and supported shell syntax.
  Edge cases need `# android44-shell: allow -- <specific reason>` inline; all are reported.
  Toolbox `mv` accepts no options. Full evidence: `.agents/android44-shell-audit.md`.
- **Modules never mutate the system directly.** All writes go through the package API in
  `nemesis/package/lib/common.sh` (`sg_prop_set`, `sg_file_put`, `sg_file_replace_line`,
  `sg_file_delete`, `sg_bind_mount`, `sg_service_restart`, `sg_zygote_install`, `sg_hook_register`,
  `sg_dex_cache_track`, `sg_revert_all`), which validates ownership (`module.properties`
  `owns_props`/`owns_files`/`owns_lines.N`/`services`), baselines, writes, verifies and appends to the ledger.
  `sg_service_call` accepts only exact `service_calls=` pairs, times out, and records every call.
  Module scripts may only read. Need a new kind of write? Add an API function to the runtime and
  the contract; never work around it in a module.
- **Text files may be shared between modules only at line level:** declare each changed stock
  line in `owns_lines`; two modules may never own the same line; whole-file operations
  (`sg_file_put`, `sg_file_delete`, zygote install, bind mounts) require exclusive `owns_files`
  ownership; the build and the runtime both enforce this. `excludes` is for functional conflicts
  (e.g. one Wi-Fi radio), not for file sharing.
- **Exact restore on uninstall is the top priority.** Restores are guarded: only undo bytes/values
  we wrote; if the target changed since (e.g. an official firmware update), report conflict, keep
  backups and fail the uninstall closed. Baselines are bound to `ro.build.product`.
  The owner-approved `restore=reboot` class is only for a module with no persistent stock
  file/property writes: disabling stops future calls; stock behavior returns after a head-unit
  restart, and status remains pending until that restart.
- **Root channel:** the app is unprivileged and calls only fixed `hmg-seogaemo-root <id> <verb>`
  or `hmg-seogaemo-root map status|run|verify|export` commands with
  fixed, validated arguments. NEMESIS root is reachable by any UID; never add a verb that takes
  free-form shell or paths.
- **No key material in git.** Only `keys/ota-manifest-public.pem` is committed. Release secrets live
  in the GitHub environment `release` (tags `v*`); owners keep a local backup.
- **Licensing:** the repository is GNU AGPL-3.0 (`LICENSE`, `NOTICE.md`).
  `modules/wireless-carplay-and-aa` contains AGPL-3.0 code adapted from HMG-API; keep original
  headers and mark modified files. The core mapper, verifier, host mapper, and catalogue are
  our own implementation. Do not copy upstream source into them. Keep stable hookpoint IDs and
  provenance in `UPSTREAM.md`; run `tools/upstream-diff.sh` before translating upstream changes.
- Commit messages: plain, no AI attribution / `Co-Authored-By` trailers.
- **Confirm before anything non-trivial (car touch screens are easy to mis-tap).** Every action that
  changes files/properties/state on the unit or the app's persistent settings, or that starts work
  that does not finish instantly (module on/off, language change, export, update check/download/
  install/rollback, head-unit restart, any root call that writes), must first show a confirmation
  via the shared `ui.ConfirmDialog` helper (large, NEMESIS-scale buttons; Cancel is the default /
  left button; destructive actions styled with the error color). Pure navigation and read-only
  views need no confirm. Never call such an action directly from a tap handler.
- **Never translate or transliterate proper nouns** in UI strings or docs, in any locale: keep
  `HMG-Seogaemo`, `NEMESIS`, `CarPlay`, `Android Auto`, `Wi-Fi`, `ADB`, `USB`, `GitHub`, `HMG-API`,
  `Hyundai`/`Kia`/`Genesis`, `Gen5W`, model/firmware ids as written (e.g. KO: "무선 CarPlay",
  not "무선 카플레이"; "HMG-Seogaemo 버전", not "새개모 버전"). Translate only the surrounding words.

## Layout

| Path | What |
|---|---|
| `app/` | APK `com.seogaemo.hmg`: `ui/` (Features/Car/Settings tab screens: `FeaturesView`, `FeatureCard`, `LineIcon`, `OptionsList`, `ConfirmDialog`, `StepProgressDialog`, `Theme`; `ui/settings` page components), `module/` (registry, `ModuleManager`, `RootClient`, contract types), `core/update/` (OTA) |
| `modules/<id>/` | one module = one dir in package form, shipped as `bundled/<id>.hsm`: `module.properties` (`api=1`, `raw_shell=1`), `module.sh`, `strings/{en,ko}.txt`, `ui.txt`, `files/` (payload); repository-only `build/build.sh`, `payload/` (sources), `test/run.sh` |
| `nemesis/package/` | NEMESIS package `hmg-seogaemo`: `NEMESIS.data`, `bin/` (`hmg-seogaemo-root`, `open.sh`, `install-apk.sh`), `lib/common.sh`, `core/update.sh`, `scripts/` (stable hook wrappers), `svc/reconcile.sh` (boot-only), `svc/watcher.sh` (boot/screen_on watch dispatch, never apply/revert) |
| `nemesis/usb/` | USB wrapper descriptor (`packages/hmg-seogaemo.zip`) |
| `tools/` | module generator, packager, root-script lint, tests, `testlib/fakebin` (toolbox shims) |
| `core/hookpoints/`, `core/map/`, `maps/` | full hookpoint catalogue, standalone API 19 mapper, bundled verified map data |
| `keys/` | OTA manifest public key only |
| `.agents/` | design, contracts, research, per-module notes |

Every module ships as a bundled `.hsm` package, installed on first install and removable; there are no
built-in modules. The package's `modules.list`/`modules.graph` hold only the `package-compat` entry so
installs from 0.1.33 and older accept an OTA payload; the runtime ignores it. Current modules: `wifi` (formerly `wifi-client`; one role per radio, built-in or USB
adapter; the built-in client role excludes `wireless-carplay-and-aa`),
`wireless-adb` (independent; offers "Connect to another Wi-Fi"), `wireless-carplay-and-aa`,
`skip-consent-screen` (factory Binder call on boot and screen wake), and
`user-button` (both star buttons; merged from `user-button-shortcut` / `user-button-head-unit` with `replaces=`).
`wireless-carplay-and-aa` claims `featurexml.cfg` stock lines; `wifi` owns only
`android.hardware.wifi.xml` and `persist.wifi.state` (the NEEV KOR `featurexml.cfg` has no Wi-Fi
removal line, verified on the car) plus transient USB adapter effects. Their exclusion is for STA versus AP on one radio.
Device state lives under `/data/nemesis/backup/hmg-seogaemo/` (desired state, baselines, ledger).

## Car mapping

- The core owns mapping; modules declare stable IDs in `hookpoints.required`. The build validates
  those manifests against the full catalogue. The bundled NEEV KOR map has 356 of 357 points;
  `themesettings.split_item.type` remains unresolved and no module requires it.
- `map status` is read-only and matches the exact product, onebin, Android release, and MD5 of every
  stock file in `car.json`. Known maps get reflection verification once per boot on a worker.
  Unknown firmware requires the confirmed **Map this car** action in Settings → Car mapping.
  `map run` scans the full catalogue in a separate root `app_process`; it publishes only verified
  points through the package API and ledger. Modules stay off unless all their required IDs pass.
- Car gate: every module reports `incompatible` until a bundled or published map exists for the exact
  `ro.build.product` (`sg_car_map`, cheap, no map tool). Per-firmware facts come from that map's
  `car.json`, `ro.mobis.onebindir` (`@onebin@` in `owns_lines` paths) or product-scoped
  `stock_file.N=<glob>:<path>:<md5>`; never write a product check into a module script.
- `map export` and ordinary USB/adb ledger export include a PR-ready `maps/...` folder. Owners send it
  through the `new-firmware-map.yml` issue form, opened from the app's QR code (only firmware ids,
  versions and map/module states; never personal data); maintainers turn it into a PR. A scan that
  fails a required point publishes nothing; `map export` then exports the kept incomplete candidate
  (`incomplete.txt`, per-point reasons in `car.json`) for diagnosis only. See
  `docs/mapping-new-firmware.md` for adb, host baksmali mapping, comparison, and PR steps.

## Build, test, release

- `make` builds `out/hmg-seogaemo.apk`; `make test` builds the package, then `tools/run-tests.py`
  runs generator, package, runtime, update, lint, Java and every `modules/*/test/run.sh` in one
  CPU-sized pool (tests put `tools/testlib/fakebin` first on PATH; root/module suites run on
  `mksh`, /bin/sh only a smoke set; `HMG_SEOGAEMO_TEST_SHELLS=all` runs both fully;
  `TESTS_ONLY=word,...` selects tasks; `make test-suites` skips the rebuild); `make package` writes `out/dist/` (`hmg-seogaemo-<v>-nemesis-package.zip`,
  `-nemesis-usb.zip`, `-ota.zip`, `.apk`, `SHA256SUMS`, plus signed manifest when
  `OTA_MANIFEST_PRIVATE_KEY` is set); `make verify-dist`; `make clean`.
- Local builds are signed with a throwaway debug key. **Install only release-signed builds on a
  car you want to update OTA later**: a signer change forces uninstall and loses app data.
- Requirements: JDK 17, Android SDK (`platforms;android-19`, `build-tools;34.0.0`), python3,
  clang + lld (carplay native payload), optional `mksh`.
- CI (`ci.yml`) and release share `.github/actions/setup`: the runner's preinstalled SDK plus a
  cached API 19 platform and mksh .deb, LLVM 18 from the image; `android-actions/setup-android@v3`
  breaks on the removed `tools` package.
- Branches: `main` ships finals, the long-lived `beta` ships betas. Cut feature branches from `main`;
  merge them (`--no-ff`) into `beta` to ship as a beta, into `main` for a final. Never merge `beta`
  into `main` and never cut a feature branch from `beta`: `PRERELEASE` exists only on `beta`, and CI
  on `main` (push and PR) fails if it is present. `beta` is not deleted or reset.
- Version files: `VERSION` is `X.Y.Z`, the only edited version. Final: `VERSION` alone, tag `vX.Y.Z`.
  Beta: `VERSION` holds the coming release and `PRERELEASE` holds `beta.N`, tag `vX.Y.Z-beta.N`
  (`tools/version.py --label`). The APK shows `X.Y.Z-beta.N` (same versionCode), the package carries
  `PRERELEASE`, and the release is a GitHub prerelease that in-app OTA (`releases/latest`) never
  offers; install it by hand. The `X.Y.Z` final replaces it over OTA (a beta is older than its release).
- Release order (always): merge everything first; for a final bump `VERSION` in its own commit on
  `main` (beta's version moves automatically, see below); push the branch, wait until CI on that
  exact commit is green (CI runs on pushes and PRs to `main` and `beta`), then tag that commit and
  push only the tag. Never tag a
  commit CI has not run on (e.g. a local merge commit) and never move or reuse a pushed tag; a failed
  release gets the next number (patch for a final, `beta.N+1` for a beta).
- Release workflow: `release.yml` refuses a beta tag whose commit is not contained in `origin/beta` and
  a final tag whose commit is not contained in `origin/main`. It builds with the release keystore,
  checks the APK certificate SHA-256, signs the manifest, waits for CI on the tagged SHA (success:
  `make test-dist` on the release build; otherwise the full suite via `make test-suites`), uploads
  to a draft release, verifies the asset list, then publishes. Tag a commit CI tested to get the
  short path (commits pushed by the bump below start no CI, so tag after a merge or push that ran it).
- Automatic beta bumps (`beta-sync.yml`, `tools/beta-bump.py`; runs after `Release` succeeds, pushes
  `beta` with `GITHUB_TOKEN`, never tags): after a final `vX.Y.Z` it merges that tag commit into
  `beta` ("Merge vX.Y.Z into beta"; creates `beta` from it when missing) and commits
  `beta: X.Y.(Z+1)-beta.1` (`VERSION` X.Y.(Z+1), `PRERELEASE` beta.1; a `beta` already ahead keeps
  its `VERSION`). After a beta `vX.Y.Z-beta.N` it commits `beta: X.Y.Z-beta.(N+1)`, only while `beta`
  is still at `X.Y.Z` / `beta.N`. A merge conflict (only `VERSION`/`PRERELEASE` auto-resolve) pushes
  nothing, fails the job and opens an issue: merge the final into `beta` by hand and set the next
  `VERSION`/`PRERELEASE` in a separate commit. Re-runs change nothing.
- UI screenshots: AVD `hmg_1920x720` (1920x720, 240 dpi, API 28 image; no NEMESIS, so module
  status shows unavailable). README screenshots are the Korean UI.
- README: every image is a real app screenshot from `assets/`; no "mock", "demo", "example",
  "emulator" or similar disclaimers/captions anywhere in README. Plain screen titles only, and
  captures must not show error states (render unreachable status neutrally).

## On-car operations

- Settings → General offers **Restore stock state** (KO **순정 상태로 되돌리기**)
  and **Uninstall HMG-Seogaemo**, both confirmed with progress and per-module
  results. Fixed root commands are `hmg-seogaemo-root stock restore|status` and
  `hmg-seogaemo-root package uninstall`. Restore keeps the app installed; uninstall
  restores first, then queues NEMESIS removal without force. Cancel changes nothing.
  On failure automatic module calls remain paused, backups stay available, and
  failed/unvisited desired states remain unchanged. A successful explicit module
  apply resumes dispatch. Restart when requested to complete transient restoration.
- Before car approval, verify exact property/backing-file and file restoration,
  bind/dex cleanup, no further watcher calls after wake/reboot, conflict retention,
  and ledger export. Then verify app-initiated NEMESIS removal survives the caller
  closing, removes both package and APK, and retains uninstall result/logs under
  `/data/nemesis/backup/hmg-seogaemo/uninstall/`. Detailed checklist:
  `.agents/stock-restore.md`. These paths have only been tested off-car.

- First install: release `hmg-seogaemo-<v>-nemesis-usb.zip` unzipped to an empty FAT32/exFAT stick.
- Full root over adb: `adb shell cp /system/xbin/nemesis /data/local/tmp/nemesis-d` then
  `adb shell /data/local/tmp/nemesis-d root -c '<cmd>'` (plain `nemesis root -c` from adb is a weak
  root). Export the change ledger:
  `adb shell /data/local/tmp/nemesis-d root -c '/data/nemesis/apps/hmg-seogaemo/bin/hmg-seogaemo-root export adb'`
  then `adb pull /data/local/tmp/hmg-seogaemo-export/`. The app's Logs page exports to USB.
- Test modules one at a time, lowest risk first (`wireless-adb` → `wifi` →
  `wireless-carplay-and-aa`), keep adb reachable, export the ledger before and after, and verify
  revert restores the exact originals before moving on.

## Known gaps / risks (unverified on a car)

- The 18 v1.0.1, six stock-guidance and eight CarPlay owner map additions have exact-stock host
  evidence and still need on-car reflection.
- Cars other than the Ioniq 5 KOR: the generic install, car gate and `@onebin@` path are tested off-car
  only. CarPlay's stock `app_process` MD5 is known only for `NEEV.KOR.*.260902`; elsewhere that
  unrecorded-swap check has no reference build. korea-projection reports wireless CarPlay on 13 other
  Korean cars with the same upstream recipes, but with the stock hotspot call a no-op on several of them
  (it starts `hostapd` directly, 5 GHz channel 149); that hotspot start is not implemented here.
  Other feature claims require their own evidence.
- The core hook host replaces `/system/bin/app_process` for every hook module, `wireless-carplay-and-aa`
  included (boot guard disables it after 3 quick restarts). Keep an adb recovery path ready. CarPlay on the
  host, the migration from its old self-installed wrapper and turning CarPlay off on the host (exact
  stock restore) are car-verified; stock restore releasing the host and the boot guard are not yet.
- `wifi` built-in STA vs the CarPlay AP on one radio: treated as mutually exclusive; concurrency is
  unknown. The USB adapter roles and the wifi-client takeover are unverified on a car. `wifi` (built-in client) sets `persist.wifi.state=3` with the feature XML; no NEEV KOR system file
  names that property, and stock `HKMC_WifiSettings` gates its client menu on `android.hardware.wifi`.
- OTA: TLS 1.2 to GitHub on 4.4 with bundled roots (`update_roots.pem`), the reboot/resume flow
  through `wifi`, and rollback are untested on a car.
- An official firmware OTA while modules are applied makes restores conflict by design.
- Removing only the APK (not via NEMESIS) skips the uninstall hook; reconcile must clean up.

## Working conventions

- Parallel work: one Paseo/git worktree per area; ownership is in the contract's ownership table.
  Shared files (`MainActivity`, `hmg-seogaemo-root`, `lib/common.sh`, `Makefile`,
  `tools/test-*.py`) belong to the runtime owner; others list needed hunks instead of editing.
- One commit per logical change; each commit builds and passes `make test` on its own. Do not
  bundle unrelated fixes into one commit.
- Merge feature branches into `main` with `--no-ff`; keep worktrees after merging.
- Docs agents read hold only the current state: when something is verified or changes, rewrite the
  line in place; move history to `.agents/archive/` (not read unless asked) or delete it.
- Interface changes go into `.agents/module-runtime-contract.md` first, then code.

## Module manifest template guidance

For a new module, copy the metadata shape from an existing module and declare
only the operations it performs. Use `owns_files=/absolute/path,...` for exclusive
whole-file operations. For a shared text file, add one numbered entry per changed
stock line, for example:

```properties
owns_lines.1=/system/onebin/@onebin@/featurexml.cfg:-/system/etc/permissions/com.hkmc.software.wifihotspot.xml
```

`@onebin@` is replaced with `ro.mobis.onebindir` when the module is installed.

Numbers are unique positive decimals without leading zero. The first colon
separates the path from the exact stock line; everything after it is literal,
including commas, colons, equals signs, backslashes and spaces (no escaping).
Control characters are forbidden. Do not also list that path in `owns_files`.
Pass this exact stock line to `sg_file_replace_line`, including on reapply.
See `.agents/module-runtime-contract.md` for composition and recovery semantics.
