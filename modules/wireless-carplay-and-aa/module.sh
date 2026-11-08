#!/bin/sh
# Modified by HMG-Seogaemo: single-car port of HMG-API wireless projection.
set -eu
. "$HMG_SEOGAEMO_BASE/lib/common.sh"
umask 077

# The feature list lives in the car's own onebin folder (owns_lines in module.properties lists every
# supported one; an unlisted folder is refused in compatibility()).
ONEBIN=$(getprop ro.mobis.onebindir)
FEATURE=/system/onebin/$ONEBIN/featurexml.cfg
ASSET=/system/etc/hmg-seogaemo/wireless-carplay-and-aa
RESTART_DETAIL='restart unit to start wireless CarPlay and Android Auto'
# The hooks load through the core hook host; apps read the world-readable copy of the jar.
PARTS=/system/framework/hmg-seogaemo-wireless-parts.jar
ENTRY=hmgapi.mods.wireless.Wireless
PROCESSES='com.mnsoft.navi com.tcc.iap2server com.google.android.projection.sink com.android.btsettings com.daudio.app.dipo'

path() { sg_print "${SG_WIRELESS_TEST_ROOT:-}$1"; }
exists() { [ -f "$(path "$1")" ]; }
value() { getprop "$1"; }
fail() { sg_status failed none "$1"; }
conflict() { sg_status conflict none "$1"; }
incompatible() { sg_status incompatible none "$1"; }
hooked() { sg_applied "$SG_DATA_ROOT/core/hook/mods/${HMG_SEOGAEMO_STATE##*/}/entry"; }
# Before the core hook host, this module installed its own app_process wrapper.
legacy() { sg_applied /system/bin/app_process || [ -f "$HMG_SEOGAEMO_STATE/zygote-upgrade/ready" ]; }
# A boot reapply must not replace a jar that running apps hold open with identical bytes:
# the orphaned inode keeps /system from returning to read-only until the next restart.
current() { [ "$was" -eq 1 ] && sg_applied "$1" && cmp "$HMG_SEOGAEMO_MODULE_DIR/$2" "$(path "$1")" >/dev/null 2>&1; }

