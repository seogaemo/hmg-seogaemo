# Hyundai Avante (CN7) KOR 260902

The bundle maps 349 of 349 catalogue points, including
`themesettings.split_item.type`, which stays unresolved on the Ioniq 5 KOR
bundle. Every name and all 18 stock MD5s were resolved on 2026-11-09 with our
host mapper (`tools/map-car.py`, baksmali 2.5.2) from the contributor's read-only
dump of the official `260902` system image for this car. The head unit reports
`ro.build.product` `CN7.KOR.0000.V039.001.260902` (the generic `build.prop`
inside the image reads `HYUNDAI.KOR.0000.V039.001.260902`), onebin `cn7_kr`,
Android 4.4.2, Telechips tcc897x. The contributor's separate HMG-API host mapping of
the same dump agrees on all 325 IDs the two catalogues share.

The catalogue has since grown to 350 points: the optional `dipo.carplay.telephony`
(added 2026-11-10) is not mapped in this bundle and is listed under `missing` in `car.json`.

347 of the 349 entries equal the Ioniq 5 KOR bundle; `panel.test_gate.on` and
`themesettings.split_item.type` differ.

No point has on-car reflection yet and HMG-Seogaemo has not been installed on
this car. Reflection is not a feature test. The contributor reported working wireless
CarPlay on this car with HMG-API only, which says nothing about this package.

Per-firmware facts: the stock `featurexml.cfg` of `cn7_kr` contains none of the
three wireless permission removal lines that `wireless-carplay-and-aa` claims,
so on this firmware the module only adds the permission XML files. The stock
`/system/bin/app_process` MD5 is `33f798115689d1859e8d2159dc88e7dc`, the same
build as the Ioniq 5 KOR `260902`; the module declares it as a product-scoped
`stock_file`. The value comes from the decrypted firmware image, not from a car.

[evidence.json](evidence.json) records the host mapping observation. The two
`framework.window_manager_service` points bind to `/system/framework/services.odex`,
a boot classpath member that `car.json` does not hash; the sidecar records its MD5. See the
generated [catalogue coverage](../../../../../docs/hookpoints.md).
