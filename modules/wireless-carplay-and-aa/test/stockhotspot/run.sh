#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$HERE/../../payload/src/hmgapi/mods/wireless/StockHotspot.java.src" "$T/StockHotspot.java"
javac --release 7 -Xlint:-options -d "$T/classes" "$T/StockHotspot.java" "$HERE/StockHotspotTest.java" "$HERE"/../usbhotspot/stubs/*.java
java -cp "$T/classes" hmgapi.mods.wireless.StockHotspotTest
