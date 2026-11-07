# HMG-API upstream tracking

HMG-Seogaemo's core mapper and hookpoint catalogue are independently implemented. Their behavior follows [VysseCodes/HMG-API](https://github.com/VysseCodes/HMG-API) at commit `4fab437`. Upstream-derived hookpoint IDs intentionally match HMG-API so the existing wireless projection hooks consume the published map. The stock-guidance extension below adds our own stable IDs. The owner supplied the NEEV KOR names and stock MD5s in the bundled map.

| Our component | HMG-API path at `4fab437` |
| --- | --- |
| `core/map/src/.../HmgSeogaemoDexIndex.java` | `core/runtime/java/hmgapi/engine/Dex.java` |
| `core/map/src/.../HmgSeogaemoJsonIO.java` | `core/runtime/java/hmgapi/engine/Json.java` |
| `core/map/src/.../HmgSeogaemoMapFiles.java`, `HmgSeogaemoMapTool.java` | `core/runtime/java/hmgapi/engine/CarMap.java`, `MapProbe.java` |
| `core/map/src/.../HmgSeogaemoMapScanner.java` | `core/runtime/java/hmgapi/engine/MapProbe.java` |
| `core/map/src/.../HmgSeogaemoMapVerifier.java` | `core/runtime/java/hmgapi/engine/MapCheck.java` |
| `tools/map-car.py` | `tools/map-car.py` |
| `tools/verify-map`, `tools/validate-maps.py` | `tools/test-hooks.py` |
| `tools/hmg-seogaemo-list-stock-files.py` | `core/hookpoints/*.json` |
| `tools/test-map-scanner.py`, `tools/test-map-car.py` | `tools/probe-test.py`, `tools/test-hooks.py` |
| `core/hookpoints/btsettings.json` | `core/hookpoints/btsettings.json` |
| `core/hookpoints/buttonsettings.json` | `core/hookpoints/buttonsettings.json` |
| `core/hookpoints/dipo.json` | `core/hookpoints/dipo.json` |
| `core/hookpoints/framework.json` | `core/hookpoints/framework.json` |
| `core/hookpoints/gpm.json` | `core/hookpoints/gpm.json` |
| `core/hookpoints/homesetting.json` | `core/hookpoints/homesetting.json` |
| `core/hookpoints/iap2.json` | `core/hookpoints/iap2.json` |
| `core/hookpoints/launcher.json` | `core/hookpoints/launcher.json` |
| `core/hookpoints/panel.json` | `core/hookpoints/panel.json` |
| `core/hookpoints/settings.json` | `core/hookpoints/settings.json` |
| `core/hookpoints/themesettings.json` | `core/hookpoints/themesettings.json` |

Run `sh tools/upstream-diff.sh [path/to/HMG-API]` after updating a local clone. Review the reported commits and changed paths, then translate relevant behavior into our schema and implementation. Keep point IDs stable. Re-run `make test`, `tools/verify-map`, and on-car mapping before accepting changed shape rules. Upstream changes are never copied automatically.

## Component review baselines

Each section of the host review helper has its own explicit baseline below.
A review records evidence; it does not advance the baseline or import code.
Change the corresponding literal in the script and this table together only
when the translated component has been accepted.

| Review component | Baseline | Tracked HMG-API paths |
| --- | --- | --- |
| Mapper and catalogue | `4fab437` | Mapper engine files listed above, `core/hookpoints/**`, mapper/verification tools |
| Core hook host (`core/hook/`) | `4fab437` | Built from the ported wireless payload (`core/loader/**`, `core/zygote/**`, `core/runtime/java/hmgapi/hook/**`) with core paths; `core/hook/src` replaces `HmgApi`, `ModContext`, `RuntimeResult`, `RequiredPoints` |
| Ported wireless payload | `4fab437` | `mods/wireless-carplay-aa/**` (including native converter and recipes), `core/loader/**`, `core/zygote/**`, `core/runtime/java/hmgapi/hook/**`, `MemRecipe.java`, `tools/mkrecipe.py`, `tools/mkmemrecipe.py` |
| Install, uninstall and restore | `4fab437` | `install/**`, `core/app/install.sh`, installer/NEMESIS package tools |
| hmgapid and runtime engine | `4fab437` | `core/hmgapid/**`, engine/vehicle Java, runtime tests |
| CI and workflows | `4fab437` | `.github/workflows/**`, Dependabot, Makefile, aggregate test/script checks |

