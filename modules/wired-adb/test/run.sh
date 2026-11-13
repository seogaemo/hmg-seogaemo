#!/bin/sh
set -eu

module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$module_dir/../.." && pwd)
car_shell=${HMG_SEOGAEMO_TEST_SHELL:-$(command -v mksh || command -v sh)}
export HMG_SEOGAEMO_TEST_COMMON="$repo/nemesis/package/lib/common.sh"
. "$HMG_SEOGAEMO_TEST_COMMON"
tmp=$(mktemp -d "$module_dir/test/.tmp.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/base/lib" "$tmp/bin" "$tmp/props" "$tmp/data/modules/wired-adb" "$tmp/data/desired" \
    "$tmp/payload/files" "$tmp/net" "$tmp/dev/net" "$tmp/apps" "$tmp/usb0/HSM" "$tmp/usb1"

# The runtime's transient API is covered by tools/test-transient.py; here it is a recorder.
cat > "$tmp/base/lib/common.sh" <<'FAKE'
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_log() { sg_print "log $*" >> "$FAKE_ROOT/calls"; }
sg_car_mapped() { [ -f "$FAKE_ROOT/car-map" ]; }
sg_daemon_running() { [ -f "$FAKE_ROOT/daemon-running" ]; }
sg_daemon_start() {
    sg_print "start $1" >> "$FAKE_ROOT/calls"
    if [ -f "$FAKE_ROOT/start-code" ]; then return "$(cat "$FAKE_ROOT/start-code")"; fi
    : > "$FAKE_ROOT/daemon-running"
}
sg_daemon_restart() {
    sg_print "restart $1" >> "$FAKE_ROOT/calls"
    [ ! -f "$FAKE_ROOT/fail-restart" ]
}
sg_revert_transient() { sg_print revert-transient >> "$FAKE_ROOT/calls"; rm -f "$FAKE_ROOT/daemon-running"; }
sg_revert_all() {
    sg_print revert-all >> "$FAKE_ROOT/calls"
    [ ! -f "$FAKE_ROOT/fail-revert" ] || return 3
    rm -f "$FAKE_ROOT/daemon-running"
}
sg_status() {
    case "$1" in
        conflict) code=3 ;; incompatible) code=4 ;; failed) code=1 ;; *) code=0 ;;
    esac
    sg_print "state=$1" "restart=$2" "detail=${3:-}"
    return "$code"
}
FAKE
cat > "$tmp/bin/getprop" <<'FAKE'
#!/bin/sh
[ -f "$FAKE_ROOT/props/$1" ] && cat "$FAKE_ROOT/props/$1"
exit 0
FAKE
chmod +x "$tmp/bin/getprop"

# The module sees only KitKat-available commands (rm serves the recorder above; the module
# itself may not call it, see tools/lint-module-root.py). Forbidden names are failing stubs,
# so a swallowed command failure is still detected.
mkdir -p "$tmp/restricted-bin"
ln -s "$tmp/bin/getprop" "$tmp/restricted-bin/getprop"
for name in cat chmod dd ls mkdir rm; do
    ln -s "$(command -v "$name")" "$tmp/restricted-bin/$name"
done
cat > "$tmp/bin/forbidden" <<'FAKE'
#!/bin/sh
echo "${0##*/}" >> "$FAKE_ROOT/forbidden-calls"
exit 99
FAKE
chmod +x "$tmp/bin/forbidden"
for name in awk sed tail head cut tr wc sort uniq xargs find stat readlink printf \
    sha256sum sha1sum tar unzip busybox toybox base64 mv cp; do
    ln -s "$tmp/bin/forbidden" "$tmp/restricted-bin/$name"
done

state=$tmp/data/modules/wired-adb
export FAKE_ROOT="$tmp" HMG_SEOGAEMO_BASE="$tmp/base" HMG_SEOGAEMO_STATE="$state" \
    HMG_SEOGAEMO_MODULE_DIR="$tmp/payload" SG_DATA_ROOT="$tmp/data" SG_SYS_NET_ROOT="$tmp/net" \
    SG_DEV_ROOT="$tmp/dev" SG_NEMESIS_APPS="$tmp/apps" SG_USB_DIRS="$tmp/usb1 $tmp/usb0"

