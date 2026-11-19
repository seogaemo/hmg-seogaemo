# N Mode module

The release USB archive includes `HSM/cn7-n-mode-1.8.0.hsm`. Extract the USB
archive, then open the Modules tab and add N Mode from USB.
Updating from 1.7.0 requires turning the old module off first so it can restore
its original files. Restart the head unit after enabling or disabling N Mode.

The module uses Android 4.4's current onebin and changes only the exact N Mode
exclusion in that vehicle's package list. It needs a matching car map, the stock
N Mode APK and the exclusion. A vehicle whose stock menu already shows N Mode
does not need this change. The app's gauges and controls depend on the vehicle.

The optional display bridge keeps the previous CN7 profile and its checks for
the CAN service, framework, vehicle features and powertrain. Other profiles use
their own stock N Mode code. The IGPEHEV KOR 260902 firmware map identifies
Android classes and methods. IGPEHEV N Mode startup, telemetry and the splash
write have not been tested on a physical IGPEHEV.

The release contains only the difference between the original and enhanced ODEX.
Rebuild the HSD1 data with Python, bsdiff4 1.2.6 and
`tools/make-stock-delta.py STOCK ENHANCED extras/n-mode/files/display.delta.gz`.
The decoder checks both SHA-256 digests before committing the staged result.
