Status: current — index of the agent notes, reorganized 2026-11-05.

# Agent notes

`archive/` is not part of the reading order; do not read it unless explicitly asked.

Reading order: `module-architecture.md` → `module-runtime-contract.md` → `ui-guidelines.md` → `ota-implementation.md`, then the docs for the area you change. Each fact lives in one doc; others link to it. Off-car tests do not establish physical-car behavior.

Target: Hyundai Ioniq 5 KOR, `ro.build.product=NEEV.KOR.0000.V039.001.260902` (package glob `NEEV.KOR.*.260902`), onebin `neev_kr`, Android 4.4.2; NEMESIS + HMG-Seogaemo only.

## Core design and runtime

| Doc | Content |
| --- | --- |
| [module-architecture.md](module-architecture.md) | Module contract, state/privilege/recovery, source layout, build-time module list. |
| [module-runtime-contract.md](module-runtime-contract.md) | Root/Java interface: mutation API, status block, ledger, export, line ownership, payload/dir transactions, restore guarantees, shell tools. |
| [module-runtime-implementation.md](module-runtime-implementation.md) | Runtime and host-test implementation findings (shell parity). |
| [reports-recorder.md](reports-recorder.md) | USB report recording (HSM-REPORTS), the car check, redaction and cadence. |
| [boot-lifecycle.md](boot-lifecycle.md) | NEMESIS service semantics, reconcile/watch retries, deferred APK install, map-verify deferral, QuickBoot limits. |
| [stock-restore.md](stock-restore.md) | Whole-package restore, detached uninstall, restart verb, recovery incidents, on-car checks. |
| [installable-modules.md](installable-modules.md) | `.hsm` module packages (API 1), restricted scripts, resource conflicts, core hook host, design rationale. |
| [car-mapping.md](car-mapping.md) | Core mapper, KOR map evidence, v1.0.1 additions, verification seal. |
| [ota-implementation.md](ota-implementation.md) | Signed GitHub Releases OTA, decisions, TLS roots, dispatch/rollback guards. |
| [research-nemesis-packaging.md](research-nemesis-packaging.md) | NEMESIS package facts, implemented package, USB/update route, extraction-mode audit. |
| [android44-shell-audit.md](android44-shell-audit.md) | Pinned KitKat toolbox/mksh evidence, lint boundaries, waivers. |
| [ui-guidelines.md](ui-guidelines.md) | Display tokens, touch sizes, single-panel decision, API 19 notes. |
| [ui-redesign.md](ui-redesign.md) | Approved app redesign: Modules/Car/Settings tabs, card and detail behaviour, Add/USB install, module-provided UI. |
| [ci-upstream-tracking.md](ci-upstream-tracking.md) | CI timing, test runner and shell policy, workflows (release reuses CI), pins, upstream review. |
| [backlog.md](backlog.md) | Open on-car checks and planned work; delete items when done. |

## Modules

| Doc | Content |
| --- | --- |
| [wifi.md](wifi.md) | Wi-Fi radios (former wifi-client): built-in/USB roles, takeover, capability gate, checklist. |
| [external-wifi.md](external-wifi.md) | USB Wi-Fi dongle support: constraints, report evidence, open questions. |
| [wireless-adb.md](wireless-adb.md) | Implemented ADB properties, upstream facts, restart rule, checklist. |
| [wireless-carplay-and-aa.md](wireless-carplay-and-aa.md) | AGPL projection port, hook points, change inventory, TBT behavior, zygote/runtime-record details. |
| [carplay-connection-owner.md](carplay-connection-owner.md) | CarPlay connection owner: Phone Projection state, delete order, two-phone switching; failure paths, design, stages, car plan. |
| [user-button-shortcut.md](user-button-shortcut.md) | Steering/head-unit shortcuts, reassertion, KOR evidence. |
| [skip-consent-screen.md](skip-consent-screen.md) | Factory82 provenance, watcher behavior, checklist. |

## Firmware and TBT research

| Doc | Content |
| --- | --- |
| [neev-kor-api-inventory.md](neev-kor-api-inventory.md) | Offline NEEV KOR vehicle/vendor API inventory, Binder tables, candidate hooks. |
| [cluster-lane-frame.md](cluster-lane-frame.md) | 81-byte cluster lane frame, trailer bitmasks. |
| [cluster-lane-arrows.md](cluster-lane-arrows.md) | Firmware lane arrow image-ID tables, status byte. |
| [cluster-tbt-icons.md](cluster-tbt-icons.md) | Firmware TBT turn-icon and distance-unit codes. |
| [navi-lib-index.md](navi-lib-index.md) | Index of stock `libExSLNavi.so`. |
| [cluster-ar-view.md](cluster-ar-view.md) | Cluster AR turn view: stock-format `updateTBTInfo`, vertical bar (trap info). |
| [hud-hologram.md](hud-hologram.md) | HUD hologram turn: AR display mode, gear out of P; per-type dataset. |
| [hud-junction-view.md](hud-junction-view.md) | HUD junction view: `updateCluDataNew_14` picture/highlight codes; code-table dataset. |
| [navi-ar-guidance.md](navi-ar-guidance.md) | Firmware reference: advanced-TBT/PE14 path, field packing, AR subsystem. |
| [carplay-tbt-learnings.md](carplay-tbt-learnings.md) | TBT fixes ported from HMG-API, open problems. |
| [carplay-tbt-external-research.md](carplay-tbt-external-research.md) | Index of third-party iAP2/HKMC TBT research in `carplay-tbt-external/` (`iap2-protocol`, `mib2q-deep-dive`, `apps-and-oems`, `hkmc-cluster-tbt`, `hkmc-extras`, `sources`). |

Mapping workflow: `docs/mapping-new-firmware.md`; HMG-API reference pins: `UPSTREAM.md` and `tools/upstream-diff.sh`.
