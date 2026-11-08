Compile-time signatures of the head unit's libraries that this mod's DiPO part
(`hmgapi.mods.wireless.dipo`) links against: `com.tcc.iap2` (the iAP2 server's
client API), `com.broadcom.bt` (Broadcom's Bluetooth connection manager) and
`android.phoneprojection.IPPActionListener` (framework: Phone Projection's requests), and
`android.phoneprojection.IWLDeviceListener` with `WLDeviceInfo` (BtSettings' device status listener; the
btsettings part reads WLDeviceInfo by reflection).
Our own declarations, written to match the car's method names and types; only the
members the mod uses. `build.sh` compiles them onto the class path and leaves them
out of hooks.jar: on the car the real library classes load from DiPO's class loader.
The iAP2 message classes hold data, so the off-car tests can build messages with them.
