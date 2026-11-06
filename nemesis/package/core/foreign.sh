#!/system/bin/sh
# Other NEMESIS packages and leftovers that overlap HMG-Seogaemo (HMG-API, HMG Leafia Plus,
# NEMESIS samples, factory82). Fixed catalogue; see module-runtime-contract.md "Other packages".
#   status        read-only scan, prints info.item_<n>=<item-id>,<class>
#   clean <item>  remove (NEMESIS uninstall) or delete (exact leftover paths); report items refused
umask 077
base=${0%/*}
base=${base%/core}
SG_DATA_ROOT=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}
HMG_SEOGAEMO_BASE=$base
HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/foreign
export SG_DATA_ROOT HMG_SEOGAEMO_BASE HMG_SEOGAEMO_STATE
. "$base/lib/common.sh"
case "${1:-}:$#" in status:1|clean:2) ;; *) exit 2;; esac
nroot=${SG_NEMESIS_ROOT:-/data/nemesis}
apps=$nroot/apps
backup=$nroot/backup
sys=${SG_SYSTEM_ROOT:-}
hmgapi=${SG_HMGAPI_ROOT:-/data/hmgapi}
localtmp=${SG_LOCAL_TMP:-/data/local/tmp}

has_pkg() { [ -f "$apps/$1/NEMESIS.data" ]; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
hmgapi_mods() {
    for fg_dir in "$apps"/hmgapi.*; do
        [ -f "$fg_dir/NEMESIS.data" ] && sg_print "${fg_dir##*/}"
    done
    return 0
}
hmgapi_installed() { [ -f "$hmgapi/installed.txt" ]; }
hmgapi_residue() {
    hmgapi_installed && return 1
    for fg_path in "$sys/system/bin/hmgapid" "$sys/system/bin/lpatch" "$sys/system/lib/libhmgapi_hook.so" \
        "$sys/system/framework/hmgapi-hook.jar" "$sys/system/bin/app_process.hmgapi-stock"; do
        exists "$fg_path" && return 0
    done
    grep -q '^# HMGAPI_HOOK begin' "$sys/system/etc/install-recovery.sh" "$sys/system/etc/qb_runtime.sh" 2>/dev/null
}
# HMG-API's Wi-Fi client mod writes the same feature XML and persist.wifi.state=3 as our wifi-client.
# Once HMG-API is gone they stay behind with no wifi-client record, and wifi-client refuses to touch them.
wifi_xml=$sys/system/etc/permissions/android.hardware.wifi.xml
wifi_prop=${SG_PROPERTY_ROOT:-/data/property}/persist.wifi.state
wifi_ref=$base/modules/wifi-client.d/android.hardware.wifi.xml
wifi_recorded() {
    for fg_rec in "$SG_DATA_ROOT"/modules/wifi-client/file.*/applied "$SG_DATA_ROOT"/modules/wifi-client/prop.*/applied; do
        [ -e "$fg_rec" ] && return 0
    done
    return 1
}
wifi_xml_left() { [ -f "$wifi_xml" ] && [ -f "$wifi_ref" ] && cmp "$wifi_ref" "$wifi_xml" > /dev/null 2>&1; }
wifi_prop_left() { [ -f "$wifi_prop" ] && [ "$(cat "$wifi_prop" 2>/dev/null)" = 3 ]; }
hmgapi_wifi() {
    has_pkg hmgapi && return 1
    hmgapi_installed && return 1
    wifi_recorded && return 1
    wifi_xml_left || wifi_prop_left
}
leafia_parts='wireless.carplay.bt carplay.wifi.audio projection.menu'
leafia_orphan() {
    has_pkg wireless.carplay.aa && return 1
    for fg_part in $leafia_parts; do [ -d "$backup/$fg_part" ] && return 0; done
    { [ -d "$backup/wireless.projection" ] && ! has_pkg wireless.projection; } && return 0
    [ -d "$backup/projection.tbt" ] && ! has_pkg projection.tbt
}
leafia_logs() {
    for fg_id in wireless.carplay.aa wireless.projection projection.tbt wireless.carplay.bt carplay.wifi.audio \
        projection.menu adb.tcp; do
        has_pkg "$fg_id" && continue
        sg_print "$nroot/$fg_id.log"
    done
    has_pkg wireless.carplay.aa || sg_print "$nroot/logs/wireless.carplay.aa" "$nroot/build/wireless.carplay.aa"
}
factory82_state() {
    has_pkg local.hkmc.factory82 && return 0
    sg_print "$nroot/state/local.hkmc.factory82" "$localtmp/hkmc.factory82.session"
}
any_exists() {
    while IFS= read -r fg_path; do exists "$fg_path" && return 0; done
    return 1
}

