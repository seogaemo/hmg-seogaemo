Status: **current**. Normative for installable module packages, API 1. Sections marked
*Design (not implemented)* are proposal only. Reuses the package API, ledger, guarded restore and boot
reconcile of `module-runtime-contract.md`.

# Installable modules

## Goal and constraint

- Non-developers install, remove and use modules from the head unit without a laptop. Developers (including
  people working with an AI assistant) write, test and ship a module without rebuilding the app. Exact stock
  restore stays top priority: an installed module gets no write path the runtime cannot record and undo.
- Built-in modules are compiled into the APK: `tools/gen-modules.sh` generates the registry from
  `modules/*/module.properties`, each module's UI is a Java class implementing `module/Module.java`, strings
  are Android resources. Adding/removing one needs an APK build, release and reinstall. Owner chose
  runtime-installable modules; the registry platform is deferred and modularization comes first.
- No JSON: the head unit has only toolbox and mksh, so every file is key=value or a script the root side reads
  directly; nothing is compiled on the host.

## Implementation state

Implemented: root runtime (P1: `lib/hsm.sh`, `core/hsm-module.sh`, `core/module.sh`, `core/hsm/`), app data
layer (P2), `tools/hsm` (P5), core hook host (P3, host-tested only, see Core hook host), module screens and
USB install UX (P6, see `ui-redesign.md`; on-car check pending).
Bundled (P4): every module ships as a bundled package: `skip-consent-screen`, `user-button-head-unit`,
`user-button-shortcut`, `wireless-adb`, `wifi` (formerly `wifi-client`), `wireless-carplay-and-aa` (raw_shell, see Bundled modules);
there are no built-in modules. Not implemented: `hsm test`, `hsm logs`, the registry/store. `raw_shell` and `app_data_dir` are still refused.

## Bundled modules (P4, owner decision 2026-11-06)

Built-in modules become `.hsm` packages that ship inside the NEMESIS package and are installed
automatically (option A: pre-installed, removable). Converted one at a time; a converted module has no Java
class, no Android resources and no `modules.list` entry.

- Source: `modules/<id>/` holds the package members directly (`module.properties` with `api=1`,
  `strings/`, optional `ui.txt`, `files/`, and either `apply.sh` or, with `raw_shell=1`, `module.sh`), plus
  `test/run.sh`. `gen-modules.sh` skips directories whose `module.properties` has `api=`. The build packs each
  into `bundled/<id>.hsm` plus its SHA-256 in `bundled/<id>.sha256` (the extractor verifies the archive
  against it) in the NEMESIS package and OTA; `version=@VERSION@` becomes the package version.
- `raw_shell=1` is accepted only for bundled packages. Such a module ships `module.sh` (the former
  `root/<id>.sh`, same verbs `status|precheck|apply|revert|watch`) and declares its touched list with the
  existing keys (`owns_props`, `owns_files`, `owns_lines.N`, `services`, `service_calls`, `reassert_props`,
  `owns_generated_dirs`, `restore`); the runtime enforces them exactly as for built-ins. `apply.sh` is then
  not required. The dispatcher runs `installed/<id>/module.sh` for such a manifest (`source=bundled`,
  `raw_shell=1`).
- Install: `svc/reconcile.sh` runs `module.sh install-bundled` (no arguments; only the package's own
  `bundled/*.hsm`) after Android is ready and before modules are reverted or applied; `scripts/postinstall.sh`
  also runs it right after the APK step when Android is ready, so a USB install shows them without a restart. A bundled module is
  installed when it is not installed and not removed by the owner (`<data>/bundled-removed/<id>`). Same
  version: nothing. Other version: replaced in place, even while on, only when the generated ownership keys
  are identical; otherwise the old copy stays and the reason is logged. The state directory, desired state
  and settings are keyed by ID, so a module that was on as a built-in stays on after conversion.
- `wifi` (formerly `wifi-client`, taken over with `replaces=wifi-client`, see the runtime contract) has no static
  exclusion: its built-in client role excludes wireless CarPlay through `setting-ok`/apply and the app planner
  ([wifi.md](wifi.md)). Foreign cleanup recognises the HMG-API Wi-Fi XML by its MD5, so it works after `wifi` is
  removed.
- IDs of bundled packages are reserved: a direct install with such an ID is refused. Removing a bundled
  module (normal `module remove`) records `bundled-removed/<id>`; the marker survives a package uninstall and
  reinstall (the data root stays). The app's Add screen lists removed bundled modules next to USB packages:
  `module list-removed <xx>` (read-only; `info.removed_N=<id>,<version>,<icon>` plus `_name`/`_summary` from the
  `bundled/<id>.strings.<locale>` files the packer writes beside each `.hsm`) and `module add-bundled <id>`
  (confirmed in the app; needs `bundled/<id>.hsm` and the marker; drops the marker and installs only that package,
  the marker returns if the install fails; a `replaces=` module whose predecessors were all removed installs
  anyway because the owner asked for it). Adding does not turn the module on.
