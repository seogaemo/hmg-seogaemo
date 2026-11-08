#!/bin/sh
set -eu

repo=$(CDPATH= cd "$(dirname "$0")/../../.." && pwd)
module=$repo/modules/wifi
car_shell=${HMG_SEOGAEMO_TEST_SHELL:-$(command -v mksh || command -v sh)}
python=$(command -v python3)
export HMG_SEOGAEMO_TEST_COMMON="$repo/nemesis/package/lib/common.sh"
. "$HMG_SEOGAEMO_TEST_COMMON"
work=$(mktemp -d "${TMPDIR:-/tmp}/wifi-test.XXXXXX")
# Physical path: the runtime refuses symlinked state paths (macOS /var, /tmp).
work=$(cd "$work" && pwd -P)
stop_daemons() {
    for proc in "$work"/proc/[0-9]*; do
        [ -d "$proc" ] || continue
        kill -9 "${proc##*/}" 2>/dev/null || :
    done
}
trap 'stop_daemons; rm -rf "$work"' EXIT HUP INT TERM

# The shipped drivers are the build outputs listed in files/kmod/SHA256SUMS.
"$python" - "$module/files/kmod" "$repo/kernel/usb-wifi/out/SHA256SUMS" <<'EOF'
import hashlib, pathlib, sys
kmod = pathlib.Path(sys.argv[1])
listed = dict(reversed(line.split()) for line in (kmod / "SHA256SUMS").read_text().splitlines())
shipped = {p.relative_to(kmod).as_posix() for p in kmod.rglob("*.ko")}
assert set(listed) == shipped, (listed, shipped)
for name, digest in listed.items():
    assert hashlib.sha256((kmod / name).read_bytes()).hexdigest() == digest, name
    assert b"vermagic=3.18.24-tcc SMP preempt mod_unload ARMv7 p2v8" in (kmod / name).read_bytes(), name
build = pathlib.Path(sys.argv[2])
if build.is_file():
    assert listed == dict(reversed(line.split()) for line in build.read_text().splitlines()), "kmod differs from build"
EOF

data=$work/data
state=$data/modules/wifi
mkdir -p "$work/base/lib" "$work/bin" "$work/system/wifi" "$work/system/etc/permissions" \
    "$work/sys/class/net" "$work/sys/bus/usb/devices" "$work/proc/sys/kernel" "$work/kernel" \
    "$work/tools/system/bin" "$work/inbox" "$data/installed" "$data/settings/wifi" "$data/desired" "$work/props"
xml=$work/system/etc/permissions/android.hardware.wifi.xml
cp "$module/module.properties" "$data/installed/wifi.properties"
sg_print wifi > "$data/installed.list"
: > "$work/base/modules.list"
: > "$work/proc/modules"
sg_print 3.18.24-tcc > "$work/proc/sys/kernel/osrelease"
sg_print boot-a > "$work/boot_id"
sg_print 6f1d2e3c-4b5a-4968-8776-a5b4c3d2e1f0 > "$work/uuid"
# Supported stock capability remains present while SDIO/WLAN are powered off.
sg_print broadcom > "$work/vendor"
sg_print driver > "$work/system/wifi/bcmdhd.ko"
sg_print firmware > "$work/system/wifi/fw_bcmdhd.bin"
sg_print NEEV.KOR.0000.V039.001.260902 > "$work/product"
: > "$work/owners"
: > "$work/pm-feature"

