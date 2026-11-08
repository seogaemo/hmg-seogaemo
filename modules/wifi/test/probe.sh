#!/bin/sh
# Host test of sg_wifi_probe (runtime): chip already there, woken, never appearing, Wi-Fi already
# on, and a probe cut off with Wi-Fi on. The fake svc/settings keep the Wi-Fi switch in a file.
set -eu
repo=$(CDPATH= cd "$(dirname "$0")/../../.." && pwd)
car_shell=${HMG_SEOGAEMO_TEST_SHELL:-$(command -v mksh || command -v sh)}
work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-probe.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/sdio" "$work/data"
cat > "$work/bin/settings" <<'EOS'
#!/bin/sh
[ "$1 $2 $3" = "get global wifi_on" ] || exit 1
cat "$TEST_WORK/wifi_on" 2>/dev/null || echo null
EOS
cat > "$work/bin/svc" <<'EOS'
#!/bin/sh
[ "$1" = wifi ] || exit 1
case "$2" in
    enable) echo 1 > "$TEST_WORK/wifi_on"
        # the chip shows up after TEST_WAKE_AFTER enable calls' worth of polling (0: never)
        [ "${TEST_CHIP:-0}" = 1 ] && mkdir -p "$TEST_WORK/sdio/mmc1:0001:1" ;;
    disable) echo 0 > "$TEST_WORK/wifi_on"; echo "disable" >> "$TEST_WORK/svc.log" ;;
    *) exit 1 ;;
esac
EOS
chmod +x "$work/bin/settings" "$work/bin/svc"
cat > "$work/t.sh" <<'EOS'
. "$HMG_SEOGAEMO_TEST_COMMON"
sleep() { /bin/sleep 0.3; }
sg_log() { :; }
HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/modules/wifi
EOS
run() { # run <function call...>: the runtime under the car shell with the fake tools first on PATH
    TEST_WORK=$work SG_DATA_ROOT=$work/data SG_SDIO_DIR=$work/sdio SG_WIFI_PROBE_TRIES=3 \
        HMG_SEOGAEMO_TEST_COMMON=$repo/nemesis/package/lib/common.sh PATH="$work/bin:$PATH" \
        "$car_shell" -c ". $work/t.sh; $*"
}
expect() { # expect <status> <command...>
    want=$1; shift
    set +e; "$@"; got=$?; set -e
    [ "$got" -eq "$want" ] || { echo "FAIL: '$*' returned $got, wanted $want" >&2; exit 1; }
}
marker() { cat "$work/data/wifi-chip" 2>/dev/null || echo none; }

# 1. A chip on SDIO already: nothing is touched, marker seen.
mkdir -p "$work/sdio/mmc1:0001:1"; echo 0 > "$work/wifi_on"; : > "$work/svc.log"
expect 0 run sg_wifi_probe
[ "$(marker)" = seen ] && [ ! -s "$work/svc.log" ]
rm -rf "$work/sdio/mmc1:0001:1" "$work/data/wifi-chip"

# 2. Wi-Fi off, the chip appears after enabling: marker seen, the switch is back to off.
echo 0 > "$work/wifi_on"; : > "$work/svc.log"
export TEST_CHIP=1
expect 0 run sg_wifi_probe
[ "$(marker)" = seen ] && [ "$(cat "$work/wifi_on")" = 0 ] && [ ! -e "$work/data/wifi-probe-pending" ]
grep -Fq 'wifi_probe' "$work/data/ledger/ledger.tsv"
rm -rf "$work/sdio/mmc1:0001:1" "$work/data/wifi-chip"; unset TEST_CHIP

# 3. No chip appears: marker absent, switch restored, exit 10.
echo 0 > "$work/wifi_on"
expect 10 run sg_wifi_probe
[ "$(marker)" = absent ] && [ "$(cat "$work/wifi_on")" = 0 ] && [ ! -e "$work/data/wifi-probe-pending" ]
# ...and an owner retry is allowed and does the same.
expect 10 run sg_wifi_probe

# 4. Wi-Fi already on and still no chip: no toggling at all.
echo 1 > "$work/wifi_on"; : > "$work/svc.log"; rm -f "$work/data/wifi-chip"
expect 10 run sg_wifi_probe
[ "$(cat "$work/wifi_on")" = 1 ] && [ ! -s "$work/svc.log" ]

# 5. A probe cut off with Wi-Fi on: the pending file makes the next probe put it back first.
echo 1 > "$work/wifi_on"; echo 0 > "$work/data/wifi-probe-pending"; : > "$work/svc.log"; rm -f "$work/data/wifi-chip"
expect 10 run sg_wifi_probe
[ -s "$work/svc.log" ] && [ "$(cat "$work/wifi_on")" = 0 ] && [ ! -e "$work/data/wifi-probe-pending" ]

echo 'wifi probe tests passed'