HMG-API v1.0.1 (`dd10045`) was reviewed on **2026-11-04**. There are no
wireless payload changes in `4fab437..dd10045`: the wireless mod (including
recipes/converter), loader, zygote, copied hook classes, and `MemRecipe.java`
are unchanged. The broader hook-runtime directory contains changes to
`HmgApi.java`, `Mods.java`, and a new `ModDexCache.java`; these generic
loader changes need separate assessment because our port replaces the generic loader.
The 18 catalogue additions are translated below; every other mapper/catalogue
rule keeps the `4fab437` baseline.
The review also exposes install/restore, hmgapid/runtime-engine, and workflow
changes for separate assessment; those upstream components are not installed
alongside HMG-Seogaemo and are never imported automatically.

Catalogue-only addition baseline (2026-11-04): translated the following 18 IDs
from HMG-API `dd10045` (v1.0.1), iAP2 definitions introduced by
`13a2b17`/`c4f24e9`/`02609bc` and framework definitions by `d120037`. All other
catalogue rules and runtime/module provenance retain the `4fab437` baseline.
No upstream mapper/tool source was copied. KOR names were resolved independently
from exact-stock odex; see [coverage](docs/hookpoints.md) and the bundled evidence.

- `iap2.service.on_destroy`, `iap2.service.on_bind`,
  `iap2.service.native_handle`, `iap2.service.native_lock`,
  `iap2.init_info.use_vehicle_information`, `iap2.init_info.use_vehicle_status`
- `framework.bcm_service.batt_cond_indicator`, `framework.hev_flag.batt_cond_failure`,
  `framework.car_services.cluster`, `framework.cluster_service`,
  `framework.cluster_service_stub`, `framework.cluster_service_stub.as_interface`,
  `framework.cluster_listener`, `framework.cluster_listener_stub`,
  `framework.cluster_listener_stub.as_interface`, `framework.cluster_listener_stub.battery_info`,
  `framework.cluster_service.add_listener`, `framework.cluster_service.battery_info`

## Stock-guidance catalogue extension (2026-11-07)

These six IDs are independently derived from the owner's read-only NEEV KOR
stock dump, rather than translated from HMG-API. The general upstream baseline
and the 18 v1.0.1 additions above are unchanged. All six uniquely resolve with
our DEX scanner without reference-map fallback in
`/system/framework/automotive.odex`, MD5 `c76b8209ef171739b177eb14e8df61dd`.
Exact signatures (methods and field are instance members; all methods return void):

| Stable ID | Stock class/member signature |
| --- | --- |
| `framework.navigation_cluster.update_tbt_trap_info` | `com.hkmc.cluster.NavigationCluster.updateTBTTrapInfo(int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int): void`; argument 12 is barGraphLevel |
| `framework.navigation_cluster.update_tbt_trap_info_new` | `com.hkmc.cluster.NavigationCluster.updateTBTTrapInfoNew(com.hkmc.cluster.NavigationCluster$NaviTbtTrapInfo): void` |
| `framework.navigation_cluster.update_clu_data_new_14` | `com.hkmc.cluster.NavigationCluster.updateCluDataNew_14(int, int, int, int, int): void` |
| `framework.tbt_trap_info` | `com.hkmc.cluster.NavigationCluster$NaviTbtTrapInfo` |
| `framework.tbt_trap_info.new` | `com.hkmc.cluster.NavigationCluster$NaviTbtTrapInfo.<init>()` |
| `framework.tbt_trap_info.bar_graph_level` | `com.hkmc.cluster.NavigationCluster$NaviTbtTrapInfo.barGraphLevel: int` |

