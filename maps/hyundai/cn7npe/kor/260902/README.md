# Hyundai Avante N (CN7NPE) KOR 260902

The bundle maps 350 of 350 catalogue points, including the optional
`dipo.carplay.telephony`. Every name and all 18 stock MD5s were resolved on
2026-11-17 with our host mapper (`tools/map-car.py`, baksmali 2.5.2) from stock
files the owner collected read-only from the car with a USB script:
`ro.build.product` `CN7NPE.KOR.0000.V039.001.260902`, incremental
`eng.vmadmin.20260902.185204`, onebin `cn7npe_kr`, Android 4.4.2, Telechips
tcc803x. The collection receipt matched the MD5 of every copied file on the car,
and the 18 hashes equal the ones the car reported in its own map export.

Host mapping needs all 16 `BOOTCLASSPATH` members of this firmware for the
baksmali deodex, not only the 18 catalogue files.

346 of the 350 entries equal the CN7 KOR 260902 bundle. The four that differ are
`btsettings.projection_helper` (class `iO` here, `iP` on CN7),
`dipo.iap2_client.manager`, `homesetting.edit_list.items`, and
`dipo.carplay.telephony`, which the CN7 bundle does not map.

The car's own `map run` on HMG-Seogaemo 0.1.55 kept an incomplete candidate:
it took `btsettings.projection_helper` as `iP`, so the four
`btsettings.projection_helper.*` methods found 0 matches, and
`panel.test_gate.on` had 3 candidates. The host mapper resolves all five
uniquely (`iO.ih`, `iO.a`, `iO.aj`, `iO.aQ`, `pB`); the other 344 points equal
the car's candidate.

No point has on-car reflection yet. Reflection is not a feature test.

Per-firmware facts: the stock `featurexml.cfg` of `cn7npe_kr` contains the three
wireless permission removal lines that `wireless-carplay-and-aa` claims, so its
`owns_lines` apply on this firmware. The stock `/system/bin/app_process` MD5 is
`33f798115689d1859e8d2159dc88e7dc`, the same build as CN7 KOR and Ioniq 5 KOR
`260902`.

[evidence.json](evidence.json) records the host mapping observation. The two
`framework.window_manager_service` points bind to `/system/framework/services.odex`,
a boot classpath member that `car.json` does not hash; the sidecar records its MD5. See the
generated [catalogue coverage](../../../../../docs/hookpoints.md).
