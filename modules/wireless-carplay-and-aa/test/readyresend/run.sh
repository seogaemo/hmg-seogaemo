#!/bin/sh
# Host JVM test of the wireless AA ready resend (payload/src/hmgapi/mods/wireless/ReadyResend).
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/hmgapi/mods/wireless" "$T/out"
cp "$HERE/../../payload/src/hmgapi/mods/wireless/ReadyResend.java.src" "$T/src/hmgapi/mods/wireless/ReadyResend.java"
javac -source 7 -target 7 -Xlint:-options -d "$T/out" "$T/src/hmgapi/mods/wireless/ReadyResend.java" "$HERE/ReadyResendTest.java"
java -cp "$T/out" hmgapi.mods.wireless.ReadyResendTest