# An app_process swap with no ownership record is never "disabled": refuse and
# leave everything untouched (restore stays a conflict until the owner resolves it).
unrecorded_swap() {
    sg_zygote_foreign && return 0
    conflict 'app_process changed outside the ledger; restore refused, nothing modified'
    return 3
}
# Generated diagnostics: our private tree, and the hook's per-app runtime and Dalvik
# directories (declared as owns_generated_dirs). Apps keep writing them until the next
# restart, so the per-app removal is advisory: it never fails the revert and records a
# cleanup that boot reconcile retries.
cleanup_runtime() {
    sg_projection_runtime clear || { fail 'runtime diagnostics cleanup failed'; return 1; }
    sg_generated_dirs_remove || :
}
# The CarPlay hotspot (contract: peer info). The wifi module publishes it while it is on; this script
# only reads. Without a published hotspot the stock Broadcom one is used, as before the wifi module.
wifi_role() {
    wr_value=$(cat "$(path "$SG_DATA_ROOT/settings/wifi/$1")" 2>/dev/null) || wr_value=
    case "$wr_value" in off|client|carplay_ap) sg_write "$wr_value" ;; *) sg_write "$2" ;; esac
}
stock_radio() {
    [ "$(value tcc.wifi.vendor)" = broadcom ] &&
        [ -s "$(path /system/wifi/bcmdhd.ko)" ] && [ -s "$(path /system/wifi/fw_bcmdhd.bin)" ]
}
hotspot_radio() {
    hr_radio=$(sg_peer_info wifi radio 2>/dev/null) || hr_radio=
    case "$hr_radio" in
        usb) sg_write usb; return ;;
        none) if [ "$(wifi_role builtin_role client)" = client ]; then sg_write none; return; fi ;;
    esac
    if stock_radio; then sg_write builtin; else sg_write none; fi
}
# ModuleManager.hotspotConflict on the root side: wifi on with the built-in radio as a client and no
# USB CarPlay hotspot leaves wireless CarPlay without one. apply refuses; precheck only warns because
# the app's plan turns wifi off before this apply.
no_hotspot() {
    [ "$(cat "$(path "$SG_DATA_ROOT/desired/wifi")" 2>/dev/null)" = on ] || return 1
    [ "$(wifi_role builtin_role client)" = client ] || return 1
    [ "$(wifi_role usb_role off)" != carplay_ap ] || return 1
    [ "$(sg_peer_info wifi radio 2>/dev/null)" != usb ]
}
compatibility() {
    map_state=$(/system/bin/sh "$HMG_SEOGAEMO_BASE/bin/hmg-seogaemo-root" map status 2>/dev/null) || map_state= # android44-shell: allow -- fixed dispatcher beneath the runtime-supplied package root
    sg_print "$map_state" | grep -Fxq 'state=on' ||
        { incompatible 'verified car map required'; return 4; }
    case "$ONEBIN" in ''|*[!a-z0-9_]*) incompatible 'unsupported onebin'; return 4 ;; esac
    sg_validate owns_lines "$FEATURE:-/system/etc/permissions/com.hkmc.software.wifihotspot.xml" ||
        { incompatible "onebin $ONEBIN is not supported yet"; return 4; }
    [ "$(value ro.build.version.release)" = 4.4.2 ] || { incompatible 'requires Android 4.4.2'; return 4; }
    for owner in hmgapi leafia nemesis-adb-tcp; do
        if sg_owner_present "$owner"; then conflict "external owner: $owner"; return 3; fi
    done
    if exists /system/bin/app_process.hmgapi-stock; then conflict 'HMG-API app_process backup present'; return 3; fi
    if exists /system/bin/app_process.hmg-seogaemo-stock && ! legacy && ! sg_core_hook_owned; then
        conflict 'orphaned app_process backup'; return 3
    fi
    unrecorded_swap || return 3
    exists "$FEATURE" || { incompatible 'featurexml.cfg absent'; return 4; }
    for name in com.hkmc.software.connectivity.carplay_wireless com.hkmc.software.connectivity.androidauto_wireless com.hkmc.software.wifihotspot; do
        target=/system/etc/permissions/$name.xml
        if exists "$target" && ! grep -Fq "<feature name=\"$name\"" "$(path "$target")"; then
            incompatible "feature XML content mismatch: $name"; return 4
        fi
        old="-/system/etc/permissions/$name.xml"
        active=$(grep -Fxc -e "$old" "$(path "$FEATURE")" || :)
        inactive=$(grep -Fxc -e "#$old" "$(path "$FEATURE")" || :)
        [ "$((active + inactive))" -le 1 ] || { incompatible "featurexml line mismatch: $name"; return 4; }
    done
    exists /system/bin/app_process || { incompatible 'app_process absent'; return 4; }
    for name in wireless-mod.jar libleafiaaac.so; do
        [ -s "$HMG_SEOGAEMO_MODULE_DIR/files/$name" ] || { fail "missing payload: $name"; return 1; }
    done
    case "$(value persist.service.adb.tcp.enable)" in
        1) conflict 'stock ADB switch conflicts with hotspot'; return 3 ;;
    esac
}

put_assets() {
    sg_file_put /system/lib/libleafiaaac.so files/libleafiaaac.so 644 0:0 || return 1
    for name in aa-tbt-48ee793a aa-tbt-a0bea1c4 carplay-core-wifi carplay-audio-formats carplay-utils-converter iap2-lane-msgid; do
        sg_file_put "$ASSET/recipes/$name.recipe" "files/recipes/$name.recipe" 644 0:0 || return 1
    done
    for name in com.hkmc.software.connectivity.carplay_wireless com.hkmc.software.connectivity.androidauto_wireless com.hkmc.software.wifihotspot; do
        target=/system/etc/permissions/$name.xml
        if ! exists "$target"; then sg_file_put "$target" "files/feature/$name.xml" 644 0:0 || return 1; fi
        old="-/system/etc/permissions/$name.xml"
        new="#$old"
        if grep -Fqx -e "$old" "$(path "$FEATURE")"; then
            sg_file_replace_line "$FEATURE" "$old" "$new" || return 1
        elif grep -Fqx -e "$new" "$(path "$FEATURE")"; then
            :
        fi
    done
}

