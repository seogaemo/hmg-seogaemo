# Notices

## HMG-API

The `wireless-carplay-and-aa` module contains source adapted from [HMG-API](https://github.com/VysseCodes/HMG-API) by VysseCodes, licensed AGPL-3.0. Its Dalvik hook loader, wireless projection hooks, native patch recipes, and AAC/Opus converter are included with modifications identified in source comments. The HMG-API app, daemon, and generic mod engine are not included.

The core car mapper, verifier, host mapping workflow, and hookpoint catalogue follow HMG-API's published behavior and point definitions. They are independently implemented in HMG-Seogaemo. `UPSTREAM.md` records the pinned source paths for future comparison.

## NEMESIS

HMG-Seogaemo installs through [NEMESIS](https://github.com/xwtk/hmg_nemesis) by xwtk, licensed AGPL-3.0. NEMESIS is a required package manager and root command provider; its source is not copied into the wireless module.

## HKMC Factory 82

The `skip-consent-screen` module follows the observed behavior of [HKMC Factory 82](https://github.com/armandodollia/nemesis-package-builds) by armandodollia (MIT). HMG-Seogaemo's module, fixed Binder-call API, and shared `watcher` service are independently written; no HKMC Factory 82 source is included.

## Android Open Source Project (adbd)

The `wired-adb` module ships `cable-adbd`, built from the Android Open Source Project's `adb`, `libcutils` and `libmincrypt` (`android-4.4.4_r1`, Apache-2.0) with the changes in `modules/wired-adb/payload/adbd/cable-adbd.patch`. The upstream notices are in `modules/wired-adb/files/NOTICE.txt`. The build follows HMG-API's adbd build flags at `4fab437`; no HMG-API source is included. The `cable-link` service and the patch are adapted from a contributor's own standalone package.

## HMG Leafia Plus and Xposed

HMG-API credits [HMG Leafia Plus](https://github.com/VysseCodes/HMG-Leafia-Plus) for the original wireless CarPlay bridge, native patch recipes, and audio converter lineage. HMG-API's Dalvik hook design follows Xposed for Android 4.x; no Xposed source is included here. See HMG-API's upstream `NOTICE.md` for its attributions.

The combined project is licensed under GNU AGPL-3.0; see `LICENSE`. Distribution must include its Corresponding Source.
