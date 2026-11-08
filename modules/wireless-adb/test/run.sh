#!/bin/sh
set -eu

module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$module_dir/../.." && pwd)
car_shell=${HMG_SEOGAEMO_TEST_SHELL:-$(command -v mksh || command -v sh)}
export HMG_SEOGAEMO_TEST_COMMON="$repo/nemesis/package/lib/common.sh"
. "$HMG_SEOGAEMO_TEST_COMMON"
tmp=$(mktemp -d "$module_dir/test/.tmp.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/base/lib" "$tmp/bin" "$tmp/props" "$tmp/state" "$tmp/baseline" "$tmp/applied" "$tmp/interfaces"

cat > "$tmp/base/lib/common.sh" <<'EOF'
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_log() { :; }
sg_prop_baseline() {
    key=$1
    if [ -f "$FAKE_ROOT/baseline/build-product" ]; then
        [ "$(cat "$FAKE_ROOT/baseline/build-product")" = "$(getprop ro.build.product)" ] || return 3
    else
        getprop ro.build.product > "$FAKE_ROOT/baseline/build-product"
    fi
    [ -f "$FAKE_ROOT/baseline/$key.saved" ] && return 0
    if [ -f "$FAKE_ROOT/props/$key" ]; then
        cp "$FAKE_ROOT/props/$key" "$FAKE_ROOT/baseline/$key.value"
        sg_write "present" > "$FAKE_ROOT/baseline/$key.saved"
    else
        sg_write "absent" > "$FAKE_ROOT/baseline/$key.saved"
    fi
}
sg_prop_set() {
    sg_prop_baseline "$1" || return $?
    setprop "$1" "$2"
    [ "$(getprop "$1")" = "$2" ] || return 1
    sg_write "$2" > "$FAKE_ROOT/applied/$1"
}
sg_applied() {
    [ -f "$FAKE_ROOT/applied/$1" ] &&
        [ "$(getprop "$1")" = "$(cat "$FAKE_ROOT/applied/$1")" ]
}
sg_revert_all() {
    [ -f "$FAKE_ROOT/baseline/build-product" ] || return 0
    [ "$(cat "$FAKE_ROOT/baseline/build-product")" = "$(getprop ro.build.product)" ] || return 3
    for key in persist.adb.tcp.port persist.service.adb.tcp.enable; do
        [ -f "$FAKE_ROOT/baseline/$key.saved" ] || continue
        live=$(getprop "$key")
        applied=$(cat "$FAKE_ROOT/applied/$key" 2>/dev/null) || applied=
        case "$(cat "$FAKE_ROOT/baseline/$key.saved")" in
            present) original=$(cat "$FAKE_ROOT/baseline/$key.value") ;;
            absent) original= ;;
        esac
        [ "$live" = "$applied" ] || [ "$live" = "$original" ] || return 3
    done
    for key in persist.adb.tcp.port persist.service.adb.tcp.enable; do
        [ -f "$FAKE_ROOT/baseline/$key.saved" ] || continue
        case "$(cat "$FAKE_ROOT/baseline/$key.saved")" in
            present) cp "$FAKE_ROOT/baseline/$key.value" "$FAKE_ROOT/props/$key" ;;
            absent) rm -f "$FAKE_ROOT/props/$key" ;;
        esac
    done
    rm -f "$FAKE_ROOT/baseline/build-product" \
        "$FAKE_ROOT/baseline/persist.adb.tcp.port.saved" \
        "$FAKE_ROOT/baseline/persist.adb.tcp.port.value" \
        "$FAKE_ROOT/baseline/persist.service.adb.tcp.enable.saved" \
        "$FAKE_ROOT/baseline/persist.service.adb.tcp.enable.value" \
        "$FAKE_ROOT/applied/persist.adb.tcp.port" \
        "$FAKE_ROOT/applied/persist.service.adb.tcp.enable"
}
sg_service_restart() {
    [ "$1" = adbd ] || return 1
    setprop ctl.restart "$1" || return $?
    sg_write running > "$FAKE_ROOT/props/init.svc.adbd"
    sg_print "0: 00000000:15B3 00000000:0000 0A" > "$FAKE_ROOT/tcp"
}
sg_owner_present() { [ -f "$FAKE_ROOT/owner-$1" ]; }
sg_status() {
    case "$1" in
        conflict) code=3 ;; incompatible) code=4 ;; failed) code=1 ;; *) code=0 ;;
    esac
    sg_print "state=$1" "restart=$2" "detail=${3:-}"
    return "$code"
}
EOF
cat > "$tmp/bin/getprop" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
[ -f "$FAKE_ROOT/props/$1" ] && cat "$FAKE_ROOT/props/$1"
exit 0
EOF
cat > "$tmp/bin/setprop" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_print "$1 $2" >> "$FAKE_ROOT/calls"
if [ "$1" = ctl.restart ] && [ -f "$FAKE_ROOT/fail-restart" ]; then exit 1; fi
if [ "$1" != ctl.restart ]; then sg_write "$2" > "$FAKE_ROOT/props/$1"; fi
EOF
cat > "$tmp/bin/ifconfig" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
[ -f "$FAKE_ROOT/interfaces/$1" ] || exit 1
cat "$FAKE_ROOT/interfaces/$1"
EOF
cat > "$tmp/bin/netcfg" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
cat "$FAKE_ROOT/netcfg" 2>/dev/null || true
EOF
chmod +x "$tmp/bin/"*