The six additions have exact-stock host evidence in the bundled sidecar and
still need on-car reflection. No module requirement changes here. Source paths,
smali cross-checks and Parcelable copying notes: [.agents/car-mapping.md](.agents/car-mapping.md).

## Phone Projection menu on Korea

HMG-API changes the Phone Projection menu only for US/Canada (`Wireless` hook on `btsettings.projection_helper.open_wireless_page`).
For Korea (region 0) we extend our own hook (`ProjectionMenu`, `Wireless.phoneProjectionMenu`) to call the stock non-wireless
branch (`open_other_page`), the behavior stock Korea has without the wireless features. The community HMG Leafia Plus
r8.2 build (third party, not installed alongside) was the behavioral reference: it patches `HKMC_BtSettings` so region 0 skips the
wireless page. Behavior only; no code or odex delta was copied, and the stock choice was confirmed in the stock smali.
See [.agents/wireless-carplay-and-aa.md](.agents/wireless-carplay-and-aa.md).

## CarPlay connection owner reference (r8.2, behavior only)

The community HMG Leafia Plus r8.2 build (third party, not installed alongside) was the behavioral reference for the
CarPlay connection owner (`ProjectionOwner`, item 9 of [.agents/carplay-connection-owner.md](.agents/carplay-connection-owner.md)):
which status Phone Projection receives for a wireless CarPlay session (ready, connected, ended), when they are sent
(after DiPO's activation state changes), and how an owed end is carried into a quick reconnect. Behavior only: the rules were
read from its decompiled owner class and written again as our own state machine, names and tests. No smali, Java or
structure was copied, and its owner class is not ported. Where we differ on purpose: an owed end waits for DiPO to go inactive
(with a 30 s cap) instead of being sent at the next session start, and activation is polled with a cap. Stock NEEV KOR smali
is the evidence for our hook points (`dipo.carplay.*`, `btsettings.pp_bt*`). The same build's delete order for the connected
phone (disconnect first, row deleted after the matching end, with a binder barrier and a fallback) was the behavioral reference
for `ProjectionDelete` (item 10); we add a 15 s fallback it does not have for CarPlay. Behavior only, nothing copied.
See [.agents/wireless-carplay-and-aa.md](.agents/wireless-carplay-and-aa.md).

## Startup consent screen reference

The community [HKMC Factory 82 package](https://github.com/armandodollia/nemesis-package-builds) by armandodollia (`local.hkmc.factory82`, release `4.2.1`, MIT) is the behavioral reference for `skip-consent-screen`. Its `packages/hkmc-factory82/svc/watch.sh` calls `com.hkmc.factory` Binder transaction `82` after startup or display wake. HMG-Seogaemo independently implements a fixed-call API and shared `watcher` service; it has not copied the package scripts. See [.agents/skip-consent-screen.md](.agents/skip-consent-screen.md).

## User button shortcut reference

`user-button-shortcut` (steering) and `user-button-head-unit` follow the shared
action-broadcast / explicit-activity behavior in
HMG-API `core/runtime/java/hmgapi/hook/StarKey.java:64-103` at `4fab437`. The
owner-selected no-hook alternative omits stock-list injection (`:115-204`) and
uses our guarded exact property restore instead of upstream's reset-to-None.
Module and receiver code are independently written; no upstream source was copied.
See [.agents/user-button-shortcut.md](.agents/user-button-shortcut.md) for KOR
odex evidence (including head getCustomKeyAction and processCustomKey offsets)
and physical-car checks. Both independently own one property and share our fixed
receiver; no additional upstream source was copied.

The user-button reassertion follow-up is owner-directed behavior beyond upstream:
while enabled, our fixed action overrides stock resets and stock-settings choices,
including quick boot without a new boot ID/display transition. The shared watcher
reuses fixed screen_on dispatch on declared property drift; original product-bound
baselines survive, and disable restores them even over drift. This uses no upstream
hook code; see the module/runtime notes for policy and car verification limits.

## Android Auto UTF-8 length helper

`modules/wireless-carplay-and-aa/files/recipes/aa-tbt-48ee793a.recipe` and `aa-tbt-a0bea1c4.recipe` come from HMG-API but are no longer unchanged: the 32-byte UTF-8 length helper at segment offset `0x17a` is replaced. HMG-API `main` 1.0.2 still ships the unfixed helper (it cut the last Hangul syllable of every short turn-by-turn string). The fix was located and confirmed against the third-party package `HMG_Leafia_Plus_Wireless_CarPlay_AA-v1.0.5.NEEV.KOR.03-r8.2` (its `patches/neev_kr/libautoreceiver_infobank.tbt.lpd`, reference only, not executed or copied). Our replacement is written from the described logic in `modules/wireless-carplay-and-aa/payload/recipes/aa-utf8-len.s` and happens to assemble to the same 32 bytes. See [.agents/wireless-carplay-and-aa.md](.agents/wireless-carplay-and-aa.md). Re-apply this slot when taking new upstream recipe changes.

## Android Auto lane packing

The same two recipes carry a second local change: the lane byte of next-turn event 34 (upstream 1, or 2 when any direction is recommended) is the mask of recommended arrow slots, and shape 9 (U-turn right) gets the U-turn arrow. The in-place edits and the extra tail code are written from our own analysis of the segment in `modules/wireless-carplay-and-aa/payload/recipes/aa-lane-routes.s`, applied with `apply-aa-lane-routes.py`; test `test/aalanes`. The third-party package `HMG_Leafia_Plus_Wireless_CarPlay_AA-v1.0.5.NEEV.KOR.03-r8.2` was only compared (its library patch matches this segment plus a raw NavigationState hex dump; its lane colours are made in Java); nothing was copied. The Java side (`AaTurns`, `dipo/CpLaneFrame`) is our own. Re-apply with the script when taking new upstream recipe changes.

## USB Wi-Fi kernel drivers

`kernel/usb-wifi/` builds two GPL-2.0 Realtek out-of-tree drivers for the Gen5W
`3.18.24-tcc` kernels (tcc803x and tcc897x). Sources are fetched at build time at these
pins and never vendored; our changes are the patches in `kernel/usb-wifi/patches/`.

| Module | Chips | Source | Pinned commit |
| --- | --- | --- | --- |
| `88x2bu.ko` | RTL8812BU / RTL8822BU | [cilynx/rtl88x2bu](https://github.com/cilynx/rtl88x2bu) | `04ed7009bac4b235fe1880ba29e23159f49a6121` (2026-08-18) |
| `8851bu.ko` | RTL8831BU / RTL8851BU | [fofajardo/rtl8851bu](https://github.com/fofajardo/rtl8851bu) | `9e37e7a1101316a05d5daede91549ea779b64539` (2026-09-07) |

Kernel: kernel.org `linux-3.18.24.tar.xz` (sha256
`ed54cf8c3ac6b95fc17b07b3a236bc42719c96fee08fe696cabfb5b8e07f8c1b`); compiler: AOSP
`prebuilts/gcc/linux-x86/arm/arm-eabi-4.7` at `8b880805d454664b3eed11d0f053cdeafa1ff06e`
(kitkat-release). Car facts (kernel version, vermagic, configs, toolchain choice and the
behaviours the dongle needs) come from [GRT47/HKG_5W_USB_Wlan](https://github.com/GRT47/HKG_5W_USB_Wlan)
at `2e9a74c`; that repository has no license, so only its two kernel `.config` dumps were
taken as data (`kernel/usb-wifi/configs/PROVENANCE.md`). Its scripts and driver patches
were not copied. To move a pin, change the commit in `kernel/usb-wifi/build.sh` and this
table together, check that the patches still apply, and rebuild.

The built modules ship in `modules/wifi/files/kmod/<platform>/` (bundled `wifi` package) with
`files/kmod/SHA256SUMS` equal to the build's `out/SHA256SUMS`; their corresponding source is the
pinned commits above plus our patches. `modules/wifi/files/usb-ids.txt` lists the device ids of
the built chips, taken from each driver's `rtw_usb_id_tbl` at these pins. After a rebuild, copy
the four `.ko` files and the sums together (the module test fails on any mismatch).
