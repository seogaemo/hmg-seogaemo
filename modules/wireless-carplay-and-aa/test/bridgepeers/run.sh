#!/bin/sh
# Pure tests of the two-phone decisions (BridgePeers, ProjectionSwitch) and the single-phone replay of the bridge's sequences.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D="$HERE/../../payload/src/hmgapi/mods/wireless/dipo"
cp "$D/BridgePeers.java.src" "$T/BridgePeers.java"
cp "$D/ProjectionSwitch.java.src" "$T/ProjectionSwitch.java"
javac --release 7 -Xlint:-options -d "$T/classes" "$T/BridgePeers.java" "$T/ProjectionSwitch.java" "$HERE/BridgePeersTest.java" "$HERE/BridgeReplayTest.java"
java -cp "$T/classes" hmgapi.mods.wireless.dipo.BridgePeersTest
java -cp "$T/classes" hmgapi.mods.wireless.dipo.BridgeReplayTest