# The child module sees only KitKat-available commands. Forbidden names are
# present as failing stubs so a swallowed command failure is still detected.
mkdir -p "$tmp/restricted-bin"
for name in getprop setprop ifconfig netcfg; do
    ln -s "$tmp/bin/$name" "$tmp/restricted-bin/$name"
done
for name in dd cat cp rm sleep grep; do
    ln -s "$(command -v "$name")" "$tmp/restricted-bin/$name"
done
ln -s "$repo/tools/testlib/fakebin/md5" "$tmp/restricted-bin/md5"
ln -s "$(command -v python3)" "$tmp/restricted-bin/python3"
cat > "$tmp/bin/forbidden" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_print "${0##*/}" >> "$FAKE_ROOT/forbidden-calls"
exit 99
EOF
chmod +x "$tmp/bin/forbidden"
for name in awk sed tail head cut tr wc sort uniq xargs find stat readlink \
    sha256sum sha1sum tar unzip busybox toybox; do
    ln -s "$tmp/bin/forbidden" "$tmp/restricted-bin/$name"
done
export FAKE_ROOT="$tmp" HMG_SEOGAEMO_BASE="$tmp/base" HMG_SEOGAEMO_STATE="$tmp/state"
script="$tmp/wireless-adb.sh"
python3 - "$module_dir/module.sh" "$script" "$tmp" <<'PYFIXTURE'
from pathlib import Path
import sys
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('/proc/net/tcp6', sys.argv[3]+'/tcp6').replace('/proc/net/tcp', sys.argv[3]+'/tcp'))
PYFIXTURE

run() { PATH="$tmp/restricted-bin" "$car_shell" "$script" "$1" > "$tmp/output"; }
has() { grep -q -F "$1" "$tmp/output" || { cat "$tmp/output"; exit 1; }; }
restarts() { count=$(grep -c '^ctl.restart adbd$' "$tmp/calls" 2>/dev/null) || count=0; sg_write "$count"; }
assert_count() { [ "$(restarts)" = "$1" ] || { cat "$tmp/calls"; exit 1; }; }
reset() {
    rm -f "$tmp/props/"* "$tmp/baseline/"* "$tmp/applied/"* "$tmp/state/"* "$tmp/interfaces/"* \
        "$tmp/owner-"* "$tmp/fail-restart" "$tmp/calls" "$tmp/netcfg"
    : > "$tmp/calls"
    sg_print "0: 00000000:15B3 00000000:0000 0A" > "$tmp/tcp"
    : > "$tmp/tcp6"
    sg_write running > "$tmp/props/init.svc.adbd"
    sg_write "19" > "$tmp/props/ro.build.version.sdk"
    sg_write "TEST.KOR.0000.V001.001.270101" > "$tmp/props/ro.build.product"
}
# The car gate needs a map for the exact firmware; this one is not the Ioniq 5.
mkdir -p "$tmp/base/maps/test/car/kor/270101"
sg_print '{"product": "TEST.KOR.0000.V001.001.270101"}' > "$tmp/base/maps/test/car/kor/270101/car.json"

reset
sg_write "WRONG.KOR.0000.V001.001.270101" > "$tmp/props/ro.build.product"
if run apply; then exit 1; fi
has 'state=incompatible'
[ ! -e "$tmp/props/persist.adb.tcp.port" ]

