#!/bin/sh
# Wi-Fi client feature exposure for the verified NEEV Korean firmware.
# On NEEV.KOR.260902 featurexml.cfg has no android.hardware.wifi removal line,
# and stock HKMC_WifiSettings gates its client menu on that PackageManager
# feature (verified on the car 2026-11-03). No stock file reads
# persist.wifi.state on this firmware; it is set for parity with other units.
set -u
. "$HMG_SEOGAEMO_BASE/lib/common.sh"

xml=/system/etc/permissions/android.hardware.wifi.xml
prop=persist.wifi.state
value=3

result() { sg_status "$1" "$2" "$3"; exit $?; }
xml_ours() {
    [ -f "$xml" ] &&
        cmp "$HMG_SEOGAEMO_MODULE_DIR/android.hardware.wifi.xml" "$xml" >/dev/null 2>&1
}
pm_wifi() { pm list features 2>/dev/null | grep -Fxq 'feature:android.hardware.wifi'; }

wifi_capable() {
    # Stock init sets the vendor at boot; libhardware_legacy loads this driver
    # and normal firmware on demand. SDIO and wlan0 can both vanish with power
    # off, so enumeration and wlan.driver.status cannot gate initial enable.
    [ "$(getprop tcc.wifi.vendor 2>/dev/null)" = broadcom ] &&
        [ -f /system/wifi/bcmdhd.ko ] && [ -s /system/wifi/bcmdhd.ko ] &&
        [ -f /system/wifi/fw_bcmdhd.bin ] && [ -s /system/wifi/fw_bcmdhd.bin ]
}

external_owner() {
    sg_owner_present leafia ||
        [ -f /data/nemesis/apps/wireless.projection/NEMESIS.data ]
}

parse_client_ip() {
    mode=$1
    line=
    while IFS= read -r line || [ -n "$line" ]; do
        set -f; set -- $line; set +f
        ip=
        if [ "$mode" = netcfg ]; then
            [ "$#" -gt 0 ] || continue
            [ "$1" = wlan0 ] || continue
            shift
            for field do
                case "$field" in */*) ip=${field%%/*}; break ;; esac
            done
        else
            while [ "$#" -gt 1 ]; do
                if [ "$1" = inet ]; then
                    shift
                    ip=${1#addr:}
                    break
                fi
                shift
            done
        fi
        # An AP normally owns 192.168.0.1; never report that as a client IP.
        case "$ip" in
            ''|0.0.0.0|192.168.0.1|*[!0-9.]*|.*|*..*|*.) continue ;;
            *.*.*.*) sg_print "$ip"; break ;;
        esac
    done
}

# The unit has no wpa_cli; a non-AP IPv4 address on wlan0 means DHCP finished.
client_ip() {
    [ -e /sys/class/net/wlan0 ] || return 0
    ip=$(ifconfig wlan0 2>/dev/null | parse_client_ip ifconfig)
    [ -n "$ip" ] || ip=$(netcfg 2>/dev/null | parse_client_ip netcfg)
    [ -z "$ip" ] || sg_print "$ip"
}
print_ip() {
    ip=$(client_ip)
    [ -z "$ip" ] || sg_print "info.client_ip=$ip" "info.client_adb_endpoint=$ip:5555"
}

ap_active() {
    [ "$(getprop init.svc.hostapd 2>/dev/null)" = running ] && return 0
    ifconfig wlan0 2>/dev/null | grep -Eq '(^|[ :])192\.168\.0\.1([ /]|$)'
}

projection_desired() {
    # The sibling module status reflects the runtime-owned desired state.
    [ -f "$HMG_SEOGAEMO_BASE/bin/hmg-seogaemo-root" ] || return 1
    /system/bin/sh "$HMG_SEOGAEMO_BASE/bin/hmg-seogaemo-root" wireless-carplay-and-aa status 2>/dev/null | # android44-shell: allow -- fixed dispatcher beneath the runtime-supplied package root
        grep -Eq '^state=(on|pending-restart)$'
}

compatible() {
    case "$(getprop ro.build.product 2>/dev/null)" in
        NEEV.KOR.*.260902) ;;
        *) result incompatible none 'Unsupported firmware' ;;
    esac
    if ! wifi_capable; then
        result incompatible none 'Stock Broadcom Wi-Fi capability unavailable'
    fi
}

# Refuse targets this module did not write; shared by precheck and apply.
unowned_changes() {
    if external_owner; then result conflict none 'Another package owns Wi-Fi feature files'; fi
    if sg_applied "$xml" || sg_applied "$prop"; then return 0; fi
    if [ -e "$xml" ]; then
        if xml_ours; then result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'; fi
        result conflict none 'Existing Wi-Fi feature XML differs'
    fi
    if [ -n "$(getprop "$prop" 2>/dev/null)" ]; then
        [ "$(getprop "$prop" 2>/dev/null)" != "$value" ] ||
            result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'
        result conflict none 'persist.wifi.state is set outside this module'
    fi
}

precheck() {
    compatible
    unowned_changes
    if projection_desired || ap_active; then sg_print "warn.carplay_active=1"; fi
    result off none ''
}

status() {
    print_ip
    if sg_applied "$xml" && sg_applied "$prop"; then
        if pm_wifi; then result on none ''; fi
        result pending-restart head_unit 'Wi-Fi feature awaits head-unit restart'
    fi
    if sg_applied "$xml" || sg_applied "$prop"; then
        result conflict none 'Wi-Fi client changes are only partly applied'
    fi
    if [ -e "$xml" ]; then
        if xml_ours; then result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'; fi
        result conflict none 'Existing Wi-Fi feature XML differs'
    fi
    if [ -n "$(getprop "$prop" 2>/dev/null)" ]; then
        [ "$(getprop "$prop" 2>/dev/null)" != "$value" ] ||
            result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'
        result conflict none 'persist.wifi.state is set outside this module'
    fi
    if pm_wifi; then
        sg_print info.desired=off
        result pending-restart head_unit 'Wi-Fi feature awaits removal at restart'
    fi
    result off none ''
}

apply() {
    compatible
    unowned_changes
    if sg_applied "$xml" && sg_applied "$prop"; then status; fi
    if sg_applied "$xml" || sg_applied "$prop"; then
        result conflict none 'Wi-Fi client changes are partly applied'
    fi
    sg_file_put "$xml" android.hardware.wifi.xml 0644 root:root ||
        result failed none 'Could not apply Wi-Fi feature XML'
    if ! sg_prop_set "$prop" "$value"; then
        sg_revert_all || :
        result failed none 'Could not set persist.wifi.state'
    fi
    if ! sg_applied "$xml" || ! sg_applied "$prop"; then
        result failed none 'Could not verify applied Wi-Fi client changes'
    fi
    sg_log 'Wi-Fi client feature applied'
    # PackageManager may already report the feature (e.g. reapply before a restart).
    status
}

revert() {
    if ! sg_revert_all; then
        result conflict none 'Wi-Fi client changes drifted; baselines retained'
    fi
    if pm_wifi; then
        sg_print info.desired=off
        result pending-restart head_unit 'Wi-Fi feature awaits removal at restart'
    fi
    result off none ''
}

[ "$#" -eq 1 ] || exit 2
case "$1" in
    status) status ;;
    precheck) precheck ;;
    apply) apply ;;
    revert) revert ;;
    *) exit 2 ;;
esac