assets_readable() {
    for recipe in aa-tbt-48ee793a aa-tbt-a0bea1c4 carplay-core-wifi carplay-audio-formats carplay-utils-converter iap2-lane-msgid; do
        sg_public_readable "$(path "$ASSET/recipes/$recipe.recipe")" || return 1
    done
    sg_public_readable "$(path /system/lib/libleafiaaac.so)"
}

repair_assets() {
    if ! assets_readable; then
        # DiPO registers once: retain restart intent even if repair is interrupted.
        sg_restart_required || return 1
    fi
    for recipe in aa-tbt-48ee793a aa-tbt-a0bea1c4 carplay-core-wifi carplay-audio-formats carplay-utils-converter iap2-lane-msgid; do
        sg_payload_dirs "$ASSET/recipes/$recipe.recipe" || return 1
    done
    put_assets || return 1
}

apply() {
    compatibility || return $?
    if no_hotspot; then
        conflict 'Wireless CarPlay needs a hotspot: the Wi-Fi module uses built-in Wi-Fi as a client'; return 3
    fi
    if legacy; then
        # Package update: restore what the old self-installed wrapper changed, then apply
        # again through the core hook host. The running zygote is untouched until restart.
        sg_log 'moving wireless projection to the core hook host' || :
        sg_revert_all || { conflict 'previous wrapper restore blocked by drift; ledger retained'; return 3; }
    fi
    sg_projection_runtime prepare || { fail 'private runtime directory unavailable'; return 1; }
    was=0; jar_changed=0
    if hooked; then was=1; fi
    if [ "$was" -eq 0 ]; then
        # Stale wrapper guard state (never baselined as stock) must not be recorded as originals.
        sg_zygote_guard_sweep || { conflict 'wrapper guard state could not be cleared'; return 3; }
    fi
    assets=1
    if [ "$was" -eq 1 ]; then repair_assets || assets=0; else put_assets || assets=0; fi
    if [ "$assets" -eq 0 ] ||
       ! sg_prop_set persist.ium.support carplay ||
       ! sg_prop_set persist.sys.iap2.wifi t ||
       ! sg_prop_set persist.iap2.iden.wireless t ||
       { ! current "$PARTS" files/wireless-mod.jar && ! sg_file_put "$PARTS" files/wireless-mod.jar 644 0:0; } ||
       { ! current "$SG_DATA_ROOT/core/hook/mods/${HMG_SEOGAEMO_STATE##*/}/hook.jar" files/wireless-mod.jar &&
         { jar_changed=1; ! sg_hook_register files/wireless-mod.jar "$ENTRY" $PROCESSES; }; }; then
        if [ "$was" -eq 0 ]; then
            sg_revert_all || sg_log 'rollback failed; ledger and baselines retained'
            if ! sg_restore_material; then sg_projection_runtime clear || return 1; fi
            fail 'apply failed; inspect change ledger'; return 1
        fi
        fail 'reapply failed; inspect change ledger'; return 1
    fi
    result=0
    host=$(sg_core_hook_ensure 2>&1) || result=$?
    if [ "$result" -ne 0 ]; then
        sg_log "core hook host install failed ($result): $host" || :
        if [ "$was" -eq 0 ]; then
            sg_revert_all || sg_log 'rollback failed; ledger and baselines retained'
            sg_core_hook_release || sg_log 'hook host release after failure blocked'
        fi
        if [ "$result" -eq 3 ]; then conflict 'app hook host blocked: app_process is changed or owned elsewhere'; return 3; fi
        fail 'app hook host install failed; inspect change ledger'; return 1
    fi
    # A new hook jar loads only in the next zygote.
    if [ "$was" -eq 1 ] && [ "$jar_changed" -eq 0 ]; then status applying; return $?; fi
    sg_restart_required || { fail 'could not record the pending restart'; return 1; }
    # The running zygote predates the wrapper: stay pending until the boot changes.
    sg_status pending-restart head_unit "$RESTART_DETAIL"
}