reset
sg_print "wlan0 Link encap:Ethernet inet addr:192.168.0.1 Bcast:192.168.0.255" > "$tmp/interfaces/wlan0"
run status
has 'state=off'
has 'info.hotspot_ip=192.168.0.1'
has 'info.adb_endpoint=192.168.0.1:5555'
! grep -q 'info.hotspot_ssid=' "$tmp/output"
run precheck
! grep -q '^warn\.' "$tmp/output"
run apply
has 'state=on'
[ "$(cat "$tmp/props/persist.service.adb.tcp.enable")" = 0 ]
[ "$(cat "$tmp/props/persist.adb.tcp.port")" = 5555 ]
assert_count 1
run apply
assert_count 1
run revert
has 'state=off'
[ ! -e "$tmp/props/persist.service.adb.tcp.enable" ]
[ ! -e "$tmp/props/persist.adb.tcp.port" ]
assert_count 2

reset
run apply
sg_write "TEST.KOR.0000.V001.001.270102" > "$tmp/props/ro.build.product"
if run revert; then exit 1; fi
has 'state=conflict'
[ "$(cat "$tmp/props/persist.adb.tcp.port")" = 5555 ]
[ -f "$tmp/baseline/build-product" ]

reset
sg_write "" > "$tmp/props/persist.service.adb.tcp.enable"
sg_write "5555" > "$tmp/props/persist.adb.tcp.port"
run apply
assert_count 0
run revert
[ -f "$tmp/props/persist.service.adb.tcp.enable" ]
[ ! -s "$tmp/props/persist.service.adb.tcp.enable" ]
[ "$(cat "$tmp/props/persist.adb.tcp.port")" = 5555 ]
assert_count 0

reset
: > "$tmp/owner-nemesis-adb-tcp"
if run apply; then exit 1; fi
has 'state=conflict'
[ ! -e "$tmp/props/persist.adb.tcp.port" ]

reset
run apply
sg_write "6000" > "$tmp/props/persist.adb.tcp.port"
if run revert; then exit 1; fi
has 'state=conflict'
[ -f "$tmp/baseline/persist.adb.tcp.port.saved" ]
[ "$(cat "$tmp/props/persist.adb.tcp.port")" = 6000 ]

reset
sg_write "20" > "$tmp/props/ro.build.version.sdk"
if run apply; then exit 1; fi
has 'state=incompatible'
[ ! -e "$tmp/props/persist.adb.tcp.port" ]

reset
sg_print "eth0 inet addr:192.168.0.123 Mask:255.255.255.0" > "$tmp/interfaces/eth0"
run apply
has 'state=pending-restart'
has 'restart=head_unit'
run revert

reset
sg_write "7777" > "$tmp/props/service.adb.tcp.port"
if run apply; then exit 1; fi
has 'state=conflict'

reset
: > "$tmp/fail-restart"
if run apply; then exit 1; fi
has 'state=failed'
[ ! -e "$tmp/props/persist.adb.tcp.port" ]
rm -f "$tmp/fail-restart"
run revert

reset
sg_print "wlan0 UP 10.0.0.23/24 0x00001043 00:00:00:00:00:00" > "$tmp/netcfg"
run status
has 'info.client_ip=10.0.0.23'
has 'info.client_adb_endpoint=10.0.0.23:5555'
[ ! -e "$tmp/forbidden-calls" ] || { cat "$tmp/forbidden-calls"; exit 1; }


reset
run apply
sg_write 7777 > "$tmp/props/service.adb.tcp.port"
if run status; then exit 1; fi
has 'state=conflict'
has 'overrides port 5555'
has 'info.effective_port=7777'
sg_write 5555 > "$tmp/props/service.adb.tcp.port"
run status
has 'state=on'
sg_write stopped > "$tmp/props/init.svc.adbd"
if run status; then exit 1; fi
has 'state=failed'
has 'adbd stopped'
has 'info.adbd_state=stopped'
run apply
has 'state=on'
assert_count 2
run apply
assert_count 2

: > "$tmp/tcp"
if run status; then exit 1; fi
has 'info.adb_listener=absent'
has 'not listening'
run apply
has 'info.adb_listener=listening'
assert_count 3
: > "$tmp/tcp"
sg_print '0: 00000000000000000000000000000000:15B3 00000000:0000 0A' > "$tmp/tcp6"
run status
has 'info.adb_listener=listening'

sg_print "wireless-adb tests passed"