scan() {
    [ -z "$(hmgapi_mods)" ] || sg_print 'pkg-hmgapi-mods remove'
    if has_pkg hmgapi; then sg_print 'pkg-hmgapi remove'
    elif hmgapi_installed && [ -f "$hmgapi/uninstall.sh" ]; then sg_print 'hmgapi-standalone remove'; fi
    if hmgapi_residue; then sg_print 'hmgapi-residue report'
    elif [ -d "$hmgapi" ] && ! hmgapi_installed; then sg_print 'hmgapi-data delete'; fi
    hmgapi_wifi && sg_print 'hmgapi-wifi delete'
    has_pkg wireless.carplay.aa && sg_print 'pkg-leafia remove'
    leafia_orphan && sg_print 'leafia-orphan report'
    { ! has_pkg wireless.carplay.aa && [ -f "$nroot/wireless.carplay.aa.stopped" ]; } && sg_print 'leafia-disabled-apps report'
    exists "$sys/system/bin/app_process.leafia-stock" && sg_print 'app-process-leafia report'
    leafia_logs | any_exists && sg_print 'foreign-logs delete'
    has_pkg adb.tcp && sg_print 'pkg-adb-tcp remove'
    { ! has_pkg adb.tcp && [ -d "$backup/adb.tcp" ]; } && sg_print 'adb-tcp-orphan report'
    has_pkg wireless.projection && sg_print 'pkg-wireless-projection remove'
    has_pkg local.hkmc.factory82 && sg_print 'pkg-factory82 remove'
    factory82_state | any_exists && sg_print 'factory82-state delete'
    has_pkg carplay.session && sg_print 'pkg-carplay-session remove'
    has_pkg voicehandler.vr-gates && sg_print 'pkg-vr-gates remove'
    return 0
}

# Our modules whose targets the item also changes: they must be off before its restore runs.
overlap() {
    case "$1" in
        pkg-hmgapi-mods|pkg-hmgapi|hmgapi-standalone|pkg-leafia)
            sg_print wireless-carplay-and-aa wifi-client wireless-adb user-button-head-unit user-button-shortcut ;;
        pkg-adb-tcp) sg_print wireless-adb wireless-carplay-and-aa ;;
        pkg-wireless-projection|pkg-carplay-session) sg_print wireless-carplay-and-aa wifi-client ;;
        pkg-vr-gates) sg_print wireless-carplay-and-aa ;;
        hmgapi-wifi) sg_print wifi-client ;;
        pkg-factory82) sg_print skip-consent-screen ;;
    esac
}

uninstall_pkg() {
    sg_ready || { sg_status failed none 'Could not prepare state'; exit 1; }
    nemesis uninstall "$1" > "$HMG_SEOGAEMO_STATE/uninstall.out" 2>&1 < /dev/null
    fg_code=$?
    if [ "$fg_code" -eq 0 ]; then fg_result=ok; else fg_result=failed; fi
    sg_ledger foreign_remove "$1" /dev/null "$HMG_SEOGAEMO_STATE/uninstall.out" '' "$fg_result" || :
    [ "$fg_code" -eq 0 ] || { sg_status failed none "NEMESIS could not remove $1 (exit $fg_code)"; exit 1; }
}

if [ "$1" = status ]; then
    found=$(scan)
    n=0
    lines=
    for fg_line in $(sg_print "$found" | while read -r fg_id fg_class; do [ -z "$fg_id" ] || sg_print "$fg_id,$fg_class"; done); do
        n=$((n + 1))
        lines="$lines${lines:+
}info.item_$n=$fg_line"
    done
    if sg_ready; then
        { [ -z "$lines" ] || sg_print "$lines"; sg_print "info.count=$n"; } > "$HMG_SEOGAEMO_STATE/report.tmp.$$" &&
            mv "$HMG_SEOGAEMO_STATE/report.tmp.$$" "$HMG_SEOGAEMO_STATE/report"
    fi
    [ -z "$lines" ] || sg_print "$lines"
    sg_print "info.count=$n"
    sg_status on none "$n other package items"
    exit $?
fi

