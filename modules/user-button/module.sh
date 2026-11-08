#!/bin/sh
# One module for the user (star) buttons: the head-unit button (persist.sys.key.custom) and the
# steering-wheel button (persist.sys.key.swrccustom). Each enabled button gets its own fixed
# broadcast; which app it opens is chosen in the app, never passed to root. A button that is
# off keeps its stock assignment. Restore puts back the exact first-apply original.
set -eu
. "$HMG_SEOGAEMO_BASE/lib/common.sh"
ID=user-button

ub_gate() {
    [ "$(getprop ro.build.version.sdk)" = 19 ] || { sg_status incompatible none 'Requires Android 4.4'; return $?; }
    case "$(getprop ro.build.product)" in
        *.KOR.*) ;;
        *) sg_status incompatible none 'Requires Korean firmware'; return $? ;;
    esac
    for owner in hmgapi leafia; do
        if sg_owner_present "$owner"; then
            sg_status conflict none 'Another package owns user button hooks'; return $?
        fi
    done
}

ub_enabled() { [ "$(cat "$SG_DATA_ROOT/settings/$ID/$1" 2>/dev/null)" = on ]; }
ub_key() { case "$1" in head) sg_print persist.sys.key.custom;; swrc) sg_print persist.sys.key.swrccustom;; esac; }
ub_action() { case "$1" in head) sg_print com.seogaemo.hmg.USER_BUTTON_HEAD;; swrc) sg_print com.seogaemo.hmg.USER_BUTTON_SWRC;; esac; }
ub_desired_on() { [ "$(cat "$SG_DATA_ROOT/desired/$ID" 2>/dev/null)" = on ]; }
ub_baseline() { [ -f "$HMG_SEOGAEMO_STATE/prop.$(ub_key "$1")/ready" ]; }
# Our own broadcasts, including the one the separate modules wrote before the merge.
ub_ours() {
    case "$(getprop "$(ub_key "$1")")" in
        com.seogaemo.hmg.USER_BUTTON_HEAD|com.seogaemo.hmg.USER_BUTTON_SWRC|com.seogaemo.hmg.USER_BUTTON_SHORTCUT) return 0 ;;
    esac
    return 1
}

ub_status() {
    ub_gate || return $?
    ub_any=0; ub_drift=0; ub_orphan=0
    for b in head swrc; do
        if ub_baseline "$b"; then
            sg_check_build || { sg_status conflict none 'Firmware changed; backup retained'; return $?; }
            if ub_enabled "$b"; then
                ub_any=1
                [ "$(getprop "$(ub_key "$b")")" = "$(ub_action "$b")" ] || ub_drift=1
            fi
        elif ub_ours "$b"; then
            ub_orphan=1
        fi
        sg_print "info.button_$b=$(ub_enabled "$b" && echo on || echo off)"
    done
    if [ "$ub_orphan" -eq 1 ]; then sg_status conflict none 'Shortcut assignment has no restore baseline'
    elif [ "$ub_any" -eq 1 ] && [ "$ub_drift" -eq 0 ]; then sg_status on none 'User buttons open their shortcuts'
    elif [ "$ub_any" -eq 1 ] && ub_desired_on; then
        sg_print 'info.desired=on'
        sg_status pending-restart head_unit 'Button reassignment pending; watcher will restore shortcut'
    elif ub_desired_on && ! ub_enabled head && ! ub_enabled swrc; then sg_status on none 'No button assigned'
    else sg_status off none 'User button shortcuts are off'
    fi
}

ub_apply() {
    ub_gate || return $?
    for b in head swrc; do
        ub_enabled "$b" || continue
        if ub_baseline "$b"; then
            sg_check_build || { sg_status conflict none 'Firmware changed; backup retained'; return $?; }
        elif ub_ours "$b"; then
            sg_status conflict none 'Shortcut assignment has no restore baseline'; return $?
        fi
        if ! sg_prop_set "$(ub_key "$b")" "$(ub_action "$b")"; then
            code=$?
            if [ "$code" -eq 3 ]; then
                sg_status conflict none 'User button changed outside HMG-Seogaemo; backup retained'
            else
                sg_status failed none 'Could not assign user button; backup retained'
            fi
            return $?
        fi
    done
    if ! ub_enabled head && ! ub_enabled swrc; then ub_gate || return $?; sg_status on none 'No button assigned'; return $?; fi
    ub_status
}

ub_revert() {
    if sg_revert_all; then
        sg_status off none 'Previous user button assignment restored'
    else
        code=$?
        if [ "$code" -eq 3 ]; then
            sg_status conflict none 'User button changed outside HMG-Seogaemo; backup retained'
        else
            sg_status failed none 'Could not restore user button; backup retained'
        fi
    fi
}

ub_watch() {
    case "$1" in boot|screen_on) ;; *) return 2;; esac
    ub_desired_on || return 3
    [ ! -f "$SG_DATA_ROOT/stock/paused" ] || return 3
    ub_gate || return $?
    for b in head swrc; do
        ub_enabled "$b" || continue
        ub_baseline "$b" || { sg_status failed none 'Missing original button baseline'; return $?; }
        sg_check_build || { sg_status conflict none 'Firmware changed; backup retained'; return $?; }
        if [ "$(getprop "$(ub_key "$b")")" != "$(ub_action "$b")" ]; then
            sg_prop_set "$(ub_key "$b")" "$(ub_action "$b")" ||
                { sg_status failed none 'Could not reassign user button; backup retained'; return $?; }
        fi
    done
    ub_status
}

[ "$#" -ge 1 ] || exit 2
case "$1" in
    status) [ "$#" -eq 1 ] || exit 2; ub_status ;;
    precheck) [ "$#" -eq 1 ] || exit 2; sg_print 'warn.assignment=1'; ub_status ;;
    apply) [ "$#" -eq 1 ] || exit 2; ub_apply ;;
    revert) [ "$#" -eq 1 ] || exit 2; ub_revert ;;
    watch) [ "$#" -eq 2 ] || exit 2; ub_watch "$2" ;;
    *) exit 2 ;;
esac
