#!/system/bin/sh
# Root script for installed module packages. The dispatcher sets
# HMG_SEOGAEMO_BASE/STATE/MODULE_DIR and holds operation.lock for writes.
. "$HMG_SEOGAEMO_BASE/lib/common.sh"
. "$HMG_SEOGAEMO_BASE/lib/hsm.sh"
id=${HMG_SEOGAEMO_STATE##*/}
pkg=$HMG_SEOGAEMO_MODULE_DIR
manifest=$SG_DATA_ROOT/installed/$id.properties
HSM_SETTINGS_DIR=$SG_DATA_ROOT/settings/$id
HSM_MODULE_ID=$id
export HSM_SETTINGS_DIR HSM_MODULE_ID

hm_field() {
    hm_value=
    while IFS='=' read -r hm_key hm_val; do
        [ "$hm_key" = "$1" ] && hm_value=$hm_val
    done < "$manifest"
    sg_print "$hm_value"
}

hm_text() {
    hm_text_value=${1#@}
    while IFS='=' read -r hm_key hm_val; do
        [ "$hm_key" = "${1#@}" ] && hm_text_value=$hm_val
    done < "$pkg/strings/en.txt"
    sg_print "$hm_text_value"
}

hm_desired_on() { [ "$(cat "$SG_DATA_ROOT/desired/$id" 2>/dev/null)" = on ]; }
hm_reboot_class() { grep -Fxq restore=reboot "$manifest"; }
hm_is_action() { grep -Fxq kind=action "$manifest"; }
hm_hooks() { grep -Fxq hooks=1 "$manifest"; }

hm_hook_status() {
    hm_hooks || return 0
    if sg_core_hook_owned; then sg_print info.hook_host=on; else sg_print info.hook_host=off; fi
    [ -f "$SG_DATA_ROOT/core/hook/status" ] || return 0
    while IFS='=' read -r hm_key hm_val; do
        case "$hm_key" in
            gate) sg_print "info.hook_gate=$(sg_clean "$hm_val")" ;;
            "mod.$id") sg_print "info.hook_load=$(sg_clean "$hm_val")" ;;
        esac
    done < "$SG_DATA_ROOT/core/hook/status"
}

hm_gate() {
    hm_product=$(getprop ro.build.product)
    hm_match=0
    hm_old_ifs=$IFS
    IFS=,
    for hm_glob in $(hm_field cars); do
        case "$hm_product" in $hm_glob) hm_match=1;; esac
    done
    for hm_owner in $(hm_field conflicts); do
        IFS=$hm_old_ifs
        if sg_owner_present "$hm_owner"; then
            sg_status conflict none "$hm_owner already provides this feature"; return $?
        fi
    done
    IFS=$hm_old_ifs
    [ "$hm_match" -eq 1 ] || { sg_status incompatible none "Not built for $hm_product"; return $?; }
}

hm_stock_ok() {
    while IFS='=' read -r hm_key hm_val; do
        case "$hm_key" in known_stock.*) ;; *) continue;; esac
        case "$(getprop ro.build.product)" in ${hm_val%%:*}) ;; *) continue;; esac
        hm_rest=${hm_val#*:}
        hm_path=${hm_rest%:*}
        hm_sum=$(md5 "$hm_path" 2>/dev/null) || return 1
        set -- $hm_sum
        [ "${1:-}" = "${hm_rest##*:}" ] || return 1
    done < "$manifest"
}