item=$2
case "$item" in ''|*[!a-z0-9-]*) exit 2;; esac
sg_ready || { sg_status failed none 'Could not prepare state'; exit 1; }
scan > "$HMG_SEOGAEMO_STATE/scan" || exit 1
class=
while read -r fg_id fg_class; do
    [ "$fg_id" = "$item" ] && class=$fg_class
done < "$HMG_SEOGAEMO_STATE/scan"
[ -n "$class" ] || { sg_status failed none "$item not found"; exit 1; }
[ "$class" != report ] || { sg_status failed none "$item can only be reported"; exit 1; }
for fg_module in $(overlap "$item"); do
    [ "$(cat "$SG_DATA_ROOT/desired/$fg_module" 2>/dev/null)" != on ] ||
        { sg_status conflict none "Turn off $fg_module first"; exit 3; }
done
case "$item" in
    pkg-hmgapi-mods) for fg_id in $(hmgapi_mods); do uninstall_pkg "$fg_id"; done ;;
    pkg-hmgapi)
        [ -z "$(hmgapi_mods)" ] || { sg_status conflict none 'Remove the HMG-API mod packages first'; exit 3; }
        uninstall_pkg hmgapi ;;
    hmgapi-standalone)
        sg_ready || { sg_status failed none 'Could not prepare state'; exit 1; }
        /system/bin/sh "$hmgapi/uninstall.sh" > "$HMG_SEOGAEMO_STATE/uninstall.out" 2>&1 < /dev/null
        fg_code=$?
        if [ "$fg_code" -eq 0 ]; then fg_result=ok; else fg_result=failed; fi
        sg_ledger foreign_remove hmgapi-standalone /dev/null "$HMG_SEOGAEMO_STATE/uninstall.out" '' "$fg_result" || :
        [ "$fg_code" -eq 0 ] || { sg_status failed none "HMG-API uninstall failed (exit $fg_code)"; exit 1; } ;;
    pkg-leafia)
        ! has_pkg projection.cardata || uninstall_pkg projection.cardata
        uninstall_pkg wireless.carplay.aa ;;
    pkg-adb-tcp) uninstall_pkg adb.tcp ;;
    pkg-wireless-projection) uninstall_pkg wireless.projection ;;
    pkg-factory82) uninstall_pkg local.hkmc.factory82 ;;
    pkg-carplay-session) uninstall_pkg carplay.session ;;
    pkg-vr-gates) uninstall_pkg voicehandler.vr-gates ;;
    hmgapi-wifi)
        if wifi_xml_left; then
            cp "$wifi_xml" "$HMG_SEOGAEMO_STATE/hmgapi-wifi.xml" || { sg_status failed none 'Could not back up the Wi-Fi feature XML'; exit 1; }
            sg_remount rw || { sg_status failed none 'Could not remount /system'; exit 1; }
            rm -f "$wifi_xml"
            fg_code=$?
            sg_remount_ro
            [ "$fg_code" -eq 0 ] && [ ! -e "$wifi_xml" ] || { sg_status failed none 'Could not delete the Wi-Fi feature XML'; exit 1; }
            sg_ledger foreign_delete "$wifi_xml" "$HMG_SEOGAEMO_STATE/hmgapi-wifi.xml" /dev/null '' ok || :
        fi
        if wifi_prop_left; then
            setprop persist.wifi.state '' 2> /dev/null || :
            rm -f "$wifi_prop" && [ ! -e "$wifi_prop" ] || { sg_status failed none 'Could not clear persist.wifi.state'; exit 1; }
            sg_ledger foreign_delete "$wifi_prop" /dev/null /dev/null '' ok || :
        fi ;;
    hmgapi-data|foreign-logs|factory82-state)
        case "$item" in
            hmgapi-data) paths=$hmgapi ;;
            foreign-logs) paths=$(leafia_logs) ;;
            factory82-state) paths=$(factory82_state) ;;
        esac
        for fg_path in $paths; do
            exists "$fg_path" || continue
            rm -rf "$fg_path" || { sg_status failed none "Could not delete $fg_path"; exit 1; }
            sg_ledger foreign_delete "$fg_path" /dev/null /dev/null '' ok || :
        done
        sg_status off none "Deleted $item"
        exit $? ;;
    *) exit 2 ;;
esac
sg_restart_required || :
sg_status pending-restart head_unit "Removed $item; restart the head unit to finish"