revert() {
    unrecorded_swap || return 3
    on=0
    if hooked || legacy; then on=1; fi
    # An interrupted apply can have feature/property changes without the hook registration.
    sg_revert_all || { conflict 'restore blocked by drift; ledger retained'; return 3; }
    sg_core_hook_release || { conflict 'app hook host restore blocked; backup retained'; return 3; }
    # Empty asset directories that an earlier build left without a baseline.
    sg_owned_dirs_prune "$ASSET/recipes" "$ASSET" /system/etc/hmg-seogaemo || sg_log 'empty asset directories kept' || :
    cleanup_runtime || return $?
    if [ "$on" -eq 1 ]; then
        sg_restart_required || :
        sg_print info.desired=off
        sg_status pending-restart head_unit 'restart unit to finish restoration'; return $?
    fi
    # A hooked zygote from an earlier revert keeps running until the restart.
    if sg_restart_pending; then sg_status pending-restart head_unit 'restart unit to finish restoration'; return $?; fi
    sg_status off none 'disabled'
}

status() {
    if sg_restore_material; then sg_print info.restore_material=present
    else sg_print info.restore_material=absent; fi
    sg_print "info.hotspot_radio=$(hotspot_radio)"
    if ! command -v sg_applied >/dev/null 2>&1; then
        sg_status not-implemented none 'not implemented'; return 0
    fi
    if legacy; then
        sg_status pending-restart head_unit 'restart unit to finish the update'; return $?
    fi
    if ! hooked; then
        unrecorded_swap || return 3
        if sg_restart_pending; then sg_status pending-restart head_unit 'restart unit to finish restoration'; return $?; fi
        sg_status off none 'disabled'; return 0
    fi
    sg_core_hook_owned || { fail 'app hook host missing; apply again'; return 1; }
    if [ "$(value persist.service.adb.tcp.enable)" = 1 ]; then conflict 'stock ADB switch conflicts with hotspot'; return 3; fi
    if [ "$(value persist.ium.support)" != carplay ] ||
       [ "$(value persist.sys.iap2.wifi)" != t ] ||
       [ "$(value persist.iap2.iden.wireless)" != t ]; then fail 'projection property drift'; return 1; fi
    assets_readable || { fail 'projection assets unreadable; reapply and restart required'; return 1; }
    if sg_restart_pending; then
        runtime_result=$(sg_projection_runtime status) || { sg_print "$runtime_result"; return 1; }
        sg_status pending-restart head_unit "$RESTART_DETAIL"; return 0
    fi
    sg_projection_runtime "${1:-status}"
}

# The app's button runs "action tbt_reset"; older apps call the tbt-reset verb directly.
if [ "$#" -eq 2 ] && [ "$1" = action ]; then
    [ "$2" = tbt_reset ] || exit 2
    set -- tbt-reset
fi
[ "$#" -eq 1 ] || exit 2
if ! command -v sg_applied >/dev/null 2>&1; then
    case "$1" in
        status|precheck) sg_status not-implemented none 'not implemented' ;;
        apply|revert) sg_status failed none 'package mutation API unavailable' ;;
        *) exit 2 ;;
    esac
    exit $?
fi
case "$1" in
    precheck)
        if no_hotspot; then sg_print warn.wifi_client=1; fi
        if hooked || legacy; then status; else compatibility && sg_status off none 'compatible'; fi ;;
    apply) apply ;;
    revert) revert ;;
    status) status ;;
    tbt-reset) sg_projection_runtime tbt-reset ;;
    *) exit 2 ;;
esac
