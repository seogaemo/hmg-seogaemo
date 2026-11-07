#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$HERE/../../payload/src/hmgapi/mods/wireless/dipo/ProjectionOwner.java.src" "$T/ProjectionOwner.java"
javac --release 7 -Xlint:-options -d "$T/classes" "$T/ProjectionOwner.java" "$HERE/ProjectionOwnerTest.java"
java -cp "$T/classes" hmgapi.mods.wireless.dipo.ProjectionOwnerTest
