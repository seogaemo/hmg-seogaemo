#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$HERE/../../payload/src/hmgapi/mods/wireless/ProjectionDelete.java.src" "$T/ProjectionDelete.java"
javac --release 7 -Xlint:-options -d "$T/classes" "$T/ProjectionDelete.java" "$HERE/ProjectionDeleteTest.java"
java -cp "$T/classes" hmgapi.mods.wireless.ProjectionDeleteTest