run() {
    code=0
    PATH="$tmp/restricted-bin" "$car_shell" "$module_dir/module.sh" "$@" > "$tmp/output" || code=$?
}
expect() { [ "$code" -eq "$1" ] || { echo "exit $code, expected $1"; cat "$tmp/output"; exit 1; }; }
has() { grep -q -F -x -- "$1" "$tmp/output" || { echo "missing: $1"; cat "$tmp/output"; exit 1; }; }
lacks() { ! grep -q -F -- "$1" "$tmp/output" || { echo "unexpected: $1"; cat "$tmp/output"; exit 1; }; }
called() { grep -q -F -x -- "$1" "$tmp/calls" || { echo "not called: $1"; cat "$tmp/calls"; exit 1; }; }
count() { grep -c -F -x -- "$1" "$tmp/calls" || true; }
reset() {
    rm -rf "$state" "$tmp/net/sgncm0" "$tmp/apps/cn7.mac.cable" "$tmp/usb0/HSM" "$tmp/usb1/HSM"
    rm -f "$tmp/daemon-running" "$tmp/start-code" "$tmp/fail-restart" "$tmp/fail-revert" "$tmp/data/desired/wired-adb"
    mkdir -p "$state" "$tmp/usb0/HSM"
    : > "$tmp/calls"
    : > "$tmp/car-map"
    : > "$tmp/dev/net/tun"
    : > "$tmp/payload/files/cable-link"
    : > "$tmp/payload/files/cable-adbd"
    sg_write 19 > "$tmp/props/ro.build.version.sdk"
}
key() { python3 -c "import sys; print(sys.argv[1] * 699 + '=', end='')" "$1"; }
key_a=$(key A)
key_b=$(key b)
usb_key=$tmp/usb0/HSM/adbkey.pub

# Gates: car map, Android release, TUN device, payload, the standalone package.
reset
rm -f "$tmp/car-map"
run status; expect 4; has state=incompatible
reset
sg_write 23 > "$tmp/props/ro.build.version.sdk"
run apply; expect 4; [ "$(count 'start cable-link')" = 0 ]
reset
rm -f "$tmp/dev/net/tun"
run status; expect 4; has 'detail=This unit has no TUN device'
: > "$tmp/dev/tun"
run status; expect 0; has state=off
rm -f "$tmp/dev/tun"
reset
rm -f "$tmp/payload/files/cable-adbd"
run apply; expect 1; has 'detail=Missing payload files/cable-adbd'
reset
mkdir -p "$tmp/apps/cn7.mac.cable"
run apply; expect 3; has state=conflict; [ "$(count 'start cable-link')" = 0 ]

# Off, then on without a key: the service runs and asks for a key.
reset
run status; expect 0; has state=off; has info.key_count=0; has info.no_key=1; has info.link=waiting
run precheck; expect 0; has state=off
run apply; expect 0; has state=on; has 'detail=Import an ADB key from USB to connect'; has info.no_key=1
called 'start cable-link'

# Import: nothing on USB, a symlink, then a real file with a labelled key and a CRLF key.
run action import_key; expect 1; has 'detail=No HSM/adbkey.pub on a USB drive'
ln -s "$tmp/calls" "$usb_key"
run action import_key; expect 1; has 'detail=No HSM/adbkey.pub on a USB drive'
rm -f "$usb_key"
python3 - "$usb_key" "$key_a" "$key_b" <<'PY'
import sys
open(sys.argv[1], 'wb').write((sys.argv[2] + ' dev@laptop\n\n' + sys.argv[3] + '\r\n').encode())
PY
run action import_key; expect 0; has state=on; has 'detail=ADB keys imported: 2'; has info.key_count=2; has info.has_key=1
lacks info.no_key
called 'restart cable-link'
python3 - "$state/adb_keys" "$key_a" "$key_b" <<'PY'
import os, sys
assert open(sys.argv[1], 'rb').read() == (sys.argv[2] + ' dev@laptop\n' + sys.argv[3] + '\n').encode()
assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o600
PY
run status; expect 0; has 'detail=Waiting for a Mac on the USB port'; has info.link=waiting
mkdir -p "$tmp/net/sgncm0"
run status; expect 0; has 'detail=Mac connected; ADB on port 5556'; has info.link=up
has info.endpoint=192.168.2.249:5556; has info.endpoint6=fe80::c7ad:b