cat > "$work/base/lib/common.sh" <<'EOF'
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_log() { :; }
# Daemon start/stop polls and the scan wait keep their retry counts; each step is
# shortened (mksh's builtin sleep cannot be replaced through PATH).
sleep() { /bin/sleep 0.25; }
sg_snapshot() {
    name=${1##*/}
    if [ ! -e "$HMG_SEOGAEMO_STATE/$name.saved" ] && [ ! -e "$HMG_SEOGAEMO_STATE/$name.absent" ]; then
        if [ -e "$1" ]; then cp -p "$1" "$HMG_SEOGAEMO_STATE/$name.saved";
        else : > "$HMG_SEOGAEMO_STATE/$name.absent"; fi
    fi
}
sg_mark() {
    name=${1##*/}
    cp -p "$1" "$HMG_SEOGAEMO_STATE/$name.applied"
    sg_print "$name" >> "$TEST_WORK/marks"
}
sg_applied() {
    case "$1" in
        /*) name=${1##*/}
            [ -f "$HMG_SEOGAEMO_STATE/$name.applied" ] && [ -f "$1" ] &&
                cmp -s "$HMG_SEOGAEMO_STATE/$name.applied" "$1" ;;
        *) [ -f "$HMG_SEOGAEMO_STATE/prop.$1.applied" ] &&
            [ "$(getprop "$1")" = "$(cat "$HMG_SEOGAEMO_STATE/prop.$1.applied")" ] ;;
    esac
}
sg_prop_set() {
    [ "$1" = persist.wifi.state ] || return 2
    [ ! -e "$TEST_WORK/fail-prop" ] || return 1
    if [ ! -f "$HMG_SEOGAEMO_STATE/prop.$1.live" ]; then
        getprop "$1" > "$HMG_SEOGAEMO_STATE/prop.$1.live"
    fi
    setprop "$1" "$2" || return 1
    sg_print "$2" > "$HMG_SEOGAEMO_STATE/prop.$1.applied"
    sg_print "prop.$1" >> "$TEST_WORK/marks"
}
sg_file_put() {
    [ "$3" = 0644 ] && [ "$4" = root:root ] || return 1
    sg_ready || return 1
    sg_snapshot "$1" || return 1
    cp -p "$HMG_SEOGAEMO_MODULE_DIR/$2" "$1" || return 1
    sg_mark "$1"
}
# Files and properties are faked; transient effects go through the real runtime.
sg_revert_all() {
    sg_revert_transient || return $?
    path=$TEST_WORK/system/etc/permissions/android.hardware.wifi.xml
    name=${path##*/}
    if [ -f "$HMG_SEOGAEMO_STATE/$name.saved" ] || [ -f "$HMG_SEOGAEMO_STATE/$name.absent" ]; then
        if [ ! -f "$HMG_SEOGAEMO_STATE/$name.absent" ] || [ -e "$path" ]; then sg_applied "$path" || return 1; fi
        if [ -f "$HMG_SEOGAEMO_STATE/$name.saved" ]; then cp -p "$HMG_SEOGAEMO_STATE/$name.saved" "$path";
        else rm -f "$path"; fi
    fi
    prop=persist.wifi.state
    if [ -f "$HMG_SEOGAEMO_STATE/prop.$prop.live" ]; then
        current=$(getprop "$prop")
        [ "$current" = "$(cat "$HMG_SEOGAEMO_STATE/prop.$prop.live")" ] || sg_applied "$prop" || return 1
        setprop "$prop" "$(cat "$HMG_SEOGAEMO_STATE/prop.$prop.live")" || return 1
    fi
    [ ! -e "$TEST_WORK/fail-clear" ] || return 1
    rm -f "$HMG_SEOGAEMO_STATE"/*.saved "$HMG_SEOGAEMO_STATE"/*.absent "$HMG_SEOGAEMO_STATE"/*.applied "$HMG_SEOGAEMO_STATE"/*.live
}
sg_owner_present() { grep -Fxq "$1" "$TEST_WORK/owners"; }
sg_status() {
    sg_print "state=$1" "restart=$2" "detail=${3:-}"
    case "$1" in conflict) return 3;; incompatible) return 4;; failed) return 1;; esac
    return 0
}
EOF
cat > "$work/bin/getprop" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
case "$1" in ro.build.product) cat "$TEST_WORK/product";; init.svc.hostapd) cat "$TEST_WORK/hostapd" 2>/dev/null || :;;
    tcc.wifi.vendor) cat "$TEST_WORK/vendor";; ro.board.platform) sg_print tcc803x;;
    persist.wifi.state) cat "$TEST_WORK/props/$1" 2>/dev/null || sg_print "";; esac
EOF
cat > "$work/bin/setprop" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
[ "$1" = persist.wifi.state ] || { echo "unexpected setprop $1" >&2; exit 1; }
sg_print "$2" > "$TEST_WORK/props/$1"
EOF
cat > "$work/bin/dmesg" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
cat "$TEST_WORK/dmesg" 2>/dev/null || :
EOF
cat > "$work/bin/pm" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
[ "$*" = 'list features' ] && [ -s "$TEST_WORK/pm-feature" ] && sg_print "feature:android.hardware.wifi"
exit 0
EOF
cat > "$work/bin/ifconfig" <<'EOF'
#!/bin/sh
cat "$TEST_WORK/ifconfig.$1" 2>/dev/null || :
EOF
cat > "$work/bin/netcfg" <<'EOF'
#!/bin/sh
cat "$TEST_WORK/netcfg" 2>/dev/null || :
EOF
# Kernel-facing fakes keep their state in files under $TEST_WORK/kernel.
cat > "$work/tools/system/bin/insmod" <<EOF
#!$python
import os, sys
work = os.environ["TEST_WORK"]
open(work + "/kernel/calls", "a").write("insmod " + " ".join(sys.argv[1:]) + "\n")
name = os.path.basename(sys.argv[1])[:-3]
open(work + "/proc/modules", "a").write(name + " 16384 0 - Live 0xbf000000\n")
os.makedirs(work + "/sys/class/net/rtwlan0", exist_ok=True)
open(work + "/sys/class/net/rtwlan0/flags", "w").write("0x1002\n")
EOF
cat > "$work/tools/system/bin/rmmod" <<EOF
#!$python
import os, shutil, sys
work = os.environ["TEST_WORK"]
open(work + "/kernel/calls", "a").write("rmmod " + " ".join(sys.argv[1:]) + "\n")
lines = open(work + "/proc/modules").read().splitlines()
kept = [line for line in lines if line.split()[0] != sys.argv[1]]
if len(kept) == len(lines):
    sys.exit(1)
open(work + "/proc/modules", "w").write("".join(line + "\n" for line in kept))
shutil.rmtree(work + "/sys/class/net/rtwlan0", ignore_errors=True)
EOF
cat > "$work/tools/system/bin/iptables" <<EOF
#!$python
import os, sys
work = os.environ["TEST_WORK"]
open(work + "/kernel/calls", "a").write("iptables " + " ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]
rule = " ".join([args[1], args[3]] + args[4:])
path = work + "/kernel/iptables"
rules = open(path).read().splitlines() if os.path.exists(path) else []
if args[2] == "-I":
    rules.insert(0, rule)
elif rule in rules:
    rules.remove(rule)
else:
    sys.exit(1)
open(path, "w").write("".join(line + "\n" for line in rules))
EOF
cat > "$work/tools/system/bin/ip" <<EOF
#!$python
import os, sys
work = os.environ["TEST_WORK"]
net = work + "/sys/class/net"
args = sys.argv[1:]
if args[:2] != ["addr", "show"]:
    open(work + "/kernel/calls", "a").write("ip " + " ".join(args) + "\n")
path = work + "/kernel/addr." + args[-1]
addrs = open(path).read().splitlines() if os.path.exists(path) else []
if args[0] == "addr":
    if not os.path.isdir(net + "/" + args[-1]):
        sys.exit(1)
    if args[1] == "show":
        for addr in addrs:
            print("    inet " + addr + " scope global " + args[-1])
        sys.exit(0)
    if args[1] == "add":
        addrs.append(args[2])
    elif args[2] in addrs:
        addrs.remove(args[2])
    else:
        sys.exit(2)
    open(path, "w").write("".join(a + "\n" for a in addrs))
elif args[:2] == ["link", "set"]:
    open(net + "/" + args[2] + "/flags", "w").write("0x1003\n" if args[3] == "up" else "0x1002\n")
EOF
for daemon in wpa_supplicant dhcpcd hostapd dnsmasq; do
    cat > "$work/tools/system/bin/$daemon" <<EOF
#!/bin/sh
proc="\$SG_PROC_ROOT/\$\$"
/bin/mkdir -p "\$proc"
"$python" -c 'import sys; open(sys.argv[1], "wb").write(b"".join(a.encode() + b"\0" for a in sys.argv[2:]))' "\$proc/cmdline" "\$0" "\$@"
trap '/bin/rm -rf "\$proc"; exit 0' TERM
while :; do /bin/sleep 1 & wait \$!; done
EOF
done
cat > "$work/tools/system/bin/wpa_cli" <<'EOF'
#!/bin/sh
[ "$1 $3" = "-p -i" ] && [ "$4" = rtwlan0 ] || exit 2
case "$5" in
    scan) echo OK ;;
    scan_results)
        echo 'bssid / frequency / signal level / flags / ssid'
        printf 'aa:bb:cc:dd:ee:01\t5180\t-41\t[WPA2-PSK-CCMP][ESS]\tHome\n'
        printf 'aa:bb:cc:dd:ee:02\t2412\t-70\t[ESS]\tCafe Free\n'
        printf 'aa:bb:cc:dd:ee:03\t5200\t-50\t[WPA2-PSK-CCMP][ESS]\tHome\n'
        printf 'aa:bb:cc:dd:ee:04\t2437\t-60\t[WPA2-EAP-CCMP][ESS]\tOffice\n'
        printf 'aa:bb:cc:dd:ee:05\t2462\t-80\t[WPA-PSK-TKIP][ESS]\t\n' ;;
    *) exit 2 ;;
esac
EOF
# The package helper that derives a private hostapd (core/hsm HmgSeogaemoBinPatch), same rules.
cat > "$work/bin/app_process" <<EOF
#!$python
import sys
assert sys.argv[1:4] == ["/system/bin", "com.seogaemo.hmg.core.hsm.HmgSeogaemoBinPatch", "patch"], sys.argv
source, dest, old, new = sys.argv[4:]
data = open(source, "rb").read()
open(dest, "xb").write(data.replace(old.encode(), new.encode().ljust(len(old), b"\\0")))
print("ok count=%d" % data.count(old.encode()))
EOF
# Ownership changes are recorded, not made (the host user cannot give files to uid 1010).
cat > "$work/bin/chown" <<'EOF'
#!/bin/sh
echo "chown $*" >> "$TEST_WORK/chowns"
EOF
chmod +x "$work/bin/"* "$work/tools/system/bin/"*

# Rewrite only fixed filesystem roots in a private copy.
sed -e "s|^xml=/system/|xml=$work/system/|" \
    -e "s|/system/wifi/|$work/system/wifi/|g" \
    -e "s|/system/bin/wpa_cli|$work/tools/system/bin/wpa_cli|g" \
    "$module/module.sh" > "$work/wifi.sh"

export TEST_WORK=$work HMG_SEOGAEMO_BASE=$work/base HMG_SEOGAEMO_STATE=$state HMG_SEOGAEMO_MODULE_DIR=$module \
    SG_DATA_ROOT=$data SG_PROC_ROOT=$work/proc SG_SYS_NET_ROOT=$work/sys/class/net SG_BOOT_ID_FILE=$work/boot_id \
    HMG_SEOGAEMO_TOOL_ROOT=$work/tools SG_USB_DEVICES_DIR=$work/sys/bus/usb/devices \
    HMG_SEOGAEMO_WIFI_INBOX=$work/inbox SG_UUID_FILE=$work/uuid
# Keep the test harness on the host PATH, but execute the module with only
# toolbox-like commands. Forbidden names are explicit failing stubs.
mkdir "$work/allowed"
for tool in cat cmp cp dd grep rm mkdir mv chmod ls date sleep; do
    ln -s "$(command -v "$tool")" "$work/allowed/$tool"
done
ln -s "$repo/tools/testlib/fakebin/md5" "$work/allowed/md5"
ln -s "$python" "$work/allowed/python3"
for tool in getprop setprop pm ifconfig netcfg dmesg app_process chown; do
    ln -s "$work/bin/$tool" "$work/allowed/$tool"
done
for tool in awk sed tail head cut tr wc sort uniq xargs find stat readlink sha256sum sha1sum tar unzip busybox toybox; do
    cat > "$work/allowed/$tool" <<'EOF'
#!/bin/sh
echo "forbidden tool called: ${0##*/}" >&2
exit 99
EOF
    chmod +x "$work/allowed/$tool"
done
run() { PATH=$work/allowed "$car_shell" "$work/wifi.sh" "$@" > "$work/output"; }
fails() { if run "$@"; then cat "$work/output"; exit 1; fi; }
assert_state() { grep -Fxq "state=$1" "$work/output" || { cat "$work/output"; exit 1; }; }
assert_line() { grep -Fxq "$1" "$work/output" || { cat "$work/output"; exit 1; }; }
refute_line() { if grep -Fxq "$1" "$work/output"; then cat "$work/output"; exit 1; fi; }
prop_value() { cat "$work/props/persist.wifi.state" 2>/dev/null || :; }
roles() {
    sg_write "$1" > "$data/settings/wifi/builtin_role"
    sg_write "$2" > "$data/settings/wifi/usb_role"
}
calls() { cat "$work/kernel/calls" 2>/dev/null || :; }
peer() { "$car_shell" -c '. "$1"; sg_peer_info wifi "$2"' sh "$HMG_SEOGAEMO_TEST_COMMON" "$1"; }
daemon_pid() { sed -n 2p "$state/daemon.$1"; }
plug() {
    mkdir -p "$work/sys/bus/usb/devices/1-1"
    sg_print "$1" > "$work/sys/bus/usb/devices/1-1/idVendor"
    sg_print "$2" > "$work/sys/bus/usb/devices/1-1/idProduct"
}
unplug() { rm -rf "$work/sys/bus/usb/devices/1-1"; }

# --- Built-in radio, client role (the former wifi-client module, default settings) ---
# No SDIO/WLAN devices exist: precheck and apply must still work with radio off.
run status; assert_state off; assert_line info.builtin_present=1; assert_line info.usb_present=0
assert_line info.builtin_client=1
run precheck; assert_state off
run apply; assert_state pending-restart; assert_line restart=head_unit
[ "$(wc -l < "$work/marks")" -eq 2 ]
[ -f "$xml" ]
[ "$(prop_value)" = 3 ]
[ "$(peer radio)" = none ]
run apply; assert_state pending-restart
[ "$(wc -l < "$work/marks")" -eq 2 ]
sg_print "yes" > "$work/pm-feature"
run status; assert_state on
: > "$work/sys/class/net/wlan0"
sg_print "wlan0: inet addr:10.7.0.15 Bcast:10.7.0.255 Mask:255.255.255.0" > "$work/ifconfig.wlan0"
run status; assert_line info.client_ip=10.7.0.15; assert_line info.client_adb_endpoint=10.7.0.15:5555
rm "$work/ifconfig.wlan0"
sg_print "wlan0 UP 10.7.0.16/24 0x00001043" > "$work/netcfg"
run status; assert_line info.client_ip=10.7.0.16
sg_print "wlan0 UP 192.168.0.1/24 0x00001043" > "$work/netcfg"
run status
if grep -q '^info.client_ip=' "$work/output"; then exit 1; fi
: > "$work/netcfg"
rm "$work/sys/class/net/wlan0"
run revert; assert_state pending-restart; assert_line info.desired=off
run status; assert_state pending-restart; assert_line info.desired=off
[ ! -e "$xml" ]
[ -z "$(prop_value)" ]
[ ! -e "$data/peer/wifi" ]
: > "$work/pm-feature"
run status; assert_state off

sg_print WRONG.USA.260902 > "$work/product"
fails apply; assert_state incompatible
fails precheck; assert_state incompatible
sg_print NEEV.KOR.0000.V039.001.260902 > "$work/product"
roles client off
for file in bcmdhd.ko fw_bcmdhd.bin; do
    mv "$work/system/wifi/$file" "$work/$file.saved"
    for verb in precheck apply; do fails "$verb"; assert_state incompatible; done
    : > "$work/system/wifi/$file"
    for verb in precheck apply; do fails "$verb"; assert_state incompatible; done
    mv "$work/$file.saved" "$work/system/wifi/$file"
done
for vendor in '' realtek; do
    sg_print "$vendor" > "$work/vendor"
    for verb in precheck apply; do fails "$verb"; assert_state incompatible; done
    run status; assert_line info.builtin_present=0
done
# Without the built-in radio, a USB-only configuration is still usable.
roles off client
run precheck; assert_state off; assert_line warn.usb_absent=1
roles client off
[ ! -e "$xml" ]
[ -z "$(prop_value)" ]
[ "$(wc -l < "$work/marks")" -eq 2 ]
sg_print broadcom > "$work/vendor"
run precheck; assert_state off
sg_print "leafia" > "$work/owners"
fails apply; assert_state conflict
fails precheck; assert_state conflict
sg_print "hmgapi" > "$work/owners"
run precheck; assert_state off
: > "$work/owners"

# Unowned changes are refused by precheck, status and apply alike.
sg_print "3" > "$work/props/persist.wifi.state"
for verb in status precheck apply; do fails "$verb"; assert_state conflict; done
: > "$work/props/persist.wifi.state"
sg_print "<permissions/>" > "$xml"
for verb in status precheck apply; do fails "$verb"; assert_state conflict; done
rm "$xml"
# Leftovers only block the built-in client role.
roles off off
sg_print "3" > "$work/props/persist.wifi.state"
run status; assert_state off
run precheck; assert_state off
# Driver and firmware without the chip: every bcmdhd power-up fails, so the radio is absent, the
# unset built-in role defaults to off and an explicit client role is refused.
rm "$data/settings/wifi/builtin_role" "$data/settings/wifi/usb_role"
sg_print '<4>[  130.388800] failed to power up DHD generic adapter, max retry reached**' > "$work/dmesg"
run status; assert_state off; assert_line info.builtin_present=0; assert_line info.builtin_role=off
run precheck; assert_state off
roles client off
for verb in precheck apply; do fails "$verb"; assert_state incompatible; done
: > "$work/dmesg"
: > "$work/props/persist.wifi.state"

sg_print "running" > "$work/hostapd"
run precheck; assert_line warn.carplay_active=1
: > "$work/hostapd"
run precheck; refute_line warn.carplay_active=1

# A failed property write rolls back the XML.
: > "$work/fail-prop"
fails apply; assert_state failed
[ ! -e "$xml" ]
rm "$work/fail-prop"

run apply; assert_state pending-restart
sg_print "drift" >> "$xml"
fails revert; assert_state conflict
[ -e "$state/android.hardware.wifi.xml.applied" ]
# A cleanup failure after exact restore must be retryable.
cp "$state/android.hardware.wifi.xml.applied" "$xml"
: > "$work/fail-clear"
fails revert; assert_state conflict
[ ! -e "$xml" ]
[ -z "$(prop_value)" ]
rm "$work/fail-clear"
run revert; assert_state off

# --- Roles: one CarPlay hotspot, and a built-in client leaves the stock hotspot to USB ---
roles carplay_ap carplay_ap
fails setting-ok usb_role carplay_ap; assert_state conflict
fails apply; assert_state conflict
fails precheck; assert_state conflict
roles carplay_ap off
fails setting-ok usb_role carplay_ap; assert_state conflict
run setting-ok usb_role client; assert_state off
run setting-ok builtin_role client; assert_state off
sg_write on > "$data/desired/wireless-carplay-and-aa"
fails setting-ok builtin_role client; assert_state conflict
roles carplay_ap carplay_ap
run setting-ok builtin_role client; assert_state off
roles client off
fails apply; assert_state conflict
run precheck; assert_state off; assert_line warn.carplay_active=1
roles client carplay_ap
run precheck; refute_line warn.carplay_active=1
rm "$data/desired/wireless-carplay-and-aa"
code=0; run setting-ok other_key x || code=$?
[ "$code" -eq 2 ]
[ ! -e "$xml" ] && [ "$(calls)" = "" ]

# --- USB adapter detection from sysfs ids ---
roles off client
plug 0bda 8179
run status; assert_line info.usb_present=0
plug 0bda b82c
run status; assert_line info.usb_present=1; assert_line info.usb_model=RTL8822BU; assert_line info.usb_id=0bda:b82c
assert_line info.usb_client=1
plug 3625 010b
run status; assert_line info.usb_model=TP-Link-TX10UB
unplug

# An absent adapter is not an error; nothing is loaded.
run apply; assert_state on; assert_line 'detail=USB Wi-Fi adapter not connected'
[ "$(calls)" = "" ] && [ ! -e "$xml" ]

# --- USB client: driver, wpa_supplicant and dhcpcd, network from the app, exact revert ---
plug 0bda b82c
run apply; assert_state on
calls | grep -Fxq "insmod $module/files/kmod/tcc803x/88x2bu.ko"
grep -q '^88x2bu ' "$work/proc/modules"
grep -Fxq "ctrl_interface=$state/wpa" "$state/usb-wpa.conf"
if grep -q network= "$state/usb-wpa.conf"; then exit 1; fi
wpa=$(daemon_pid usb-wpa)
"$python" - "$work/proc/$wpa/cmdline" "$work/tools/system/bin/wpa_supplicant" "$state" <<'EOF'
import sys
args = open(sys.argv[1], "rb").read().split(b"\0")[:-1]
assert args == [sys.argv[2].encode(), b"-irtwlan0", b"-Dnl80211", ("-c" + sys.argv[3] + "/usb-wpa.conf").encode()], args
EOF
[ -d "$work/proc/$(daemon_pid usb-dhcp)" ]
[ "$(peer radio)" = none ]
run apply; assert_state on
[ "$(calls | grep -c insmod)" -eq 1 ] && [ "$(daemon_pid usb-wpa)" = "$wpa" ]
sg_print "rtwlan0: inet addr:172.20.10.4 Bcast:172.20.10.15 Mask:255.255.255.240" > "$work/ifconfig.rtwlan0"
run status; assert_state on; assert_line info.usb_ip=172.20.10.4

run action wifi_scan; assert_state on
assert_line 'info.net_1=-41,psk,Home'; assert_line 'info.net_2=-70,open,Cafe Free'
assert_line 'info.net_3=-60,eap,Office'; assert_line info.count=3
fails action wifi_join; assert_state failed
psk64=abababababababababababababababababababababababababababababababab
sg_print "ssid=486f6d65" "psk=$psk64" > "$work/inbox/usb-join"
run action wifi_join; assert_state on
grep -Fxq '	ssid=486f6d65' "$state/usb-wpa.conf"
grep -Fxq "	psk=$psk64" "$state/usb-wpa.conf"
[ "$(daemon_pid usb-wpa)" != "$wpa" ]
sg_print "ssid=436166652046726565" "psk=none" > "$work/inbox/usb-join"
run action wifi_join; assert_state on
grep -Fxq '	key_mgmt=NONE' "$state/usb-wpa.conf"
for bad in "ssid=48;reboot psk=none" "ssid=486 psk=none" "ssid=48 psk=1234" "ssid= psk=none"; do
    set -f; set -- $bad; set +f
    sg_print "$1" "$2" > "$work/inbox/usb-join"
    fails action wifi_join; assert_state failed
done
grep -Fxq '	key_mgmt=NONE' "$state/usb-wpa.conf"
fails action other; [ ! -s "$work/output" ]

# Unplug and replug: the screen_on watch brings the client back.
wpa=$(daemon_pid usb-wpa)
kill "$wpa"
while [ -d "$work/proc/$wpa" ]; do sleep 0.1; done
fails status; assert_state failed
run watch screen_on; assert_state on
[ "$(daemon_pid usb-wpa)" != "$wpa" ]

run revert; assert_state off
grep -Fxq "rmmod 88x2bu" "$work/kernel/calls"
[ ! -s "$work/proc/modules" ] && [ ! -e "$state/changes" ]
for name in kmod.88x2bu daemon.usb-wpa daemon.usb-dhcp; do [ ! -e "$state/$name" ]; done
[ -z "$(ls "$work/proc" | grep '^[0-9]')" ]
grep -q '	kmod_unload	88x2bu	' "$data/ledger/ledger.tsv"
grep -q '	daemon_stop	usb-wpa	' "$data/ledger/ledger.tsv"
fails action wifi_scan; assert_state failed

# --- USB CarPlay hotspot: hostapd, address, dnsmasq, firewall rule, published peer info ---
roles off carplay_ap
fails action wifi_scan; assert_state conflict
: > "$work/kernel/calls"
run apply; assert_state on; assert_line info.ap_ip=192.168.50.1
assert_line info.ap_ssid=HMG-Seogaemo-6f1d
grep -Fxq 'ssid=HMG-Seogaemo-6f1d' "$state/usb-hostapd.conf"
grep -Fxq 'wpa_passphrase=6f1d2e3c4b5a49688776' "$state/usb-hostapd.conf"
grep -Fxq 'driver=nl80211' "$state/usb-hostapd.conf"
grep -Fxq 'interface=rtwlan0' "$state/usb-hostapd.conf"
[ "$(cat "$work/kernel/addr.rtwlan0")" = 192.168.50.1/24 ]
[ "$(cat "$work/kernel/iptables")" = 'filter INPUT -i rtwlan0 -j ACCEPT' ]
[ -d "$work/proc/$(daemon_pid usb-hostapd)" ] && [ -d "$work/proc/$(daemon_pid usb-dnsmasq)" ]
# hostapd runs as a private copy that keeps its station list out of the stock hotspot's file.
[ -x "$state/bin/hostapd" ] && grep -q ' /data/misc/wifi/all_sta.list usb_sta.list$' "$state/bin/hostapd.source"
grep -q '	bin_derive	hostapd	' "$data/ledger/ledger.tsv"
# hostapd drops root for wifi before reading its config: it starts in a wifi-owned run directory
# with a private copy of the config, passed relative to it (no ctrl_interface in our root dir).
run_dir=$state/run/usb-hostapd
cmp -s "$state/usb-hostapd.conf" "$run_dir/usb-hostapd.conf"
grep -Fxq "chown 1010:1010 $run_dir" "$work/chowns" && grep -Fxq "chown 1010:1010 $run_dir/usb-hostapd.conf" "$work/chowns"
if grep -q ctrl_interface "$state/usb-hostapd.conf"; then exit 1; fi
"$python" -c 'import sys; assert open(sys.argv[1], "rb").read().split(b"\0")[1] == b"usb-hostapd.conf"' \
    "$work/proc/$(daemon_pid usb-hostapd)/cmdline"
for key in radio:usb interface:rtwlan0 ip:192.168.50.1 ssid:HMG-Seogaemo-6f1d passphrase:6f1d2e3c4b5a49688776 \
        channel:6 ready:1; do
    [ "$(peer "${key%%:*}")" = "${key#*:}" ] || { echo "peer ${key%%:*}: $(peer "${key%%:*}")"; exit 1; }
done
# Credentials stay the same across applies and boots.
sg_print 00000000-0000-4000-8000-000000000000 > "$work/uuid"
run apply; assert_state on
[ "$(peer ssid)" = HMG-Seogaemo-6f1d ]
run revert; assert_state off
[ ! -s "$work/kernel/iptables" ] && [ ! -s "$work/kernel/addr.rtwlan0" ] && [ ! -s "$work/proc/modules" ]
[ -z "$(ls "$work/proc" | grep '^[0-9]')" ] && [ ! -e "$data/peer/wifi" ]
grep -q '	net_rule_del	1	' "$data/ledger/ledger.tsv"

# A restart drops every transient effect; the next apply makes them again, stale records are not ours.
run apply; assert_state on
sg_write on > "$data/desired/wifi"
stop_daemons
sg_print boot-b > "$work/boot_id"
: > "$work/proc/modules"; : > "$work/kernel/iptables"; : > "$work/kernel/addr.rtwlan0"
fails status; assert_state failed
run apply; assert_state on
[ "$(peer ready)" = 1 ]
run revert; assert_state off
rm "$data/desired/wifi"

# The adapter fails to come up: nothing transient is left behind.
cp "$work/tools/system/bin/insmod" "$work/insmod.saved"
sg_print '#!/bin/sh' 'exit 1' > "$work/tools/system/bin/insmod"
fails apply; assert_state failed
[ ! -e "$state/changes" ] && [ ! -e "$xml" ]
cp "$work/insmod.saved" "$work/tools/system/bin/insmod"

# The built-in hotspot role is published as the stock hotspot.
roles carplay_ap off
run apply; assert_state on
[ "$(peer radio)" = builtin ] && [ "$(peer ready)" = stock ] && [ "$(peer interface)" = wlan0 ]
run revert; assert_state off

echo 'wifi module tests passed'
