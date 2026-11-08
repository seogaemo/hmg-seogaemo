Status: current — display tokens, touch measurements, API 19 constraints and the single-panel decision.

# Gen5W UI guidelines

Target one panel: 1920×720 px, hdpi (Android 28 AVD uses 240 dpi = 1280×480 dp), landscape. Framework Java views, API 19 methods only. `dp()` applies display density only; no HMG-API `K = 0.66` scale.

## Single-panel decision

Upstream (NEMESIS, HMG-API, HMG-Leafia-Plus; reference car 2023 Kia EV6 US, fw 260507) all assume the wide 1920×720 @ 1.5 panel. None handles 12.3", 8", 1280px-class or dual-screen layouts; variant detection keys on firmware (`ro.build.product`, stock hashes), never on panel size (`HMG-API/core/runtime/java/hmgapi/engine/SystemCheck.java:15`). Multi-size support is out of scope here:

- Framework dp conversion, no `K` factor; NEMESIS-scale touch targets.
- Android Auto density stays stock (no `aa_density` module).
- Upstream gaps that matter only if another panel is added (inference, unverified on a car): NEMESIS fixed 4×2 tiles may clip; HMG-API fixed columns/QR/px-sized panel header may not fit; `aa_density` is one value per unit; HMG-API's car test plan has no acceptance criteria for other sizes (`HMG-API/docs/car-test.md:189`); no multi-size plan in upstream docs, wiki, changelogs or git history.

Upstream evidence (paths under `tmp/`):

| Topic | Evidence |
| --- | --- |
| HMG-API app scale | fixed `K = 0.66f`, no size check (`HMG-API/core/app/java/hmgapi/app/Ui.java:187`); fixed columns 460/360, QR 380 (`ModsTab.java:60`, `SettingsTab.java:39`, `ReportTab.java:49`); side panel fills stock slot but header uses literal px (`hook/Panel.java:33,217,222`) |
| HMG-API AA density | stock 240 on wide screens (`docs/mod-reference.md:203`); `projection.aa_density` (60–480) rewrites both density args, width/height stay stock (`docs/mod-reference.md:192`, `hook/ProjectionHooks.java:74`); car test saw 200 DPI at every resolution (`docs/car-test.md:306`) |
| NEMESIS Manager | `DisplayMetrics` dp conversion, no panel resolution (`hmg_nemesis/Sources/manager/src/com/nemesis/manager/Ui.java:94`); home 1/3 list + 2/3 pager (`res/layout/activity_main.xml:16`, `IconPager.java:53`); fixed 4×2 grid, 204×166dp tiles from stock Setup hdpi (`MainActivity.java:35,201,244`); popup 46% width, max 640dp (`DialogActivity.java:95`) |
| Leafia / HMG-API wireless mods | only feature flags/files; no width, height or DPI change, no CarPlay resolution override (`HMG-Leafia-Plus/README.md:31`, `packages/wireless-carplay-aa/comp/1_projection/scripts/common.sh:518`; `HMG-API/mods/wireless-carplay-aa/mod.json:53`, `patches.json:11`) |
| Cluster/HUD TBT | via `NavigationCluster` service, size-independent (`HMG-API/core/runtime/java/hmgapi/hook/Cluster.java:9,33`; `HMG-Leafia-Plus/packages/wireless-carplay-aa/scripts/common.sh:96`) |
| Variant detection | NEMESIS `ro.build.product` + `ro.mobis.targetdir` (`hmg_nemesis/Sources/native/pkg.c:310`; wireless package edits every `/system/onebin/*/featurexml.cfg`, `packages/wireless-projection/scripts/common.sh:320`); Leafia by product prefix + hashes (`packages/wireless-carplay-aa/scripts/cars.sh:8`); HMG-API car/firmware maps (`engine/SystemCheck.java:76`, `engine/CarMap.java:70`) |

## Dark design tokens