- `module list` reports `bundled` as the source; the app treats it like an installed package.
- All six former built-ins (`raw_shell=1` with their former root scripts). The user-button broadcast receiver is
  app code (`com.seogaemo.hmg.UserButtonReceiver`), not module code. A bundled raw_shell package may declare
  `hooks=1` (CarPlay): it registers with the core hook host through `sg_hook_register`.
- The packer (`tools/package.py`) packs only `.hsm` members (`module.properties`, scripts, `ui.txt`,
  `README.md`, `strings/*`, `files/*`); sources, build scripts and tests stay in the repository. Bundled
  modules' declared `module.properties` is also copied to the package's `modules/<id>.properties` (the
  module's own manifest is resolved there first); the generated one is under `installed/`. Shared-line and
  whole-file ownership checks read every module's manifest: the package copy, else the one under
  `installed/` (user-added `.hsm`).
- Compatibility entry: `modules.list`/`modules.graph` hold only `package-compat` (stub `modules/package-compat.sh`,
  `exit 2`). Installs from 0.1.33 and older check an OTA payload with their own `lib/payload.sh`, which needs at
  least one listed module with a script; the runtime never treats `package-compat` as a module
  (`sg_module_list`, reconcile). New checks accept empty lists.

## Package

`<id>-<version>.hsm` is a zip with these members only (no directories other than `strings/` and `files/`,
no symlinks, no absolute or `..` paths, at most 256 entries and 16 MiB uncompressed):

| Member | Required | Content |
| --- | --- | --- |
| `module.properties` | yes | key=value, keys below |
| `apply.sh` | yes | restricted script |
| `check.sh` | no | restricted script, pre-enable checks (block or warn) |
| `status.sh` | no | restricted script, extra status |
| `ui.txt` | no | screen blocks |
| `strings/en.txt` | yes | `key=value` display strings; `name` and `summary` required |
| `strings/<locale>.txt` | no | same keys; missing keys fall back to `en` |
| `files/...` | no | payload referenced by `put_file`, `put_files`, `hook_apps` |
| `README.md` | no | plain-language description, shown in the review screen |

The head unit has no `unzip`. Root extracts with a packaged API 19 Java helper run under `app_process`, with
`sg_bounded_wait` (60 s) and a private `ANDROID_DATA` (same rules as the mapper). The helper enforces the
limits and writes only into the staging extraction directory.

## module.properties keys

| Key | Form | Rule | Maps to (internal key) |
| --- | --- | --- | --- |
| `id` | `[a-z0-9][a-z0-9-]{1,47}` | unique; built-in IDs reserved | |
| `version` | `N.N.N` | | |
| `api` | `1` | unknown API refuses install; later versions only add verbs and blocks, existing meanings never change | |
| `cars` | csv of `ro.build.product` globs | at least one must match at install and apply | product checks in scripts |
| `restart` | `none`, `adbd`, `head_unit` | maximum restart this module can request | `restart` |
| `rerun_on` | csv of `boot`, `screen_on` | re-run `apply.sh` in reassert mode (Lifecycle) | `watch` |
| `depends` | csv of module IDs | enabled first in the same confirmed plan | `depends` |
| `uses` | csv of `<resource>[:<mode>]` | see Conflicts | `excludes` (mostly) |
| `not_with` | csv of module IDs | rare: a specific module that cannot be on together | `excludes` |
| `conflicts` | csv of external owner names | external tools that already own the feature; same names as `sg_owner_present` | `conflicts` |
| `stock_file.N` | `<path>:<md5>` | stock MD5 required before apply | `known_stock.N` with this module's `cars` |
| `hookpoints` | member name of a text file of stable IDs | | `hookpoints.required` |
| `setting.N` | `key:type:default` | types `toggle`, `choice(a\|b\|...)`, `number(min..max)` | `Module.settings()` |
| `raw_shell` | `1` | see Restricted scripts | |
| `replaces` | module ID list | bundled packages only: take over one renamed bundled module's state, or merge several into this one (runtime contract, "Settings check and module takeover") | |
| `replaces_setting.<old>` | `key:value` | bundled packages only: when the replaced module `<old>` was on, the takeover sets this module's setting `key` to `value` | |
| `kind` | `toggle` (default) or `action` | `action`: one-shot module, no on/off state (see Action modules). Refused together with `setting.N`, `hookpoints`, `depends`, `not_with`, `rerun_on`, `stock_file.N`; `apply.sh` may use only `call_service`; `ui.txt` needs a `button` block | `kind` |
| `icon` | one of `box`, `wifi`, `phone`, `terminal`, `car`, `gear`, `display`, `speaker`, `camera`, `map`, `power`, `key`, `skip`, `button`, `link`, `bolt` | app-drawn line icon on the module card and detail panel; default `box`; modules cannot ship images | `icon` |

Example (`wireless-carplay-and-aa`, design sketch): `id`, `version=1.0.0`, `api=1`, `cars=NEEV.KOR.*.260902`,
`restart=head_unit`, `rerun_on=boot,screen_on`,
`uses=wifi.radio:ap,system.app_process:only`,
`conflicts=hmgapi.wireless.carplay.aa,leafia.wireless.carplay.aa,nemesis.wireless.projection`,
`stock_file.1=/system/bin/app_process:33f798115689d1859e8d2159dc88e7dc`, `hookpoints=hookpoints.txt`,
`setting.1=audio_fix:toggle:on`.

Unknown keys refuse install. Ownership keys (`owns_*`, `services`, `service_calls`, `reassert_props`,
`owns_generated_dirs`, `restore`, `watch`, `excludes`) are never written by the author; root generates them.

## Restricted scripts

`apply.sh`, `check.sh` and `status.sh` look like shell but are never run by a shell (owner decision).
A root-side mksh interpreter reads them line by line. A line is blank, a comment (`#` first),
`if CHECK`, `elif CHECK`, `else`, `fi`, `then` (also accepted as `; then` after a check), or one verb. A CHECK
is one check, optionally prefixed by `not`; combine by nesting (depth 8). At most 512 lines. Tokens split on
spaces; `"..."` quotes a token with only `\"` and `\\` escapes. No variable expansion; the whole token
`{setting:KEY}` is replaced by the validated setting value and is allowed only in value positions (never in a
path, property name, service or package); free-form values never reach a command line. Any other line refuses
install with `HSM-E<nnn> <file>:<line>: <reason>`. Host lint on a PC cannot protect the car, so this is the
only enforcement point for third-party modules.

There is no revert script: turning a module off replays its ledger backwards, so every branch that ran is
restored exactly. Each write verb baselines, writes, verifies and appends to the ledger.

Write verbs (`apply.sh` only):

| Verb | Runtime call | Touched key |
| --- | --- | --- |
| `set_prop [--reassert] KEY VALUE` | `sg_prop_set` | `owns_props` (+ `reassert_props`) |
| `put_file DEST SRC [MODE]` | `sg_payload_dirs` + `sg_file_put` | `owns_files` |
| `put_files DESTDIR/ SRCDIR/ [MODE]` | `put_file` per regular file, one level | `owns_files` |
| `replace_line FILE STOCK NEW` | `sg_file_replace_line` | `owns_lines.N` |
| `restart_service NAME` | `sg_service_restart` | `services` |
| `call_service SERVICE CODE` | `sg_service_call` | `service_calls` |
| `hook_apps JAR CLASS PROCESS...` | `core/hook/mods/<id>/` + `sg_core_hook_ensure` | `owns_files` (+ `hooks=1`) |
| `app_data_dir NAME PACKAGE...` | generated-dir cleanup | `owns_generated_dirs` |

Checks (all scripts): `setting_is KEY VALUE`, `prop_is KEY VALUE`, `file_exists PATH`, `file_missing PATH`,
`car_is GLOB`, `module_on ID`, `hookpoints_ok`, `uses_on RESOURCE[:MODE]`, `action_is NAME`. Settings reach
scripts only through `setting_is` and `{setting:KEY}`, validated against `module.properties`.
Other verbs: `log TEXT` (module log, not the ledger; all scripts); `block @string` (refuse enable) and
`warn @string` (shown in the confirm dialog) in `check.sh`; `info KEY prop NAME`, `info KEY setting KEY`,
`fail @string` in `status.sh`.

Example `apply.sh`:

```sh
set_prop persist.ium.support carplay
put_file /system/lib/libleafiaaac.so files/libleafiaaac.so
if file_missing /system/etc/permissions/com.hkmc.software.wifihotspot.xml; then
    put_file /system/etc/permissions/com.hkmc.software.wifihotspot.xml files/feature/wifihotspot.xml
fi
if setting_is audio_fix on; then
    put_files /system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes/ files/recipes/
fi
replace_line /system/onebin/neev_kr/featurexml.cfg "<stock line>" "<new line>"
hook_apps files/hook.jar <entry class> com.daudio.app.dipo com.tcc.iap2server
```

`raw_shell=1` runs the three scripts with mksh after `common.sh`, like current built-in scripts. Built-in
modules shipped inside the package may use it without developer mode; an installed module needs developer
mode and a high-risk confirm, and only its verb calls keep the exact-restore guarantee. Its touched list is
declared with the current `owns_*` keys.

## Touched list and enforcement

At install root collects every write verb from every branch (also done by `hsm pack`) and generates the
ownership keys into the installed `module.properties`. Paths, property names, services and packages are
literal, so the list is exact. The existing generator and runtime rules apply unchanged: ownership validation
on every write (the runtime rejects any write outside the list), whole-file exclusivity, line-claim
uniqueness, baseline, ledger, guarded restore. A module whose writes are only `call_service` is generated
with `restore=reboot` (classified automatically; the disable confirm says a head-unit restart restores stock
behaviour).

## Conflicts

Modules declare what they use, not which modules they dislike. Enable is refused when, against any module
that is on: touched lists overlap (property, whole file, or stock line); a `uses` resource overlaps by
hierarchy and the modes differ, or either side is `only`; `not_with` names it; or a `conflicts` owner is
present. Enable additionally refuses shared owned properties and `uses` clashes via `sg_module_clash`. The
refusal names the blocking module in plain language and offers to turn it off through the normal plan and
confirm.

Layers (owner decision):
1. Automatic from the touched list; nothing to write.
2. `uses=<resource>:<mode>,...`. `wireless-carplay-and-aa` declares `wifi.radio:ap`, `wifi` declares
   `wifi.radio:sta`, and neither names the other.
3. Optional `check.sh` with read-only checks plus `uses_on`; e.g. `if uses_on wifi:sta; then block @need_wifi_free; fi`.

`not_with` is for the rare case that must name a module; `conflicts` is for external tools.

### Resource names and modes (resource registry)

Rules:
1. Names are dotted and hierarchical. A resource overlaps its parents and children: `wifi:only` conflicts
   with any `wifi.radio:*`; `audio.output:only` conflicts with `audio.output.navi:*`.
2. Modes: `use` shared, any number of modules (default when no mode is written). `only` exclusive, conflicts
   with every other mode on the same resource. Named modes (catalogue): two different named modes conflict,
   the same named mode is shared, a named mode does not conflict with `use`. `read` never conflicts; it
   documents a dependency for the review screen.
3. Custom names `x.<author>.<name>` are accepted without validation so third-party authors can coordinate
   among their own modules. Other unknown names warn at install and in `hsm validate` (typo catch).
4. A module that names no resource still gets automatic conflicts from its touched list.
5. New catalogue names are added to this file and to the core list the runtime ships; names are never removed
   or renamed, only marked deprecated.

The owner asked for a broad catalogue so authors rarely need a custom name. Catalogue (resource: named modes;
notes):

- Connectivity: `wifi.radio` (`ap`, `sta`, `off`; one radio, AP for projection, STA for client);
  `wifi.ap.config` (hotspot SSID, password, band, channel); `wifi.sta.config` (saved networks, auto-join);
  `bt.radio` (`on`, `off`); `bt.profile.a2dp` (media audio); `bt.profile.hfp` (calls); `bt.profile.pbap`
  (contacts sync); `bt.profile.avrcp` (media control); `bt.pairing` (pairing flow, device list);
  `usb.host` (`projection`, `storage`, `adb`; front USB port role); `usb.gadget` (device-side USB);
  `adbd` (`usb`, `tcp`, `off`; ADB daemon transport); `network.routing` (default route, NAT, tethering);
  `network.dns`; `network.firewall` (iptables rules); `modem` (telematics modem, if present); `gps`
  (position source, NMEA); `time.sync` (network or GPS time).
- Phone projection: `projection.carplay` and `projection.androidauto` (`wired`, `wireless`);
  `projection.mirror` (other screen-mirroring stacks); `projection.session` (session start/stop hooks,
  shared by both); `projection.audio` (audio routing); `projection.tbt` (turn-by-turn data to cluster/HUD).
- Audio: `audio.output` (whole path), `audio.output.media`, `audio.output.navi` (guidance prompts),
  `audio.output.phone` (call audio), `audio.output.alert` (chimes, warnings), `audio.focus` (focus and
  ducking), `audio.volume` (curves, per-source levels), `audio.eq` (equaliser, sound field), `audio.codec`
  (decoder libraries, formats), `audio.mic`, `audio.voice` (recognition engine).
- Display and UI: `display.brightness` (day/night curves), `display.overlay` (anything drawn over other
  apps), `display.resolution` (density, layout scaling), `ui.home` (home screen and widgets), `ui.launcher`
  (app list), `ui.statusbar`, `ui.softkeys` (on-screen system keys), `ui.theme` (colours, skins), `ui.font`,
  `ui.wallpaper`, `ui.clock` (style and screen), `ui.boot` (logo and animation), `ui.consent` (startup
  consent or disclaimer screen), `ui.locale` (language and region), `ui.notification` (popups, toasts).
- Input: `input.keys.steering`, `input.keys.headunit` (hard keys and knobs), `input.keys.custom`
  (user-programmable button), `input.touch` (handling, gestures), `input.voice_key` (push-to-talk).
- Vehicle: `vehicle.can` (`read`, `write`; vehicle bus access), `vehicle.speed_lock` (driving restrictions on
  UI and video), `vehicle.camera.rear`, `vehicle.camera.surround`, `vehicle.cluster`, `vehicle.hud`,
  `vehicle.diagnostics` (engineering and factory menus), `vehicle.factory` (factory Binder services),
  `vehicle.charging` (EV charging screens and schedules), `vehicle.climate`, `vehicle.settings`.
- Stock apps: `app.navi`, `app.radio` (FM/AM/DAB), `app.dmb` (terrestrial TV), `app.media` (USB and BT
  player), `app.phone`, `app.settings`, `app.telematics` (connected-car service app), `app.voice` (voice
  assistant app), `app.manual` (on-screen manual), `app.packages` (installing or replacing APKs).
- System: `system.app_process` (normally `only`; owned by the core hook host), `system.zygote` (zygote-wide
  preloads), `system.hook.<package>` (per-app hooks, e.g. `system.hook.com.mnsoft.navi`), `system.framework`
  (jars and resources), `system.feature` (feature XML and `featurexml.cfg`), `system.permissions`
  (permission XML), `system.properties` (broad property changes), `system.init` (init services),
  `system.boot` (sequence and boot-completed timing), `system.dalvik` (Dalvik cache), `system.update`
  (firmware update behaviour), `system.log` (levels, capture), `system.storage` (mounts, partitions),
  `system.security` (SELinux mode, verification).
- Power: `power.sleep` (sleep and quick-boot), `power.wake` (wake triggers), `power.acc` (accessory on/off),
  `power.screen` (screen-off behaviour).

Current modules' `uses` (proposed):

| Module | `uses` |
| --- | --- |
| `wireless-carplay-and-aa` | `wifi.radio:ap,projection.carplay:wireless,projection.androidauto:wireless,system.app_process:only,system.feature` |
| `wifi` | `wifi.radio:sta,system.feature` (built-in client role; USB roles use `rtwlan*`) |
| `wireless-adb` | `adbd:tcp` |
| `skip-consent-screen` | `ui.consent,vehicle.factory` |
| `user-button-shortcut` | `input.keys.steering,input.keys.custom` |
| `user-button-head-unit` | `input.keys.headunit,input.keys.custom` |

The `user-button-*` assignments are provisional; confirm against each module's notes before converting it.

## Core hook host

`hook_apps files/<x>.jar <entry class> <process>...` registers the module with one shared `app_process`
wrapper. Modules ship only hook code (a dex jar per target process) and resolve stable hookpoint IDs through
the core map; several modules can hook apps without each replacing `app_process`. The entry class extends
`hmgapi.hook.ModEntry`, compiled against `out/hook-sdk/hmg-seogaemo-hook-api.jar` without bundling it
(bundled `hmgapi.hook` classes fail to link on Dalvik). Processes match the process name or package. The
wrapper is derived from HMG-API (AGPL-3.0): keep headers and provenance in `UPSTREAM.md`.

See `core/hook/`. Host tests cover install, shared wrapper, release after the last module and stock restore.
`wireless-carplay-and-aa` is a hook module of the same host (built-in, `hooks=1`), so hook modules and
CarPlay share `app_process`.

- Install generates `hooks=1` and `restart=head_unit`.
- Registration is the runtime API `sg_hook_register` (the `hook_apps` verb calls it).
- Engine: the core jar holds the whole engine (`hmgapi.hook`, `hmgapi.engine`: hooks, points, native
  patches, app parts, per-process `RuntimeResult`) built from the CarPlay payload sources, plus the core's
  own `HmgApi`, `ModContext` and `HostStatus` (`core/hook/status`). Module jars hold only their own
  packages.
- Apply commits `$SG_DATA_ROOT/core/hook/mods/<id>/{hook.jar,entry,processes}` (module ledger), then
  `sg_core_hook_ensure` installs the wrapper, `libhmg_seogaemo_hook.so` and `hmg-seogaemo-hook.jar` under the
  ledger owner `modules/core-hook` (generated manifest `core/hook/core-hook.properties`, `known_stock` taken
  from the CarPlay manifest). Revert of the last hook module restores stock through `sg_core_hook_release`;
  stock restore also releases a leftover host. `wireless-carplay-and-aa` is itself a hook module of the
  host (`hooks=1`), so it shares the wrapper with any other hook module.
- Zygote: guard files and boot guard as CarPlay, under `modules/core-hook/`; kernel log tag
  `hmg-seogaemo-hook`, logcat tag `HMG-Seogaemo-Hook`. The engine checks the verified car map, loads each
  `mods/<id>` with its own `DexClassLoader` (odex in `core/hook/dex/<id>`), calls `zygoteInit`, then
  `appLoaded` in matching processes; one failing module is skipped (a module with unverified hookpoints or
  that throws is turned off alone). It writes `core/hook/status` (`gate=`, `mod.<id>=`), shown by module
  status as `info.hook_host`, `info.hook_gate`, `info.hook_load`.

Design goals still open (hook API, to define): hook API version; a core API resolving stable hookpoint IDs
where a missing ID disables that part and never crashes the app; the bounded per-process result record
`runtime/<id>/p-<pid>-<start_ticks>.txt` (already used by `wireless-carplay-and-aa`) generalised so `status`
reports every hooking module.

CarPlay on the core host: entry `hmgapi.mods.wireless.Wireless` (zygote record under
`runtime/wireless-carplay-and-aa`, `boot` points gate) for its six apps; app parts load from a
world-readable copy `/system/framework/hmg-seogaemo-wireless-parts.jar` (apps cannot read the core's root-only
copy).

CarPlay migration from the self-installed wrapper (0.1.33 and earlier): on apply, a module that still holds
its old `app_process` record is first restored exactly with `sg_revert_all` (old wrapper, loader, JAR, stock
copy, guard files, properties, feature lines), then applied through the core host in the same call; a drift
refuses with a conflict and nothing more changes. The running zygote stays on the old wrapper until restart,
and status reports `pending-restart` while the old record exists. `scripts/postinstall.sh` runs this apply right
after a USB install when CarPlay is on, and OTA runs reconcile at its end, so either update needs one restart;
boot reconcile alone would run after zygote start and need a second. The old paths stay in the manifest's
`owns_files` for this restore. Host-tested; on-car run pending.

Expected shape of `wireless-carplay-and-aa` after conversion: three `set_prop`, `put_file`/`put_files` for
the AAC library and recipe files, `if file_missing` + `put_file` for the three feature XMLs, three
`replace_line` in `featurexml.cfg`, `hook_apps` for its five target apps, `app_data_dir` for runtime and dex
dirs, and a `status.sh` for projection runtime readiness.

On-car checklist before relying on `hook_apps`: fresh enable and restore with only the core host; CarPlay
migration on a car with CarPlay on; boot guard after 3 forced zygote crashes; OTA package update with the
hook host on; stock restore and uninstall exact.

## Lifecycle

- Apply: run `check.sh` (any `block` refuses; `warn` lines join the confirm dialog), then `apply.sh`. A
  failing verb stops the script and `sg_revert_all` undoes this run.
- Revert: `sg_revert_all`; there is no revert script.
- Re-run (`rerun_on`): `apply.sh` again while desired on. A re-run never captures a new baseline; a verb whose
  target has no baseline fails. `set_prop --reassert` marks a property rewritten on drift when stock firmware
  changes it (replaces `reassert_props`).
- Setting change while on: `<id> set KEY VALUE` saves the validated value, reverts the module and applies it
  again, so nothing from the previous value or branch survives. While off it only saves the value.
- Button: `hmg-seogaemo-root <id> action <name>` (`[a-z0-9_]{1,40}`, installed modules only, name must be a
  `button name=` in `ui.txt`, module must be desired on unless `kind=action`) runs `apply.sh` again with `action_is NAME` true under
  the operation lock, after the confirm (`confirm=@s`, else the label). Targets it touches get baselines and
  ledger entries like any apply; a failure reports `failed` and keeps backups (no rollback of the running
  module); revert restores everything.
- Status: `on` when every touched target is `sg_applied`; existing restart markers give `pending-restart`;
  `status.sh` adds `info.*` and may report `fail`.
- IDs: built-in module IDs are reserved; installing a module whose `id` is already installed from another
  source is refused.
- Whole restore and HMG-Seogaemo uninstall include installed modules in the same dependency graph and revert
  them in reverse order.

## Action modules (`kind=action`)

A one-shot module has nothing to switch on or restore. Its card shows no switch and no on/off label: the status row is
one button labelled with string `action_label` (else the module name); the detail panel shows the same button. A tap asks
for confirmation with string `action_confirm` (else the label) through `ui.ConfirmDialog`, then runs the module's first
`button` block of `ui.txt` (`hmg-seogaemo-root <id> action <name>`). The module need not be on: the root accepts the
action without desired state, still validating the name against `ui.txt`, taking the operation lock and recording every
`call_service` in the ledger. `apply` is refused, `revert` is a no-op without a restart, status is `off` with detail
`Ready` (or `incompatible`/`conflict` as for any module), stock restore and uninstall have nothing to undo, and the
generated manifest carries `kind=action` and no `restore=reboot`. `module describe` reports `info.kind`. A runtime
without this feature refuses the package as an unknown `kind` key (HSM-E203).

Errors: HSM-E211 forbidden key, HSM-E212 no `button` block, HSM-E213 a write verb other than `call_service`.

## ui.txt

One block per line, drawn at NEMESIS scale with existing settings components. Without `ui.txt` the screen
shows status, the on/off switch and the summary. Blocks: `status`; `toggle setting=K label=@s`;
`choice setting=K label=@s` (a value shows string `choice_K_<value>` when the module has one); `number setting=K label=@s`; `info @s`; `warning @s`; `value label=@s key=K`
(shows `info.K` from the last status; replaces `infoRows`); `button name=N label=@s confirm=@s [danger=1]` (`danger=1`: confirm in the destructive style; runs
`apply.sh` where `action_is N` is true); `enable module=ID label=@s` (normal enable plan for another module;
replaces Java `ENABLE_MODULE`); `open screen=wifi_settings` (opens a stock screen from a fixed core list;
replaces `OPEN_STOCK_WIFI_SETTINGS`; `open screen=wifi_networks` opens the app's USB Wi-Fi network picker, which runs the
module's `wifi_scan` and `wifi_join` actions); `pick_app slot=head|swrc setting=K label=@s` (one row per user button: 기본 기능 turns toggle
setting `K` off; HMG-Seogaemo or a launcher app turns it on, and the chosen app is stored in the app, never sent to
root; changing it is confirmed). Any block may add `when=K`: it is shown only while the last status
reports `info.K=1`. Unknown blocks refuse install. State-changing blocks go through
`ui.ConfirmDialog`. No Java from modules in API 1, so the app process stays free of third-party code. Home
tiles (`Module.homeTiles`) are dropped: no module uses them and the Home redesign does not need them.

The app draws every block with its own fixed row components, so all modules share one look. As for built-in
modules, 옵션 lists only what the user can change: `info` text is shown behind the 도움말 row and `value` rows
appear in the developer-only diagnostics (skipped when the status has no such key). The detail
panel and the module card already show the state, so the app ignores `status` (still accepted). Optional
strings `on_result` and `off_result` are shown as the result line in the on/off confirm. `status.sh`
may print `info note ...`; that value is the one-line note under the module name on its card.

## Root verbs and storage

- `hmg-seogaemo-root module install <sha256>`: 64 lowercase hex only. Root reads `<sha256>.hsm` from the app's
  fixed staging directory (`/data/data/com.seogaemo.hmg/files/hsm/`) or `/data/local/tmp/hsm/` (adb), copies
  it to `/data/nemesis/backup/hmg-seogaemo/staging/`, verifies the hash, extracts, validates everything
  above (`module.properties`, product globs, ownership collisions with installed modules, hookpoints), then
  publishes `/data/nemesis/backup/hmg-seogaemo/installed/<id>/` atomically (outside the package directory so
  package and OTA updates keep it). Installed is not enabled; enabling uses the existing plan and confirm
  flow. Installing over an enabled module is refused.
- `hmg-seogaemo-root module usb-import`: no arguments. The app cannot read head-unit USB mounts, so root copies
  the `*.hsm` files in the `HSM/` folder of each mounted USB drive (the same fixed drive list as `export usb`;
  files elsewhere are ignored) into `/data/data/com.seogaemo.hmg/files/hsm-usb/` (dir 0755, files 0644,
  previous copies removed first). Names must match `[A-Za-z0-9._-]{1,80}` and not start with `.`; symlinks,
  empty files and files over 10 MiB are skipped; at most 20 files. Prints `info.count=<n>`. It changes no
  stock file or property and writes no ledger entry, so the app runs it when Add opens without a confirm;
  the confirmed step is `module install`.
- `hmg-seogaemo-root module remove <id>`: installed modules only; reverts first, verifies stock, fails closed
  on conflict (module and backups kept), then deletes the directory.
- `hmg-seogaemo-root module list`: one `info.module_<snake_id>=<id>,<version>,<source>,<n>` line per module
  (`builtin`, `direct`, later `registry`); `<n>` is the 1-based catalog position.
- `hmg-seogaemo-root module describe <id> <locale>`: installed modules only (the app cannot read the
  root-only installed directory). Prints `info.version|source|restart|depends|excludes|uses|restore|icon`,
  `info.setting_<N>=<declaration>`, `info.ui_<N>=<block line>`, then `info.str_<key>=<value>` for `en`
  followed by `<locale>` (later lines win). Install caps keep it inside the app's 8 KiB root output: each
  strings file 2048 bytes and 64 entries (key `[a-z0-9_]{1,40}`, value 200 characters), `ui.txt` 1024 bytes,
  32 blocks, 200 characters.
- `hmg-seogaemo-root <id> set <key> <value>`: installed modules only; key `[a-z0-9_]+`, value `[a-z0-9_.-]+`,
  then checked against the declared type. Holds operation.lock.
- App side: `RootClient.moduleList|moduleDescribe|moduleInstall|moduleRemove|moduleSet|moduleUsbImport|moduleAction`,
  `InstalledModule` (parsed description), `ModuleRegistry.refreshInstalled` (called by `ModuleManager.plan`
  so installed modules take part in ordering and symmetric exclusions). Root output is decoded as UTF-8.
- Catalog files: `installed.list` (install order), `installed.graph` (same columns as `modules.graph`),
  `installed/<id>.properties` (generated manifest), `installed/<id>.hookpoints`, `settings/<id>/<key>`.
  `sg_module_list|props|script|dir` in `common.sh` resolve built-in or installed; reconcile reads the two
  list and graph files directly.
- Dispatch, reconcile, watcher, stock restore and uninstall treat installed modules like built-in modules in
  one dependency order.
- Update flow (design): install the new version beside the old one, revert the old one if its touched list
  changed, then switch. An unchanged touched list keeps the baseline.

## Install sources and trust (owner decisions)

Design, not implemented (P6). Sources: USB (`hmg-seogaemo/modules/*.hsm` on the stick root; the app lists
them); adb (`hsm push` copies to staging and calls the fixed install verb); store (registry index fetched
like OTA updates, deferred). Install review screen before the confirm: what it changes, whether a restart is
needed, whether it hooks apps, and its source.

Module code lives in each author's own GitHub repository (package files plus GitHub Release assets); we keep
only a registry of which repositories are listed. NEMESIS root is reachable by any UID, so every check runs
on the root side.

| Route | Who | Shown as |
| --- | --- | --- |
| Store (registered repositories) | everyone, mainly non-developers | 등록된 모듈 · 작성자 |
| Direct install (repository URL, USB or adb file) | developer mode on | 직접 추가함 · 검증 안 됨 |

- Registry: a separate web platform, not a pull-request flow. Authors submit a registration request; the
  platform shows which modules are registered; the owner can also register any repository directly.
- Direct install is expected to be the main path for module developers; receivers of shared files must enable
  developer mode and accept an unverified-module confirm. Every route uses the same ownership, ledger, exact
  restore and boot guard. Modules that call `hook_apps` get a high-risk install warning whichever route.
  Developer mode is a persistent setting behind a confirm.

## Developer and AI tooling

Done (P5): `tools/hsm new|validate|pack|push`. `validate` installs into a throwaway copy of the
real root runtime (same interpreter and HSM-E errors) against this repository's built-ins and prints the
generated ownership; `tools/test-hsm-cli.py` covers it. Host CLI design (Python, alongside
`tools/`); `new`, `validate`, `pack` and `push` exist, the rest is design:
- `hsm new <id>` writes a working module, an `AGENTS.md` for AI assistants, and a test; one example module
  per complexity level, so an AI assistant can write a valid module from a description.
- `hsm validate` checks properties, verbs, product globs, shell lint, strings and touched-list collisions
  with machine-readable errors (`HSM-E012 apply.sh:4: set_prop target persist.sys.x is owned by wifi`).
- `hsm pack`, `hsm push --adb <ip>`.
- Design, not implemented: `hsm test` (apply, status, revert and exact-restore check against fakebin and the stock file
  snapshot from `maps/`, once per branch setting combination; on host only safe for property-only modules
  because file verbs write absolute `/system` paths), `hsm logs <id>`.
- In-app developer page (developer mode only), per module: raw status, last root call stdout and exit code,
  ledger entries, single apply or revert, reload from USB. Not implemented.

## Remaining plan and open decisions

Each phase lands as its own commits, each passing `make test`; built-ins keep working throughout.
- P0 contract (done: this document). P1 root runtime and P2 app data (`ModuleRegistry` reads `module list`,
  one generic `PackageModule` implements `Module` from `module.properties`, `ui.txt`, `strings/<locale>.txt`)
  done except screens. P3 core hook host: see above.
- P4 convert built-ins, lowest risk first: `skip-consent-screen`; `user-button-head-unit`,
  `user-button-shortcut`; `wireless-adb` (its "connect another Wi-Fi" action becomes an `enable` block);
  `wifi` (was `wifi-client`); `wireless-carplay-and-aa` (native build stays in this repository). Each conversion deletes
  that module's Java class and keeps its `test/run.sh` green. After the last, remove `gen-modules.sh` and the
  compile-time registry.
- P6 install UX: developer mode, install from USB, adb or repository URL, the review screen, remove. Registry
  platform and store come after.
- Open: registry platform hosting, index format, and how the app verifies the index; whether the registry pins
  a release digest or follows each repository's latest release.
