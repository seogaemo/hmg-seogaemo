# Hyundai Avante N (CN7N) KOR 260319

The bundle maps 349 of 349 catalogue points. Every name and all 18 stock MD5s
were resolved on 2026-11-09 with our host mapper (`tools/map-car.py`, baksmali
2.5.2) from stock files the contributor collected read-only from the car on
2026-11-02 with a USB script: `ro.build.product` `CN7N.KOR.0000.V037.001.260319`,
incremental `eng.vmadmin.20260319.162633`, onebin `cn7n_kr`, Android 4.4.2,
Telechips tcc803x. The MD5s of the collected files equal the hashes the car
reported during collection. The contributor's separate HMG-API host mapping of the same
files agrees on all 325 IDs the two catalogues share.

The catalogue has since grown to 350 points: the optional `dipo.carplay.telephony`
(added 2026-11-10) is not mapped in this bundle and is listed under `missing` in `car.json`.

339 of the 349 entries equal the CN7 KOR 260902 bundle. The ten that differ are
`btsettings.projection_helper.device_connections_available`, the four
`launcher.menu_*` points, `panel.home.page_for_id`, `panel.home.test_page`,
`panel.test_gate`, `panel.test_gate.on` and `themesettings.split_item.type`.

No point has on-car reflection yet and HMG-Seogaemo has not been installed on
this car. Reflection is not a feature test.

Per-firmware facts: the stock `featurexml.cfg` of `cn7n_kr` contains the three
wireless permission removal lines that `wireless-carplay-and-aa` claims, so its
`owns_lines` apply on this firmware. No stock `/system/bin/app_process` MD5 is
recorded: the collection did not include `/system/bin`.

[evidence.json](evidence.json) records the host mapping observation. The two
`framework.window_manager_service` points bind to `/system/framework/services.odex`,
a boot classpath member that `car.json` does not hash; the sidecar records its MD5. See the
generated [catalogue coverage](../../../../../docs/hookpoints.md).
