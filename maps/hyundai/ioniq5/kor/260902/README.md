# Hyundai Ioniq 5 KOR 260902

The bundle maps 356 of 357 catalogue points. The original 324 names and all
18 stock MD5s came from the owner-supplied KOR pre-install report; those 324
points passed on-car reflection on 2026-11-03. The 18 catalogue additions were
resolved on 2026-11-04 from the KOR stock dump using our DEX scanner, with all
18 existing MD5s matching. They still require on-car reflection. The six iAP2
points are in Iap2ServerApp.odex; the twelve framework points are in
automotive.odex. No stock files or hashes were added or changed.

Six stock-guidance points were independently resolved on 2026-11-07 with our
DEX scanner against the same exact-stock dump, without reference-map fallback:
NavigationCluster's updateTBTTrapInfo (17 ints), updateTBTTrapInfoNew
(NaviTbtTrapInfo), updateCluDataNew_14 (five ints), and NaviTbtTrapInfo's class,
no-argument constructor and instance int barGraphLevel. All six are in
automotive.odex (MD5 c76b8209ef171739b177eb14e8df61dd) and still require on-car
reflection. See UPSTREAM.md for stable IDs and exact signatures; no further
trap fields are mapped because Parcelable supports copying the stock object.

Eight CarPlay connection-owner points were resolved on 2026-11-07 from the same
KOR stock dump with the host baksmali mapper (-a 18): DiPO's CarPlayService
connect, disconnect, onCreate, onDestroy and onSessionDetails, and BtSettings'
aW class with its delete request and send-disconnect methods. Each rule matched
exactly one stock candidate. They are in HKMC_DiPO.odex (MD5 3b26cdcbf3c43f75623311f2bdfc3471)
and HKMC_BtSettings.odex (MD5 dc56bcfe68ceb54371ce7e08c1153cad), are optional,
and have host evidence only; they still need on-car reflection.

`themesettings.split_item.type` remains unresolved; no module requires it.
No new point was added to a module requirement.

[evidence.json](evidence.json) separates mapped names, exact-stock reflection
and physical feature observations without extending the runtime car schema.
The owner confirmed wireless CarPlay music, Siri and calls/mic at HMG-Seogaemo
0.1.25. Wireless Android Auto is untested. Reflection is not a feature test.
See the generated [catalogue coverage](../../../../../docs/hookpoints.md).
