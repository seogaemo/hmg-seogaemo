#!/bin/sh
# Host test of the CarPlay (dipo/CpTurns) and Android Auto (AaTurns) turn-by-turn with stand-ins for Android, Cluster/Car and Dipo.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PAY=$HERE/../../payload
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/hmgapi/mods/wireless/dipo" "$T/src/com/tcc/iap2" "$T/out"
cp "$PAY/src/hmgapi/mods/wireless/dipo/CpTurns.java.src" "$T/src/hmgapi/mods/wireless/dipo/CpTurns.java"
cp "$PAY/src/hmgapi/mods/wireless/dipo/CpLaneDecoder.java.src" "$T/src/hmgapi/mods/wireless/dipo/CpLaneDecoder.java"
cp "$PAY/src/hmgapi/mods/wireless/dipo/CpGuidance.java.src" "$T/src/hmgapi/mods/wireless/dipo/CpGuidance.java"
cp "$PAY/src/hmgapi/mods/wireless/dipo/CpJunctions.java.src" "$T/src/hmgapi/mods/wireless/dipo/CpJunctions.java"
cp "$PAY/src/hmgapi/mods/wireless/dipo/CpJunctionTable.java.src" "$T/src/hmgapi/mods/wireless/dipo/CpJunctionTable.java"
cp "$PAY/src/hmgapi/mods/wireless/dipo/CpLaneFrame.java.src" "$T/src/hmgapi/mods/wireless/dipo/CpLaneFrame.java"
cp "$PAY/src/hmgapi/mods/wireless/dipo/NowPlaying.java.src" "$T/src/hmgapi/mods/wireless/dipo/NowPlaying.java"
cp "$PAY/src/hmgapi/mods/wireless/AaTurns.java.src" "$T/src/hmgapi/mods/wireless/AaTurns.java"
cp "$PAY/src/hmgapi/mods/wireless/AaGuidance.java.src" "$T/src/hmgapi/mods/wireless/AaGuidance.java"
cp "$PAY/stubs/com/tcc/iap2/Iap2NotiMsg.java.src" "$T/src/com/tcc/iap2/Iap2NotiMsg.java"
javac --release 8 -Xlint:-options -nowarn -d "$T/out" \
    $(find "$HERE/stubs" "$HERE/test" "$HERE/aaturns/stubs" -name '*.java') $(find "$T/src" -name '*.java')
java -cp "$T/out" hmgapi.mods.wireless.dipo.CpTurnsTest

java -cp "$T/out" hmgapi.mods.wireless.dipo.CpLaneDecoderTest
java -cp "$T/out" hmgapi.mods.wireless.dipo.CpGuidanceTest
java -cp "$T/out" hmgapi.mods.wireless.dipo.CpJunctionsTest
java -cp "$T/out" hmgapi.mods.wireless.dipo.CpJunctionLifecycleTest
java -cp "$T/out" hmgapi.mods.wireless.AaTurnsTest
java -cp "$T/out" hmgapi.mods.wireless.dipo.NowPlayingTest