| DESIGN.md token | Car UI mapping |
| --- | --- |
| `colors.ink` / `colors.primary` `#171717` | Main dark surface `#171717` over near-black canvas `#111111` |
| `colors.on-primary` `#ffffff` | Light primary text `#f5f5f5` |
| `colors.body` / `colors.mute` | Secondary text `#9a9a9a` |
| `colors.hairline` | Dark 1dp divider and border `#343434` |
| `colors.link` `#0070f3` | Selected sidebar, enabled toggle, primary action |
| `colors.error` `#ee0000` | Destructive Restart head unit tile only |
| `rounded.sm` / `rounded.md` | 6dp buttons and 8dp tiles |
| `typography.display-*` / `caption-mono` | Medium sans headings and localized labels at natural width; mono only for technical identifiers and numbers |

Fonts: only `sans-serif`, `sans-serif-medium`, `monospace`; none bundled. No `TextView.setLetterSpacing()` (API 21). No text compression on Home/Settings labels. Hairline borders give depth, no heavy shadows.

## NEMESIS measurements

Paths relative to repo root; dp unless marked sp.

| Element | NEMESIS reference | Current UI |
| --- | --- | --- |
| Header | 60dp; `tmp/hmg_nemesis/Sources/manager/res/layout/title_bar.xml:5` | 60dp |
| Header button | 72×60dp; `title_bar.xml:47` | 132×60dp Home back / 72×60dp close |
| Header text | 28sp; `res/values/styles.xml:18` | 28sp |
| List row | min 70dp; `res/layout/list_row.xml:5`; 26sp/22sp at `:15`, `:21` | 70dp sidebar, 75dp content rows; 23–24sp titles |
| Tile grid | 4×2; `src/com/nemesis/manager/MainActivity.java:35-36` | Six portrait cards per Home page |
| Tile | 204×166dp; `MainActivity.java:244-286` | ~174dp wide portrait card |
| Tile icon / label | 66dp icon, 25sp label; `MainActivity.java:264-280` | 66dp monogram, 21–24sp labels |
| Bottom bar / buttons | 60dp, 21sp; `res/layout/activity_list.xml:40-61` | 60dp buttons, 21sp |
| Density conversion | plain `TypedValue.applyDimension()`; `Ui.java:94-97` | same |

## Screens

- Home: horizontal `HorizontalScrollView` pager, six portrait tiles per page, swipe + arrow buttons + page dots when more than one page. Settings tile first; runtime tiles from `Module.homeTiles()` while enabled or `alwaysVisible` (current modules supply none). Viewport ~1104dp, card ~174dp; page widths are synced after layout so recreation after a language change keeps them. Only Settings navigates.
- Settings: category taps switch the pane; module toggles run through `ModuleManager` and the root dispatcher; Logs exports the ledger to USB. Sidebar sections use short non-focusable sans labels (App / 앱, Module settings / 모듈 설정); module pages are separated from core categories by a full-width hairline and 24dp top gap; rows stay 70dp with the blue selected marker; sidebar scrolls.
- General → Language persists `system`/`en`/`ko` in SharedPreferences, sets `Configuration.locale` via `Resources.updateConfiguration()` before rebuilding views, recreates the Activity. Strings: `app/res/values/strings.xml`, `values-ko/strings.xml`.
- Logo (header, launcher): proportions from `tmp/brand/logo-source.png`, two `#101016` squares on white, no VectorDrawable.
- Car mapping: core category after General; status/product/source/count rows use 75dp row geometry; 60dp Map this car and Export map actions use `ConfirmDialog` and a background `RootClient.map` call. App starts a read-only status check on launch and verifies a matching map once per boot on a worker. Without NEMESIS the page shows a neutral unavailable state. A successful mapping result directs the owner to export the `maps/...` folder; Export map offers two choice cards like Support → Report a problem: GitHub issue (default; exports the folder, then shows a read-only QR code that opens the prefilled `new-firmware-map.yml` GitHub issue form; `core/IssueLink`, `ui/QrCode`) or USB only. Support → Report a problem has three cards (Export now, Export as a GitHub issue, Keep recording); the issue card exports to USB when possible, reads `report digest`, then shows the QR for `bug-car-support.yml` with readable firmware/map/module fields and a packed log (app state, recent app errors, root digest) cut to fit a 990-byte link (QR version 25 at 3 px per module). The QR carries only `ro.build.product`, onebin, Android release, app version and map/module states; files are attached from the phone or a computer.