# The label is dropped when it is not plain; a file without a trailing newline still counts.
python3 - "$usb_key" "$key_b" <<'PY'
import sys
open(sys.argv[1], 'wb').write((sys.argv[2] + ' $(reboot);x@y more words').encode())
PY
run action import_key; expect 0; has info.key_count=1
python3 - "$state/adb_keys" "$key_b" <<'PY'
import sys
assert open(sys.argv[1], 'rb').read() == (sys.argv[2] + '\n').encode()
PY

# Refusals keep the keys already imported and leave no temporary file behind.
refused() {
    run action import_key; expect 1; has "detail=$1"
    python3 - "$state" "$key_b" <<'PY'
import os, sys
assert open(sys.argv[1] + '/adb_keys', 'rb').read() == (sys.argv[2] + '\n').encode()
assert sorted(os.listdir(sys.argv[1])) == ['adb_keys'], os.listdir(sys.argv[1])
PY
}
python3 -c "import sys; open(sys.argv[1], 'w').write(sys.argv[2][:-1] + '*\n')" "$usb_key" "$key_a"
refused 'Invalid ADB public key'
python3 -c "import sys; open(sys.argv[1], 'w').write(sys.argv[2][:600] + '\n')" "$usb_key" "$key_a"
refused 'Invalid ADB public key'
python3 -c "import sys; open(sys.argv[1], 'w').write(sys.argv[2] + 'A\n')" "$usb_key" "$key_a"
refused 'Invalid ADB public key'
python3 -c "import sys; open(sys.argv[1], 'w').write((sys.argv[2] + '\n') * 9)" "$usb_key" "$key_a"
refused 'Too many keys; 8 at most'
python3 -c "import sys; open(sys.argv[1], 'w').write((sys.argv[2] + '\n') * 12)" "$usb_key" "$key_a"
refused 'Key file is too large'
python3 -c "import sys; open(sys.argv[1], 'w').write('\n \n')" "$usb_key"
refused 'No ADB public key in the file'
python3 -c "import sys; open(sys.argv[1], 'w').write((sys.argv[2] + '\n') * 8)" "$usb_key" "$key_a"
run action import_key; expect 0; has info.key_count=8

# A failed restart is reported; removing the keys restarts the link as well.
: > "$tmp/fail-restart"
run action import_key; expect 1; has 'detail=Could not restart the cable link'
rm -f "$tmp/fail-restart"
before=$(count 'restart cable-link')
run action clear_key; expect 0; has 'detail=ADB keys removed'; has info.key_count=0; has info.no_key=1
[ "$(count 'restart cable-link')" = "$((before + 1))" ]
[ -f "$state/adb_keys" ] && [ ! -s "$state/adb_keys" ]
run action reboot; expect 2
run action; expect 2
run bogus; expect 2

# Watch restarts the service; a start failure backs the transient records out.
reset
run watch screen_on; expect 0; has state=on; called 'start cable-link'
run watch usb; expect 2
reset
sg_write 3 > "$tmp/start-code"
run apply; expect 3; has 'detail=Another module claims the cable link'; called revert-transient
reset
sg_write 1 > "$tmp/start-code"
run watch boot; expect 1; has 'detail=Could not start the cable link'; called revert-transient

# Desired on without the service is a failure; revert stops it and keeps the keys.
reset
sg_write on > "$tmp/data/desired/wired-adb"
run status; expect 1; has 'detail=Cable link is not running'
run apply; expect 0; has state=on
sg_print "$key_a" > "$state/adb_keys"
run revert; expect 0; has state=off; called revert-all; has info.key_count=1
[ ! -f "$tmp/daemon-running" ]
: > "$tmp/fail-revert"
run revert; expect 3; has state=conflict

[ ! -e "$tmp/forbidden-calls" ] || { echo 'forbidden command used:'; cat "$tmp/forbidden-calls"; exit 1; }
echo 'wired-adb module tests passed'