hm_all_applied() {
    hm_any=0
    hm_old_ifs=$IFS
    while IFS='=' read -r hm_key hm_val; do
        case "$hm_key" in
            owns_props|owns_files) IFS=, ;;
            owns_lines.*) hm_val=${hm_val%%:*} ;;
            *) continue ;;
        esac
        for hm_target in $hm_val; do
            IFS=$hm_old_ifs
            case "$hm_target" in
                /*) hm_mark=$(sg_file_key "$hm_target") || return 1
                    [ -f "$HMG_SEOGAEMO_STATE/file.$hm_mark/ready" ] ||
                        [ -f "$HMG_SEOGAEMO_STATE/line.$hm_mark/ready" ] || continue ;;
                *) [ -f "$HMG_SEOGAEMO_STATE/prop.$hm_target/ready" ] || continue ;;
            esac
            hm_any=1
            sg_applied "$hm_target" || return 1
        done
        IFS=$hm_old_ifs
    done < "$manifest"
    [ "$hm_any" -eq 1 ]
}

hm_extra_status() {
    [ -f "$pkg/status.sh" ] || return 0
    hm_extra=$(hsm_walk "$pkg/status.sh" status run 2>/dev/null) || return 0
    hm_fail=
    hm_old_ifs=$IFS
    IFS='
'
    for hm_line in $hm_extra; do
        case "$hm_line" in
            info.*) sg_print "$hm_line" ;;
            fail=*) hm_fail=$(hm_text "${hm_line#fail=}") ;;
        esac
    done
    IFS=$hm_old_ifs
    [ -z "$hm_fail" ] || { sg_status failed none "$hm_fail"; return $?; }
}

hm_status() {
    hm_gate || return $?
    # A one-shot action module has no on/off state: it is ready or unavailable.
    if hm_is_action; then hm_extra_status || return $?; sg_status off none 'Ready'; return $?; fi
    hm_hook_status
    hm_extra_status || return $?
    if hm_reboot_class; then
        if hm_desired_on; then sg_status on none 'Active'; return $?; fi
        if sg_restart_pending; then
            sg_print info.desired=off
            sg_status pending-restart head_unit 'Restart the head unit to restore stock behavior'; return $?
        fi
        sg_status off none 'Off'; return $?
    fi
    if ! sg_restore_material; then
        if sg_restart_pending; then
            sg_print info.desired=off
            sg_status pending-restart head_unit 'Restart the head unit to finish restoring'; return $?
        fi
        sg_status off none 'Off'; return $?
    fi
    sg_check_build || { sg_status conflict none 'Firmware changed; backup retained'; return $?; }
    if hm_all_applied; then
        if [ "$(hm_field restart)" = head_unit ] && sg_restart_pending; then
            sg_status pending-restart head_unit 'Restart the head unit to finish'; return $?
        fi
        sg_status on none 'Active'; return $?
    fi
    sg_status failed none 'Changed outside HMG-Seogaemo; backup retained'
}

hm_check() {
    [ -f "$pkg/check.sh" ] || return 0
    hm_checked=$(hsm_walk "$pkg/check.sh" check run 2>/dev/null)
    hm_code=$?
    hm_old_ifs=$IFS
    IFS='
'
    for hm_line in $hm_checked; do
        case "$hm_line" in
            warn=@*) sg_print "warn.${hm_line#warn=@}=1" ;;
            block=@*) IFS=$hm_old_ifs; sg_status conflict none "$(hm_text "${hm_line#block=}")"; return $? ;;
        esac
    done
    IFS=$hm_old_ifs
    [ "$hm_code" -eq 0 ] || { sg_status failed none 'Module check failed'; return $?; }
}

hm_apply() {
    hm_gate || return $?
    ! hm_is_action || { sg_status failed none 'Action modules cannot be turned on'; return $?; }
    if ! sg_restore_material && ! hm_stock_ok; then
        sg_status incompatible none 'Stock file differs from the one this module expects'; return $?
    fi
    hm_check > "$HMG_SEOGAEMO_STATE.check.$$" 2>&1
    hm_code=$?
    grep -v '^warn\.' "$HMG_SEOGAEMO_STATE.check.$$" || :
    rm -f "$HMG_SEOGAEMO_STATE.check.$$"
    [ "$hm_code" -eq 0 ] || return "$hm_code"
    sg_ready || { sg_status failed none 'Could not prepare module state'; return $?; }
    sg_bind_build || { sg_status conflict none 'Firmware changed; backup retained'; return $?; }
    # A re-apply (boot reconcile) of an applied module changes nothing that needs a restart.
    hm_was=0
    if sg_restore_material && hm_all_applied; then hm_was=1; fi
    hsm_walk "$pkg/apply.sh" apply run
    hm_code=$?
    if [ "$hm_code" -ne 0 ]; then
        sg_log "apply.sh stopped with $hm_code; rolling back"
        sg_revert_all || { sg_status conflict none 'Apply failed and rollback conflicted; backup retained'; return $?; }
        [ "$hm_code" -ne 3 ] || { sg_status conflict none 'Target changed outside HMG-Seogaemo'; return $?; }
        sg_status failed none 'Apply failed; changes rolled back'; return $?
    fi
    if hm_hooks; then
        hm_out=$(sg_core_hook_ensure 2>&1)
        hm_code=$?
        if [ "$hm_code" -ne 0 ]; then
            sg_log "core hook host install failed ($hm_code): $hm_out"
            sg_revert_all || sg_log 'module rollback after hook host failure blocked'
            sg_core_hook_release || sg_log 'hook host release after failure blocked'
            [ "$hm_code" -ne 3 ] || { sg_status conflict none 'App hook host blocked: app_process is changed or owned elsewhere'; return $?; }
            sg_status failed none 'Could not install the app hook host; changes rolled back'; return $?
        fi
    fi
    [ "$(hm_field restart)" != head_unit ] || [ "$hm_was" -eq 1 ] || sg_restart_required || :
    hm_status
}

hm_revert() {
    ! hm_is_action || { sg_status off none 'Ready'; return $?; }
    sg_revert_all
    hm_code=$?
    [ "$hm_code" -ne 3 ] || { sg_status conflict none 'Changed outside HMG-Seogaemo; backup retained'; return $?; }
    [ "$hm_code" -eq 0 ] || { sg_status failed none 'Could not restore; backup retained'; return $?; }
    if hm_hooks; then
        sg_core_hook_release || { sg_status conflict none 'App hook host restore blocked; backup retained'; return $?; }
    fi
    if hm_reboot_class || [ "$(hm_field restart)" = head_unit ]; then
        sg_restart_required || :
        sg_print info.desired=off
        sg_status pending-restart head_unit 'Restart the head unit to restore stock behavior'; return $?
    fi
    sg_status off none 'Restored'
}

hm_watch() {
    hm_desired_on || return 3
    [ ! -f "$SG_DATA_ROOT/stock/paused" ] || return 3
    hm_gate || return $?
    HSM_RERUN=1
    export HSM_RERUN
    hsm_walk "$pkg/apply.sh" apply run || { sg_status failed none 'Re-run failed; backup retained'; return $?; }
    hm_status
}

hm_action() {
    hm_declared=0
    if [ -f "$pkg/ui.txt" ]; then
        while read -r hm_line; do
            case "$hm_line " in "button "*) ;; *) continue ;; esac
            case " $hm_line " in *" name=$1 "*) hm_declared=1 ;; esac
        done < "$pkg/ui.txt"
    fi
    [ "$hm_declared" -eq 1 ] || { sg_status failed none 'Unknown button'; return $?; }
    hm_gate || return $?
    HSM_ACTION=$1
    export HSM_ACTION
    hsm_walk "$pkg/apply.sh" apply run || { sg_status failed none 'Button action failed; backup retained'; return $?; }
    hm_status
}

[ -f "$manifest" ] && [ -d "$pkg" ] || { sg_status failed none 'Module package missing'; exit $?; }
[ "$#" -ge 1 ] || exit 2
case "$1:$#" in
    status:1) hm_status ;;
    precheck:1) hm_check && hm_status ;;
    apply:1) hm_apply ;;
    revert:1) hm_revert ;;
    action:2) hm_action "$2" ;;
    watch:2) case "$2" in boot|screen_on) hm_watch ;; *) exit 2 ;; esac ;;
    *) exit 2 ;;
esac