### Settings geometry

Rules (checked in Korean at 1920×720), implemented in `SettingsUi`:

- 8/12/16/24/32dp spacing scale; cards 8dp, controls 6dp; touch targets at least 48dp.
- Status pills 144×54dp, 16dp inner horizontal padding, 16dp gap after card copy; width fits `Unavailable` (EN) and the KO strings.
- Status lines are localized human messages; unknown details go to logcat under `HMG-Seogaemo`, never the visible line. Wrapped notes grow with content.
- Baseline captures `tmp/ui-audit/before/`, final `tmp/ui-audit/after/`; the seven README images in `assets/` come from the same final build.

## Confirm before action

Rule and scope are in AGENTS.md. Implementation: `com.seogaemo.hmg.ui.ConfirmDialog.show(...)`.

- Module toggles and `ENABLE_MODULE` use `ModuleManager.plan` and read-only `precheck` first; the dialog lists every planned enable/disable step and active warning.
- Direct (no dialog): `OPEN_STOCK_WIFI_SETTINGS` and navigation (no HMG-Seogaemo state change). A previously confirmed OTA resume or restoration may continue after an Activity restart.
- Look: dark surface + hairline tokens, 8/12/16/24/32dp spacing, 60dp buttons, dimmed background. Cancel is left and initially focused; outside taps do not dismiss, Back/Cancel do. Destructive actions use the error color. The confirm button disables immediately on submit; long work calls `showProgress()` and dismisses on finish. EN/KO text in resources, proper nouns unchanged.

## API 19 compatibility

- Build: `platforms/android-19/android.jar`; `aapt` links against it, `javac -source 1.7 -target 1.7 -bootclasspath`, `d8 --min-api 19 --lib` (`tmp/hmg_nemesis/Sources/manager/Makefile:24-36`). Compile and dex in one recipe to avoid a stale dex.
- Signing: SHA1withRSA/SHA1 v1 JAR, then zipalign, with the JDK algorithm override (`app/allow-sha1.security:1-2`). Check: `apksigner verify --verbose --min-sdk-version 19 out/hmg-seogaemo.apk`.
- Manifest: `minSdkVersion=19`, `targetSdkVersion=19`, `GET_TASKS`, `allowBackup=false`, `singleTask`, style inheriting `Theme.NoTitleBar.Fullscreen` (`tmp/hmg_nemesis/Sources/manager/AndroidManifest.xml:6-23`; `res/values/styles.xml:3-6`). Close button catches `SecurityException` from `finish()` and falls back to `moveTaskToBack(true)` (NEMESIS `Ui.java:23-35`).
- Forbidden: AndroidX, Compose, `VectorDrawable`, ripple, `setLetterSpacing`, any API above 19.
- Package name, launcher category and fixed landscape serve the standalone app; NEMESIS hooks live in `nemesis/package/`. Network permission is for GitHub Releases updates. Background `#111111` inside NEMESIS's fullscreen theme parent.
- `<meta-data android:name="android.max_aspect" android:value="2.7" />` avoids Android 28 emulator letterboxing at 1920×720; Android 4.4 ignores it.
- Verified: API 19 resource linking and Java compilation; APK installs on Android 28. Not verified: physical Gen5W, any Android 19 runtime.

## Screenshots

AVD and README rules are in AGENTS.md. PNGs come from the Android 28 arm64 AVD at 1920×720/240 dpi (no API 19 image or car). Sidebar order: General, Modules, Logs, About, then module pages; inspect the layout before scripting taps. Capture with `adb exec-out screencap -p`.

## One-shot module cards

A `kind=action` module's card shows no state label: the status row is the module's own `action_label` text in the accent
colour, and the detail panel's primary button carries the same text. Both ask for confirmation first.
