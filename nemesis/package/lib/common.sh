#!/system/bin/sh
# Root-only helpers; hmg-seogaemo-root holds the operation lock.
# Never fall back after a failed write: a partial write must stay a failure.
sg_write() {
    if command -v print >/dev/null 2>&1; then
        print -rn -- "$1"
    else
        (
            LC_ALL=C
            export LC_ALL
            dd bs=1 count="${#1}" 2>/dev/null <<EOF
$1
EOF
        )
    fi
}
sg_print() {
    for sg_print_line do
        if command -v print >/dev/null 2>&1; then
            print -r -- "$sg_print_line" || return 1
        else
            sg_write "$sg_print_line" && echo || return 1
        fi
    done
}
SG_DATA_ROOT=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}
SG_PROPERTY_ROOT=${SG_PROPERTY_ROOT:-/data/property}
sg_ready() { mkdir -p "$HMG_SEOGAEMO_STATE" && chmod 700 "$HMG_SEOGAEMO_STATE"; }
sg_copy() { cp "$1" "$2.tmp.$$" && mv "$2.tmp.$$" "$2"; }
sg_equal() {
    cmp "$1" "$2" >/dev/null 2>&1
}
sg_clean() {
    sg_chars=$1
    sg_output=
    while [ -n "$sg_chars" ] && [ "${#sg_output}" -lt 200 ]; do
        sg_char=${sg_chars%"${sg_chars#?}"}
        sg_chars=${sg_chars#?}
        case "$sg_char" in
            [a-zA-Z0-9]|' '|'('|')'|';'|[.,:_/+=-]) sg_output=$sg_output$sg_char ;;
            *) sg_output=$sg_output? ;;
        esac
    done
    sg_write "$sg_output"
}
sg_bind_build() {
    sg_ready || return 1
    sg_build=$(getprop ro.build.product) || return 1
    if [ -f "$HMG_SEOGAEMO_STATE/build" ]; then
        [ "$(cat "$HMG_SEOGAEMO_STATE/build")" = "$sg_build" ]
    else
        sg_write "$sg_build" > "$HMG_SEOGAEMO_STATE/build.tmp.$$" &&
            mv "$HMG_SEOGAEMO_STATE/build.tmp.$$" "$HMG_SEOGAEMO_STATE/build"
    fi
}
sg_check_build() {
    # No baseline is not a firmware mismatch; keep mutation guards closed.
    [ -f "$HMG_SEOGAEMO_STATE/build" ] || return 1
    [ "$(cat "$HMG_SEOGAEMO_STATE/build")" = "$(getprop ro.build.product)" ] ||
        { sg_log 'conflict: firmware build changed'; return 3; }
}
sg_log() {
    sg_ready || return 1
    sg_print "$(date +%s) $(sg_clean "$*")" >> "$HMG_SEOGAEMO_STATE/module.log" || return 1
    sg_bytes=$(sg_file_size "$HMG_SEOGAEMO_STATE/module.log") || return 1
    if [ "$sg_bytes" -gt 32768 ]; then
        dd if="$HMG_SEOGAEMO_STATE/module.log" of="$HMG_SEOGAEMO_STATE/module.log.tmp.$$" bs=1 skip="$((sg_bytes - 24576))" 2>/dev/null || return 1
        mv "$HMG_SEOGAEMO_STATE/module.log.tmp.$$" "$HMG_SEOGAEMO_STATE/module.log"
    fi
}
sg_file_size() {
    set -- $(ls -ln "$1") || return 1
    # Android toolbox omits the link count; desktop ls includes it.
    case "$5" in *[!0-9]*|'') sg_print "$4";; *) sg_print "$5";; esac
}
sg_prop_name() { case "$1" in ''|*[!a-zA-Z0-9_.-]*) return 2;; esac; }
sg_prop_baseline() {
    sg_prop_name "$1" && sg_bind_build || return 1
    sg_dir=$HMG_SEOGAEMO_STATE/prop.$1
    [ ! -f "$sg_dir/ready" ] || return 0
    mkdir -p "$sg_dir" || return 1
    sg_live=$(getprop "$1") || return 1
    sg_write "$sg_live" > "$sg_dir/live.tmp.$$" && mv "$sg_dir/live.tmp.$$" "$sg_dir/live" || return 1
    if [ -e "$SG_PROPERTY_ROOT/$1" ]; then
        sg_path_safe "$SG_PROPERTY_ROOT/$1" || return 3
        sg_file_meta "$SG_PROPERTY_ROOT/$1" > "$sg_dir/backing-meta" || return 1
        sg_copy "$SG_PROPERTY_ROOT/$1" "$sg_dir/backing" || return 1
        sg_exists=present
    else sg_exists=absent; fi
    sg_write "$sg_exists" > "$sg_dir/existence.tmp.$$" &&
        mv "$sg_dir/existence.tmp.$$" "$sg_dir/existence" &&
        sg_write "1" > "$sg_dir/ready.tmp.$$" && mv "$sg_dir/ready.tmp.$$" "$sg_dir/ready"
}
sg_prop_write() {
    sg_prop_name "$1" || return 2
    setprop "$1" "$2" && [ "$(getprop "$1")" = "$2" ] || return 1
    sg_dir=$HMG_SEOGAEMO_STATE/prop.$1
    if [ -f "$sg_dir/ready" ]; then
        sg_write "$2" > "$sg_dir/applied.tmp.$$" &&
            mv "$sg_dir/applied.tmp.$$" "$sg_dir/applied" || return 1
    fi
}
# Explicit owner-approved exception; unrelated properties retain exact guards.
sg_prop_drift_allowed() {
    sg_validate owns_props "$1" && sg_validate reassert_props "$1"
}
sg_prop_restore() {
    sg_prop_name "$1" || return 2
    sg_path_safe "$SG_PROPERTY_ROOT/$1" || return 3
    sg_check_build || return 3
    sg_dir=$HMG_SEOGAEMO_STATE/prop.$1
    [ -f "$sg_dir/ready" ] || return 1
    sg_live=$(cat "$sg_dir/live") || return 1
    sg_current=$(getprop "$1") || return 1
    if [ "$sg_current" != "$sg_live" ] && ! sg_prop_drift_allowed "$1"; then
        [ -f "$sg_dir/applied" ] &&
            [ "$sg_current" = "$(cat "$sg_dir/applied")" ] ||
            { sg_log "conflict: property $1 changed"; return 3; }
    fi
    sg_prop_write "$1" "$sg_live" || return 1
    case "$(cat "$sg_dir/existence")" in
        present) sg_copy "$sg_dir/backing" "$SG_PROPERTY_ROOT/$1" &&
            sg_equal "$sg_dir/backing" "$SG_PROPERTY_ROOT/$1" || return 1
            if [ -f "$sg_dir/backing-meta" ]; then
                read sg_mode sg_uid sg_gid < "$sg_dir/backing-meta" || return 1
                chown "$sg_uid:$sg_gid" "$SG_PROPERTY_ROOT/$1" &&
                    chmod "$sg_mode" "$SG_PROPERTY_ROOT/$1" &&
                    [ "$(sg_file_meta "$SG_PROPERTY_ROOT/$1")" = "$(cat "$sg_dir/backing-meta")" ] || return 1
            fi ;;
        absent) rm -f "$SG_PROPERTY_ROOT/$1" && [ ! -e "$SG_PROPERTY_ROOT/$1" ] || return 1 ;;
        *) return 1 ;;
    esac
    [ "$(getprop "$1")" = "$sg_live" ]
}
sg_file_key() {
    sg_key_digest=$(sg_write "$1" | md5 /proc/self/fd/0) || return 1
    set -- $sg_key_digest
    [ "$#" -ge 1 ] || return 1
    [ "${#1}" -eq 32 ] || return 1
    case "$1" in *[!0-9a-f]*) return 1;; esac
    sg_write "$1"
}
sg_file_meta() {
    # Android 4.4 toolbox has ls -n but no stat. Parse only the fixed mode,
    # owner and group fields; module-owned paths never contain whitespace.
    set -- $(ls -ldn "$1") || return 1
    sg_chars=${1#?}
    case "$5" in
        *[!0-9]*|'') sg_uid=$2; sg_gid=$3 ;;
        *) sg_uid=$3; sg_gid=$4 ;;
    esac
    sg_user=0; sg_group=0; sg_other=0; sg_special=0
    for sg_pos in 1 2 3 4 5 6 7 8 9; do
        sg_char=${sg_chars%"${sg_chars#?}"}
        sg_chars=${sg_chars#?}
        case "$sg_pos:$sg_char" in
            1:r) sg_user=$((sg_user + 4));; 2:w) sg_user=$((sg_user + 2));;
            3:x) sg_user=$((sg_user + 1));; 3:s) sg_user=$((sg_user + 1)); sg_special=$((sg_special + 4));;
            3:S) sg_special=$((sg_special + 4));;
            4:r) sg_group=$((sg_group + 4));; 5:w) sg_group=$((sg_group + 2));;
            6:x) sg_group=$((sg_group + 1));; 6:s) sg_group=$((sg_group + 1)); sg_special=$((sg_special + 2));;
            6:S) sg_special=$((sg_special + 2));;
            7:r) sg_other=$((sg_other + 4));; 8:w) sg_other=$((sg_other + 2));;
            9:x) sg_other=$((sg_other + 1));; 9:t) sg_other=$((sg_other + 1)); sg_special=$((sg_special + 1));;
            9:T) sg_special=$((sg_special + 1));;
            *:-) ;; *) return 1;;
        esac
    done
    sg_print "$sg_special$sg_user$sg_group$sg_other $sg_uid $sg_gid"
}
sg_file_baseline() {
    sg_path_safe "$1" || return 3
    case "$1" in /*) ;; *) return 2;; esac
    sg_bind_build || return 1
    sg_dir=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || return 1
    [ ! -f "$sg_dir/ready" ] || { [ "$(cat "$sg_dir/path")" = "$1" ]; return; }
    mkdir -p "$sg_dir" || return 1
    sg_write "$1" > "$sg_dir/path.tmp.$$" && mv "$sg_dir/path.tmp.$$" "$sg_dir/path" || return 1
    if [ -e "$1" ]; then
        [ -f "$1" ] || return 1
        sg_copy "$1" "$sg_dir/bytes" || return 1
        sg_file_meta "$1" > "$sg_dir/meta.tmp.$$" &&
            mv "$sg_dir/meta.tmp.$$" "$sg_dir/meta" || return 1
        sg_exists=present
    else sg_exists=absent; fi
    sg_write "$sg_exists" > "$sg_dir/existence.tmp.$$" &&
        mv "$sg_dir/existence.tmp.$$" "$sg_dir/existence" &&
        sg_write "1" > "$sg_dir/ready.tmp.$$" && mv "$sg_dir/ready.tmp.$$" "$sg_dir/ready"
}
sg_file_mark_applied() {
    sg_path_safe "$1" || return 3
    case "$1" in /*) ;; *) return 2;; esac
    sg_check_build || return 3
    sg_dir=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || return 1
    [ -f "$sg_dir/ready" ] && [ "$(cat "$sg_dir/path")" = "$1" ] || return 1
    if [ -e "$1" ]; then
        [ -f "$1" ] || return 1
        sg_copy "$1" "$sg_dir/applied" || return 1
        sg_file_meta "$1" > "$sg_dir/applied-meta.tmp.$$" &&
            mv "$sg_dir/applied-meta.tmp.$$" "$sg_dir/applied-meta" || return 1
        sg_exists=present
    else rm -f "$sg_dir/applied"; sg_exists=absent; fi
    sg_write "$sg_exists" > "$sg_dir/applied-existence.tmp.$$" &&
        mv "$sg_dir/applied-existence.tmp.$$" "$sg_dir/applied-existence"
}
sg_file_restore() {
    case "$1" in /*) ;; *) return 2;; esac
    sg_check_build || return 3
    sg_dir=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || return 1
    [ -f "$sg_dir/ready" ] && [ "$(cat "$sg_dir/path")" = "$1" ] || return 1
    sg_file_guard "$1" || { sg_restore_conflict "file restore: $1"; return 3; }
    if sg_file_original "$1"; then return 0; fi
    case "$(cat "$sg_dir/existence")" in
        absent) rm -f "$1" && [ ! -e "$1" ] ;;
        present)
            read sg_mode sg_uid sg_gid < "$sg_dir/meta" || return 1
            sg_copy "$sg_dir/bytes" "$1" &&
                chown "$sg_uid:$sg_gid" "$1" && chmod "$sg_mode" "$1" &&
                sg_equal "$sg_dir/bytes" "$1" &&
                [ "$(sg_file_meta "$1")" = "$sg_mode $sg_uid $sg_gid" ] ;;
        *) return 1 ;;
    esac
}
sg_restore_conflict() {
    sg_print "info.restore_conflict=$(sg_clean "$*")"
    sg_log "conflict: $*" || :
    return 3
}
# Module shells may run with noglob (set -f); the runtime globs state directories,
# so run its glob-dependent bodies with globbing on and restore the caller's flags.
sg_glob_on() {
    case $- in
        *f*) set +f; "$@"; sg_glob_rc=$?; set -f; return "$sg_glob_rc" ;; # android44-shell: allow -- fixed internal _sg_* function names from the wrappers below
    esac
    "$@" # android44-shell: allow -- fixed internal _sg_* function names from the wrappers below
}
sg_restore_preflight() { sg_glob_on _sg_restore_preflight "$@"; }
_sg_restore_preflight() {
    sg_dirs_preflight || return 3
    sg_line_preflight || return 3
    sg_check_build || { sg_restore_conflict 'build preflight: ro.build.product missing or changed'; return 3; }
    for sg_check in "$HMG_SEOGAEMO_STATE"/prop.*/ready; do
        [ -f "$sg_check" ] || continue
        sg_dir=${sg_check%/ready}
        sg_key=${sg_dir##*/prop.}
        sg_live=$(cat "$sg_dir/live") || return 1
        sg_current=$(getprop "$sg_key") || return 1
        [ "$sg_current" = "$sg_live" ] || sg_prop_drift_allowed "$sg_key" || {
            [ -f "$sg_dir/applied" ] &&
                [ "$sg_current" = "$(cat "$sg_dir/applied")" ] || {
                    sg_restore_conflict "property preflight: $sg_key"; return 3;
                }
        }
    done
    for sg_check in "$HMG_SEOGAEMO_STATE"/file.*/ready; do
        [ -f "$sg_check" ] || continue
        sg_dir=${sg_check%/ready}
        sg_path=$(cat "$sg_dir/path") || return 1
        sg_file_guard "$sg_path" || { sg_restore_conflict "file preflight: $sg_path"; return 3; }
    done
}
sg_remount() { case "$1" in rw|ro) nemesis remount "$1";; *) return 2;; esac; }
# Returning /system to read-only fails with EBUSY while a process still holds a
# replaced or removed file (the running app_process, a loaded JAR). The write has
# already been verified by then, so a failure here must not turn into a failed
# change: warn, keep the ledger consistent, and let the next restart mount it ro.
sg_remount_ro() {
    sg_remount ro && return 0
    # remount ro would have flushed the write; a car can lose power at ignition off.
    sync || :
    sg_log 'warning: /system stays read-write until restart (remount ro failed)' || :
    return 0
}
# Leftovers of our own interrupted atomic writes (power loss at ignition off).
# Exact names only: "<name>.hmg-seogaemo.<digits>" regular files (sg_commit_file
# temporaries), and zygote-prepare.<digits> / zygote-retired.<digits> directories
# directly inside the module state directory.
sg_temp_name() {
    case "$1" in
        ?*.hmg-seogaemo.*)
            sg_tn_suffix=${1##*.hmg-seogaemo.}
            case "$sg_tn_suffix" in ''|*[!0-9]*) return 1;; esac
            return 0 ;;
    esac
    return 1
}
# Remove temporaries of one owned file, or all of them inside a created directory.
sg_sweep_temps() (
    set +f
    sg_path_safe "$1" || exit 3
    if [ -d "$1" ]; then
        for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
            [ -f "$entry" ] && [ ! -L "$entry" ] || continue
            sg_temp_name "${entry##*/}" || continue
            rm -f "$entry" || exit 1
            sg_ledger temp_sweep "$entry" "" "" "" || exit 1
        done
    else
        for entry in "$1".hmg-seogaemo.*; do
            [ -f "$entry" ] && [ ! -L "$entry" ] || continue
            sg_temp_name "${entry##*/}" || continue
            rm -f "$entry" || exit 1
            sg_ledger temp_sweep "$entry" "" "" "" || exit 1
        done
    fi
)
sg_zygote_sweep() (
    set +f
    [ -n "$HMG_SEOGAEMO_STATE" ] || exit 2
    for entry in "$HMG_SEOGAEMO_STATE"/zygote-prepare.* "$HMG_SEOGAEMO_STATE"/zygote-retired.*; do
        [ -d "$entry" ] && [ ! -L "$entry" ] || continue
        case "${entry##*.}" in ''|*[!0-9]*) continue;; esac
        rm -rf "$entry" || exit 1
    done
)
sg_baseline_clear() { sg_glob_on _sg_baseline_clear "$@"; }
_sg_baseline_clear() {
    [ -n "$HMG_SEOGAEMO_STATE" ] || return 2
    rm -rf "$HMG_SEOGAEMO_STATE"/prop.* "$HMG_SEOGAEMO_STATE"/file.* "$HMG_SEOGAEMO_STATE"/bind.*
    rm -f "$HMG_SEOGAEMO_STATE/build" "$HMG_SEOGAEMO_STATE/changes"
    rm -rf "$HMG_SEOGAEMO_STATE/zygote-upgrade"
    sg_zygote_sweep
}
# Package-only mutation API. Metadata comes from the packaged, generated
# module.properties; callers cannot nominate an arbitrary target.
# Built-in, installed, then the runtime-generated core hook host manifest.
sg_manifest_file() {
    sg_mf_id=${HMG_SEOGAEMO_STATE##*/}
    for sg_mf in "$HMG_SEOGAEMO_BASE/modules/$sg_mf_id.properties" "$SG_DATA_ROOT/installed/$sg_mf_id.properties"; do
        [ ! -f "$sg_mf" ] || { sg_print "$sg_mf"; return 0; }
    done
    [ "$sg_mf_id" = core-hook ] && [ -f "$SG_DATA_ROOT/core/hook/core-hook.properties" ] || return 2
    sg_print "$SG_DATA_ROOT/core/hook/core-hook.properties"
}
sg_validate() {
    [ -n "$HMG_SEOGAEMO_BASE" ] && [ -n "$HMG_SEOGAEMO_STATE" ] || return 2
    sg_manifest=$(sg_manifest_file) || return 2
    sg_found=0
    while IFS='=' read -r sg_field sg_values; do
        [ "$sg_field" = "$1" ] || continue
        case ",$sg_values," in *,"$2",*) sg_found=1;; esac
    done < "$sg_manifest"
    [ "$sg_found" -eq 1 ]
}
# Module catalog: package built-ins in generated order, then installed packages
# in install order. An installed module may depend only on earlier entries.
sg_module_list() { cat "$1/modules.list" "$SG_DATA_ROOT/installed.list" 2>/dev/null; }
sg_module_graph() { cat "$1/modules.graph" "$SG_DATA_ROOT/installed.graph" 2>/dev/null; }
sg_module_builtin() { grep -Fxq "$2" "$1/modules.list" 2>/dev/null; }
sg_module_known() { sg_module_list "$1" | grep -Fxq "$2"; }
sg_module_props() {
    if sg_module_builtin "$1" "$2"; then sg_print "$1/modules/$2.properties"
    else sg_print "$SG_DATA_ROOT/installed/$2.properties"; fi
}
sg_module_script() {
    if sg_module_builtin "$1" "$2"; then sg_print "$1/modules/$2.sh"
    else sg_print "$1/core/hsm-module.sh"; fi
}
sg_module_dir() {
    if sg_module_builtin "$1" "$2"; then sg_print "$1/modules/$2.d"
    else sg_print "$SG_DATA_ROOT/installed/$2"; fi
}
sg_module_field() {
    sg_mf_value=
    while IFS='=' read -r sg_mf_key sg_mf_val; do
        [ "$sg_mf_key" = "$2" ] && sg_mf_value=$sg_mf_val
    done < "$1"
    sg_write "$sg_mf_value"
}
# Resource modes: read never conflicts, only conflicts with every other mode,
# use is shared, and two different named modes conflict.
sg_uses_clash() {
    case "$1:$2" in read:*|*:read) return 1;; only:*|*:only) return 0;; use:*|*:use) return 1;; esac
    [ "$1" != "$2" ]
}
sg_resource_overlap() {
    [ "$1" = "$2" ] && return 0
    case "$1" in "$2".*) return 0;; esac
    case "$2" in "$1".*) return 0;; esac
    return 1
}
# Prints the first enabled module that shares an owned property or clashes on a
# declared resource with module $2 (whole files and lines are refused at install).
sg_module_clash() {
    sg_mc_props=$(sg_module_props "$1" "$2")
    sg_mc_own=,$(sg_module_field "$sg_mc_props" owns_props),
    sg_mc_uses=$(sg_module_field "$sg_mc_props" uses)
    for sg_mc_other in $(sg_module_list "$1"); do
        [ "$sg_mc_other" != "$2" ] || continue
        [ "$(cat "$SG_DATA_ROOT/desired/$sg_mc_other" 2>/dev/null)" = on ] || continue
        sg_mc_other_props=$(sg_module_props "$1" "$sg_mc_other")
        [ -f "$sg_mc_other_props" ] || continue
        sg_mc_ifs=$IFS
        IFS=,
        for sg_mc_prop in $(sg_module_field "$sg_mc_other_props" owns_props); do
            case "$sg_mc_own" in *",$sg_mc_prop,"*) IFS=$sg_mc_ifs; sg_print "$sg_mc_other"; return 0;; esac
        done
        for sg_mc_mine in $sg_mc_uses; do
            for sg_mc_theirs in $(sg_module_field "$sg_mc_other_props" uses); do
                sg_mc_a=use; sg_mc_b=use
                case "$sg_mc_mine" in *:*) sg_mc_a=${sg_mc_mine#*:};; esac
                case "$sg_mc_theirs" in *:*) sg_mc_b=${sg_mc_theirs#*:};; esac
                if sg_resource_overlap "${sg_mc_mine%%:*}" "${sg_mc_theirs%%:*}" &&
                    sg_uses_clash "$sg_mc_a" "$sg_mc_b"; then
                    IFS=$sg_mc_ifs; sg_print "$sg_mc_other"; return 0
                fi
            done
        done
        IFS=$sg_mc_ifs
    done
    return 1
}
sg_payload() {
    case "$1" in ''|/*|*..*|*[!a-zA-Z0-9_./-]*) return 2;; esac
    sg_source=$HMG_SEOGAEMO_MODULE_DIR/$1
    [ -f "$sg_source" ] && [ ! -L "$sg_source" ]
}
sg_ledger() {
    sg_ledger_dir=$SG_DATA_ROOT/ledger
    mkdir -p "$sg_ledger_dir/before" "$sg_ledger_dir/after" || return 1
    [ -f "$sg_ledger_dir/ledger.tsv" ] ||
        sg_print "time	module	op	target	before-ref	after-ref	result" > "$sg_ledger_dir/ledger.tsv" || return 1
    sg_stamp=$(date +%s).$$.${SG_LEDGER_SEQ:-0}
    # Subshell transactions do not propagate their counters to the caller.
    # Preserve every referenced record even within the same second and PID.
    while [ -e "$sg_ledger_dir/before/$sg_stamp" ] || [ -e "$sg_ledger_dir/after/$sg_stamp" ]; do
        SG_LEDGER_SEQ=$((${SG_LEDGER_SEQ:-0} + 1))
        sg_stamp=$(date +%s).$$.$SG_LEDGER_SEQ
    done
    SG_LEDGER_SEQ=$((${SG_LEDGER_SEQ:-0} + 1))
    sg_before=before/$sg_stamp
    sg_after=after/$sg_stamp
    if [ -f "$3" ]; then sg_copy "$3" "$sg_ledger_dir/$sg_before" || return 1
    else sg_write "absent" > "$sg_ledger_dir/$sg_before" || return 1; fi
    if [ -f "$4" ]; then sg_copy "$4" "$sg_ledger_dir/$sg_after" || return 1
    else sg_write "absent" > "$sg_ledger_dir/$sg_after" || return 1; fi
    if [ -n "$5" ] && [ -f "$5" ]; then sg_copy "$5" "$sg_ledger_dir/$sg_before.meta" || return 1; fi
    sg_print "$(date +%s)	${HMG_SEOGAEMO_STATE##*/}	$1	$2	$sg_before	$sg_after	${6:-ok}" >> "$sg_ledger_dir/ledger.tsv"
}
# One line per changed target: repeated applies must not grow the file.
sg_changed() {
    grep -Fxq "$1	$2" "$HMG_SEOGAEMO_STATE/changes" 2>/dev/null && return 0
    sg_print "$1	$2" >> "$HMG_SEOGAEMO_STATE/changes"
}
sg_prop_set() {
    sg_validate owns_props "$1" || return 2
    sg_prop_baseline "$1" || return 1
    sg_prop_write "$1" "$2" || return 1
    sg_ledger prop_set "$1" "$HMG_SEOGAEMO_STATE/prop.$1/live" "$HMG_SEOGAEMO_STATE/prop.$1/applied" "" || return 1
    sg_changed prop "$1"
}
sg_path_safe() (
    case "$1" in /*) ;; *) exit 2;; esac
    case "$1" in *..*|*//*|*[!a-zA-Z0-9_./@+-]*) exit 2;; esac
    check=$1
    while [ -n "$check" ]; do
        [ ! -L "$check" ] || exit 3
        check=${check%/*}
    done
)
sg_file_original() (
    sg_path_safe "$1" || exit 3
    saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || exit 1
    case "$(cat "$saved/existence")" in
        absent) [ ! -e "$1" ] ;;
        present) [ -f "$1" ] && sg_equal "$saved/bytes" "$1" &&
            [ "$(sg_file_meta "$1")" = "$(cat "$saved/meta")" ] ;;
        *) exit 3;;
    esac
)
sg_file_applied() (
    sg_path_safe "$1" || exit 3
    saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || exit 1
    case "$(cat "$saved/applied-existence" 2>/dev/null)" in
        absent) [ ! -e "$1" ] ;;
        present)
            [ -f "$1" ] && sg_equal "$saved/applied" "$1" || exit 3
            if [ ! -f "$saved/applied-meta" ]; then
                # Legacy markers guarded bytes only. Backfill after byte verification.
                sg_file_meta "$1" > "$saved/applied-meta.tmp.$$" &&
                    mv "$saved/applied-meta.tmp.$$" "$saved/applied-meta" || exit 1
            fi
            [ "$(sg_file_meta "$1")" = "$(cat "$saved/applied-meta")" ] ;;
        *) exit 3;;
    esac
)
sg_zygote_prepared() (
    sg_path_safe "$1" && sg_check_build || exit 3
    journal=$HMG_SEOGAEMO_STATE/zygote-upgrade
    [ -f "$journal/ready" ] || exit 3
    key=$(sg_file_key "$1") || exit 1
    if [ -f "$journal/dex.$key" ]; then
        [ ! -e "$1" ]; exit $?
    fi
    [ "$(cat "$journal/$key/path" 2>/dev/null)" = "$1" ] &&
        sg_equal "$journal/$key/next" "$1" &&
        [ "$(sg_file_meta "$1")" = "$(cat "$journal/$key/meta")" ]
)
sg_file_guard() { sg_file_original "$1" || sg_file_applied "$1" || sg_zygote_prepared "$1"; }

# Directory journals and per-module references protect shared parents.
sg_dir_guard() (
    record=$1
    [ "$(cat "$record/build")" = "$(getprop ro.build.product)" ] || exit 3
    target=$(cat "$record/path") || exit 1
    sg_path_safe "$target" || exit 3
    if [ ! -e "$target" ]; then
        [ "$(cat "$record/existence")" = absent ]; exit $?
    fi
    [ -d "$target" ] || exit 3
    meta=$(sg_file_meta "$target") || exit 1
    versions="applied pending intermediate restore-pending restore-intermediate"
    if [ ! -f "$record/applied" ] || [ -f "$record/restored" ]; then versions="$versions meta"; fi
    for version in $versions; do
        [ ! -f "$record/$version" ] || [ "$meta" != "$(cat "$record/$version")" ] || exit 0
    done
    exit 3
)
sg_dir_ensure() (
    target=$1
    sg_path_safe "$target" || { sg_restore_conflict "dir apply: $target"; exit 3; }
    key=$(sg_file_key "$target") || exit 1
    record=$SG_DATA_ROOT/payload-dirs/$key
    namespace=${SG_TARGET_ROOT:-}/system/etc/hmg-seogaemo
    module=${HMG_SEOGAEMO_STATE##*/}
    case "$target" in
        "$namespace"|"$namespace/$module"|"$namespace/$module/"*) track=1 ;;
        "$namespace/"*) exit 2 ;;
        *) if [ -f "$record/ready" ] || [ ! -d "$target" ]; then track=1; else track=0; fi ;;
    esac
    [ "$track" -eq 1 ] || exit 0
    sg_bind_build || exit 1
    if [ ! -f "$record/ready" ]; then
        mkdir -p "$record/refs" || exit 1
        sg_write "$target" > "$record/path" &&
            getprop ro.build.product > "$record/build" || exit 1
        if [ -e "$target" ]; then
            [ -d "$target" ] || exit 3
            sg_file_meta "$target" > "$record/meta" || exit 1
            sg_write present > "$record/existence" || exit 1
        else
            sg_write absent > "$record/existence" || exit 1
        fi
        sg_write 1 > "$record/ready" || exit 1
    fi
    [ "$(cat "$record/path")" = "$target" ] && sg_dir_guard "$record" || {
        sg_restore_conflict "dir apply: $target"; exit 3;
    }
    # Publish order before the reference: a failed write cannot hide a mutation
    # from deepest-first recovery. Reapply also repairs interrupted registration.
    if ! grep -Fxq "$record" "$HMG_SEOGAEMO_STATE/dir-order" 2>/dev/null; then
        sg_print "$record" >> "$HMG_SEOGAEMO_STATE/dir-order" || exit 1
    fi
    sg_write "$record" > "$HMG_SEOGAEMO_STATE/dir.$key" || exit 1
    sg_write 1 > "$record/refs/$module" || exit 1
    sg_print "0755 0 0" > "$record/pending" || exit 1
    if [ -d "$target" ]; then
        before=$(sg_file_meta "$target") || exit 1
        if [ "$before" = "0755 0 0" ]; then
            sg_copy "$record/pending" "$record/applied" &&
                rm -f "$record/pending" "$record/intermediate" "$record/restored" "$record/restore-pending" "$record/restore-intermediate"
            exit $?
        fi
        set -- $before
        sg_print "$1 0 0" > "$record/intermediate" || exit 1
    fi
    sync || exit 1
    (umask 022; mkdir -p "$target") && chown 0:0 "$target" && chmod 0755 "$target" &&
        [ "$(sg_file_meta "$target")" = "0755 0 0" ] || exit 1
    sg_copy "$record/pending" "$record/applied" || exit 1
    rm -f "$record/pending" "$record/intermediate" "$record/restored" "$record/restore-pending" "$record/restore-intermediate" || exit 1
    sg_ledger directory "$target" "$record/meta" "$record/applied" "$record/meta" || exit 1
)
sg_payload_dirs() (
    [ "$#" -eq 1 ] && sg_validate owns_files "$1" && sg_whole_exclusive "$1" || exit 2
    sg_path_safe "$1" || exit 3
    logical=${1#"${SG_TARGET_ROOT:-}"}
    case "$logical" in /system/*) ;; *) exit 0;; esac
    chain=
    parent=${1%/*}
    while [ "$parent" != "${SG_TARGET_ROOT:-}" ] && [ -n "$parent" ]; do
        chain="$parent $chain"
        parent=${parent%/*}
    done
    sg_remount rw || exit 1
    rc=0
    for parent in $chain; do sg_dir_ensure "$parent" || { rc=$?; break; }; done
    sg_remount_ro
    exit "$rc"
)
sg_dirs_preflight() (
    set +f
    for ref in "$HMG_SEOGAEMO_STATE"/dir.*; do
        [ -f "$ref" ] || continue
        record=$(cat "$ref") || exit 1
        [ -f "$record/ready" ] || continue
        sg_dir_guard "$record" || {
            sg_restore_conflict "dir preflight: $(cat "$record/path")"; exit 3;
        }
    done
)
sg_dirs_revert() (
    set +f
    [ -f "$HMG_SEOGAEMO_STATE/dir-order" ] || exit 0
    reverse=
    while IFS= read -r record; do reverse="$record $reverse"; done < "$HMG_SEOGAEMO_STATE/dir-order"
    for record in $reverse; do
        [ -f "$record/ready" ] || continue
        sg_dir_guard "$record" || {
            sg_restore_conflict "dir restore: $(cat "$record/path")"; exit 3;
        }
        module=${HMG_SEOGAEMO_STATE##*/}
        other=0
        for ref in "$record"/refs/*; do
            [ ! -f "$ref" ] || [ "${ref##*/}" = "$module" ] || other=1
        done
        if [ "$other" -eq 1 ]; then rm -f "$record/refs/$module"; continue; fi
        target=$(cat "$record/path") || exit 1
        sg_remount rw || exit 1
        rc=0
        case "$(cat "$record/existence")" in
            absent)
                # Only our own interrupted-write temporaries may keep a created dir alive.
                if [ -e "$target" ]; then sg_sweep_temps "$target" && rmdir "$target" || rc=3; fi ;;
            present)
                read mode uid gid < "$record/meta" || exit 1
                current=$(sg_file_meta "$target") || exit 1
                set -- $current
                sg_print "$1 $uid $gid" > "$record/restore-intermediate" &&
                    sg_copy "$record/meta" "$record/restore-pending" && sync || exit 1
                chown "$uid:$gid" "$target" && chmod "$mode" "$target" &&
                    [ "$(sg_file_meta "$target")" = "$(cat "$record/meta")" ] || rc=1 ;;
            *) rc=3;;
        esac
        sg_remount_ro
        [ "$rc" -eq 0 ] || exit "$rc"
        sg_write 1 > "$record/restored" || exit 1
        sg_ledger directory_revert "$target" "$record/applied" "$record/meta" "$record/meta" || exit 1
        rm -rf "$record" || exit 1
    done
    rm -f "$HMG_SEOGAEMO_STATE"/dir.* "$HMG_SEOGAEMO_STATE/dir-order"
)
sg_mkdir_target() { mkdir -p "$1"; }
sg_restart_required() {
    sg_ready && cat "${SG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" > "$HMG_SEOGAEMO_STATE/assets-repaired-boot.tmp.$$" &&
        mv "$HMG_SEOGAEMO_STATE/assets-repaired-boot.tmp.$$" "$HMG_SEOGAEMO_STATE/assets-repaired-boot"
}
sg_restart_pending() {
    [ -f "$HMG_SEOGAEMO_STATE/assets-repaired-boot" ] &&
        [ "$(cat "$HMG_SEOGAEMO_STATE/assets-repaired-boot")" = "$(cat "${SG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}")" ]
}
# Root access(2) bypasses DAC: inspect public read/search bits explicitly.
sg_public_readable() (
    target=$1
    sg_path_safe "$target" && [ -f "$target" ] || exit 1
    set -- $(sg_file_meta "$target")
    case "$1" in *[4567]) ;; *) exit 1;; esac
    parent=${target%/*}
    while [ -n "$parent" ] && [ "$parent" != "${SG_TARGET_ROOT:-}" ]; do
        set -- $(sg_file_meta "$parent")
        case "$1" in *[1357]) ;; *) exit 1;; esac
        parent=${parent%/*}
    done
)
# Call only for dedicated export containers, never USB roots or private state.
sg_export_public() (
    set +f
    sg_path_safe "$1" && [ -d "$1" ] || exit 3
    chmod 0755 "$1" || exit 1
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ ! -L "$entry" ] || exit 3
        [ -e "$entry" ] || continue
        if [ -d "$entry" ]; then sg_export_public "$entry" || exit 1
        elif [ -f "$entry" ]; then chmod 0644 "$entry" || exit 1
        else exit 3; fi
    done
)
# Size in bytes of a regular file from toolbox ls -l (no stat on the unit).
sg_file_size() (
    set -f
    sg_fs_line=$(ls -ln "$1" 2>/dev/null) || exit 1
    set -- $sg_fs_line
    case "$5" in *[!0-9]*|'') sg_fs_size=$4;; *) sg_fs_size=$5;; esac
    case "$sg_fs_size" in ''|*[!0-9]*) exit 1;; esac
    sg_write "$sg_fs_size"
)
sg_export_sizes() (
    set +f
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$entry" ] || continue
        if [ -d "$entry" ]; then sg_export_sizes "$entry" "$2${entry##*/}/" || exit 1
        elif [ -f "$entry" ]; then
            size=$(sg_file_size "$entry") || exit 1
            sg_print "$size	$2${entry##*/}" || exit 1
        fi
    done
)
# The head unit mounts the stick write-back: a name can reach the stick while its
# data has not. Record every file size in MANIFEST, sync, and (usb) re-read: each
# file must keep its recorded size and each key file must match its source size.
# Key arguments: "<relative path>=<source file>" or "<relative path>" (non-empty).
# Returns 1 when the export could not be written, 4 when it was not flushed.
sg_export_seal() (
    set +f
    sg_path_safe "$1" && [ -d "$1" ] || exit 3
    sg_es_dest=$1; sg_es_mode=$2; shift 2
    sg_es_sizes=$(sg_export_sizes "$sg_es_dest" '') || exit 1
    sg_print "$sg_es_sizes" > "$sg_es_dest/MANIFEST" && chmod 0644 "$sg_es_dest/MANIFEST" || exit 1
    sync || exit 4
    [ "$sg_es_mode" = usb ] || exit 0
    while IFS='	' read -r sg_es_size sg_es_rel; do
        [ -n "$sg_es_rel" ] || continue
        [ "$(sg_file_size "$sg_es_dest/$sg_es_rel")" = "$sg_es_size" ] || exit 4
    done < "$sg_es_dest/MANIFEST"
    for sg_es_key do
        sg_es_rel=${sg_es_key%%=*}
        sg_es_have=$(sg_file_size "$sg_es_dest/$sg_es_rel") || exit 4
        [ "$sg_es_have" -gt 0 ] || exit 4
        case "$sg_es_key" in *=*)
            sg_es_want=$(sg_file_size "${sg_es_key#*=}") || exit 4
            [ "$sg_es_have" = "$sg_es_want" ] || exit 4 ;;
        esac
    done
    exit 0
)
sg_commit_file() (
    sg_target=$1; sg_input=$2; sg_mode=$3; sg_owner=$4
    sg_validate owns_files "$sg_target" || return 2
    sg_whole_exclusive "$sg_target" || return 3
    sg_file_baseline "$sg_target" || return 1
    sg_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$sg_target") || return 1
    if [ -z "$sg_mode" ] || [ -z "$sg_owner" ]; then
        if [ -f "$sg_saved/meta" ]; then
            read sg_old_mode sg_old_uid sg_old_gid < "$sg_saved/meta" || return 1
        else sg_old_mode=0644; sg_old_uid=0; sg_old_gid=0; fi
        [ -n "$sg_mode" ] || sg_mode=$sg_old_mode
        [ -n "$sg_owner" ] || sg_owner=$sg_old_uid:$sg_old_gid
    fi
    sg_write "$sg_mode" | grep -Eq '^0?[0-7]{3,4}$' || return 2
    # Existing module manifests use the unambiguous Android root alias.
    [ "$sg_owner" != root:root ] || sg_owner=0:0
    sg_write "$sg_owner" | grep -Eq '^[0-9]+:[0-9]+$' || return 2
    if [ -f "$sg_saved/applied-existence" ]; then
        sg_file_guard "$sg_target" || { sg_restore_conflict "file apply: $sg_target"; return 3; }
    fi
    sg_payload_dirs "$sg_target" || return $?
    case "${sg_target#"${SG_TARGET_ROOT:-}"}" in /system/*) sg_remount rw || return 1; sg_system=1;; *) sg_system=0;; esac
    sg_expected_mode=$sg_mode
    [ "${#sg_expected_mode}" -eq 3 ] && sg_expected_mode=0$sg_expected_mode
    sg_tmp=$sg_target.hmg-seogaemo.$$
    sg_rc=0
    sg_mkdir_target "${sg_target%/*}" &&
        cp "$sg_input" "$sg_tmp" &&
        { chown "${sg_owner%:*}.${sg_owner#*:}" "$sg_tmp" 2>/dev/null ||
            chown "$sg_owner" "$sg_tmp"; } &&
        chmod "$sg_mode" "$sg_tmp" &&
        [ "$(sg_file_meta "$sg_tmp")" = "$sg_expected_mode ${sg_owner%:*} ${sg_owner#*:}" ] &&
        mv "$sg_tmp" "$sg_target" &&
        sg_equal "$sg_input" "$sg_target" || sg_rc=1
    sg_expected_mode=$sg_mode
    [ "${#sg_expected_mode}" -eq 3 ] && sg_expected_mode=0$sg_expected_mode
    if [ "$sg_rc" -eq 0 ]; then
        set -- $(sg_file_meta "$sg_target")
        [ "$1 $2 $3" = "$sg_expected_mode ${sg_owner%:*} ${sg_owner#*:}" ] || sg_rc=1
    fi
    rm -f "$sg_tmp"
    if [ "$sg_system" -eq 1 ]; then sg_remount_ro; fi
    [ "$sg_rc" -eq 0 ] || return 1
    sg_file_mark_applied "$sg_target" || return 1
    sg_ledger file_put "$sg_target" "$sg_saved/bytes" "$sg_saved/applied" "$sg_saved/meta" || return 1
    sg_changed file "$sg_target"
)
sg_file_put() {
    sg_validate owns_files "$1" && sg_payload "$2" || return 2
    sg_commit_file "$1" "$sg_source" "${3:-}" "${4:-}"
}
# Shared text transactions. Subshells keep their scratch variables out of the
# existing whole-file runtime. The dispatcher holds the global operation lock.
sg_line_text() {
    [ "$#" -eq 1 ] || return 2
    [ "$(sg_write "$1" | LC_ALL=C grep -c '[[:cntrl:]]')" = 0 ] || return 2
    case "$1" in *'
'*) return 2;; esac
}
sg_line_claim() (
    sg_line_text "$2" || exit 2
    while IFS='=' read -r key value; do
        case "$key" in owns_lines.*)
            [ "$value" != "$1:$2" ] || exit 0 ;;
        esac
    done < "$HMG_SEOGAEMO_BASE/modules/${HMG_SEOGAEMO_STATE##*/}.properties"
    exit 2
)
sg_whole_exclusive() (
    set +f
    # The core hook host shares the app_process files with the CarPlay module; only the
    # owner that currently holds a baseline excludes the other.
    if [ "${HMG_SEOGAEMO_STATE##*/}" = core-hook ]; then
        key=$(sg_file_key "$1") || exit 1
        for ready in "$SG_DATA_ROOT"/modules/*/file."$key"/ready; do
            case "$ready" in "$HMG_SEOGAEMO_STATE"/*) continue;; esac
            [ ! -f "$ready" ] || exit 3
        done
        exit 0
    fi
    for manifest in "$HMG_SEOGAEMO_BASE"/modules/*.properties; do
        [ "$manifest" != "$HMG_SEOGAEMO_BASE/modules/${HMG_SEOGAEMO_STATE##*/}.properties" ] || continue
        while IFS='=' read -r key value; do
            case "$key" in
                owns_files) case ",$value," in *,"$1",*) exit 3;; esac ;;
                owns_lines.*) [ "${value%%:*}" != "$1" ] || exit 3 ;;
            esac
        done < "$manifest"
    done
)
sg_line_authorize() (
    set +f
    sg_line_claim "$1" "$2" || exit 2
    module=${HMG_SEOGAEMO_STATE##*/}
    for manifest in "$HMG_SEOGAEMO_BASE"/modules/*.properties; do
        other=${manifest##*/}; other=${other%.properties}
        while IFS='=' read -r key value; do
            case "$key" in
                owns_files) case ",$value," in *,"$1",*) exit 3;; esac ;;
                owns_lines.*)
                    [ "$other" != "$module" ] || continue
                    if [ "$value" = "$1:$2" ] &&
                        [ "$(cat "$SG_DATA_ROOT/desired/$other" 2>/dev/null)" = on ]; then exit 3; fi ;;
            esac
        done < "$manifest"
    done
    # Do not reinterpret an earlier runtime's whole-file baseline as stock.
    path_key=$(sg_file_key "$1") || exit 1
    for saved in "$SG_DATA_ROOT"/modules/*/file."$path_key"/ready; do
        [ ! -f "$saved" ] || exit 3
    done
)
sg_line_guard() (
    path_key=$(sg_file_key "$1") || exit 1
    shared=$SG_DATA_ROOT/shared-lines/$path_key
    [ -f "$shared/ready" ] || exit 1
    [ "$(cat "$shared/path")" = "$1" ] &&
        [ "$(cat "$shared/build")" = "$(getprop ro.build.product)" ] &&
        [ -f "$1" ] && [ ! -L "$1" ] &&
        [ "$(sg_file_meta "$1")" = "$(cat "$shared/meta")" ] || exit 3
    expected=$shared/bytes
    if [ -f "$shared/active" ]; then
        version=$(cat "$shared/active") || exit 1
        case "$version" in v[0-9]* ) ;; *) exit 3;; esac
        expected=$shared/versions/$version/bytes
    fi
    sg_equal "$expected" "$1" && exit 0
    if [ -f "$shared/pending" ]; then
        version=$(cat "$shared/pending") || exit 1
        sg_equal "$shared/versions/$version/bytes" "$1" && exit 0
    fi
    exit 3
)
sg_line_audit() (
    set +f
    transaction=$1
    module=$(cat "$transaction/module") || exit 1
    HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/modules/$module
    for event in "$transaction"/events/*; do
        [ -d "$event" ] || continue
        op=$(cat "$event/op") || exit 1
        sg_ledger "$op" "$(cat "$transaction/path")" "$event/old" "$event/new" "$transaction/hashes" || exit 1
    done
    sg_ledger line_compose "$(cat "$transaction/path")" "$transaction/before" "$transaction/bytes" "$transaction/hashes"
)
sg_line_recover() (
    target=$1
    path_key=$(sg_file_key "$target") || exit 1
    shared=$SG_DATA_ROOT/shared-lines/$path_key
    sg_line_guard "$target" || exit $?
    [ -f "$shared/pending" ] || exit 0
    version=$(cat "$shared/pending") || exit 1
    transaction=$shared/versions/$version
    if sg_equal "$transaction/bytes" "$target"; then
        sg_line_audit "$transaction" || exit 1
        sg_copy "$shared/pending" "$shared/active" || exit 1
        sync || exit 1
    fi
    rm -f "$shared/pending"
)
sg_line_baseline() (
    target=$1
    path_key=$(sg_file_key "$target") || exit 1
    shared=$SG_DATA_ROOT/shared-lines/$path_key
    [ ! -f "$shared/ready" ] || { sg_line_recover "$target"; exit $?; }
    [ -f "$target" ] && [ ! -L "$target" ] || exit 3
    stage=$shared.init.$$
    mkdir -p "$stage/versions" || exit 1
    chmod 700 "$SG_DATA_ROOT/shared-lines" "$stage" || exit 1
    sg_copy "$target" "$stage/bytes" &&
        sg_file_meta "$target" > "$stage/meta" &&
        sg_write "$target" > "$stage/path" &&
        getprop ro.build.product > "$stage/build" &&
        sg_write present > "$stage/existence" &&
        sg_write 1 > "$stage/ready" &&
        mv "$stage" "$shared" || exit 1
)
# Compose each output line from the original input. Patch output is never fed
# into another patch, even when its text equals a different stock line.
sg_line_compose() (
    set +f
    shared=$1; next=$2
    for patch in "$next"/patches/*/*; do
        [ -d "$patch" ] || continue
        owner=${patch%/*}; owner=${owner##*/}
        grep -Fxq "$owner" "$HMG_SEOGAEMO_BASE/modules.list" || exit 3
        old=$(cat "$patch/old") || exit 1
        count=0
        while IFS= read -r line || [ -n "$line" ]; do
            [ "$line" != "$old" ] || count=$((count + 1))
        done < "$shared/bytes"
        [ "$count" -eq 1 ] || exit 3
    done
    : > "$next/bytes" || exit 1
    while :; do
        line=; newline=1
        IFS= read -r line || newline=0
        [ "$newline" -eq 1 ] || [ -n "$line" ] || break
        output=$line; matches=0
        while IFS= read -r module; do
            for patch in "$next/patches/$module"/*; do
                [ -d "$patch" ] || continue
                if [ "$(cat "$patch/old")" = "$line" ]; then
                    matches=$((matches + 1))
                    output=$(cat "$patch/new") || exit 1
                fi
            done
        done < "$HMG_SEOGAEMO_BASE/modules.list"
        [ "$matches" -le 1 ] || exit 3
        if [ "$newline" -eq 1 ]; then sg_print "$output"; else sg_write "$output"; fi >> "$next/bytes" || exit 1
        [ "$newline" -eq 1 ] || break
    done < "$shared/bytes"
)
sg_line_transaction() (
    set +f
    target=$1; action=$2; old=${3:-}; new=${4:-}
    module=${HMG_SEOGAEMO_STATE##*/}
    sg_line_baseline "$target" || exit $?
    path_key=$(sg_file_key "$target") || exit 1
    shared=$SG_DATA_ROOT/shared-lines/$path_key
    sg_line_guard "$target" || exit $?
    version=v$(date +%s).$$; serial=0
    while [ -e "$shared/versions/$version" ]; do serial=$((serial + 1)); version=v$(date +%s).$$.$serial; done
    next=$shared/versions/$version
    mkdir -p "$next/patches" "$next/events" || exit 1
    if [ -f "$shared/active" ]; then
        previous=$(cat "$shared/active") || exit 1
        cp -R "$shared/versions/$previous/patches/." "$next/patches/" || exit 1
    fi
    mkdir -p "$HMG_SEOGAEMO_STATE/line.$path_key" || exit 1
    marker=$HMG_SEOGAEMO_STATE/line.$path_key
    sg_write "$target" > "$marker/path.tmp.$$" &&
        mv "$marker/path.tmp.$$" "$marker/path" &&
        sg_write 1 > "$marker/ready.tmp.$$" &&
        mv "$marker/ready.tmp.$$" "$marker/ready" || exit 1
    sg_bind_build || exit 3
    if [ "$action" = apply ]; then
        # Refuse an already applied same-line patch, even if desired=off.
        for patch in "$next"/patches/*/*; do
            [ -d "$patch" ] || continue
            owner=${patch%/*}; owner=${owner##*/}
            if [ "$(cat "$patch/old")" = "$old" ] && [ "$owner" != "$module" ]; then exit 3; fi
        done
        number=
        while IFS='=' read -r key value; do
            case "$key" in owns_lines.*) [ "$value" != "$target:$old" ] || number=${key#owns_lines.};; esac
        done < "$HMG_SEOGAEMO_BASE/modules/$module.properties"
        case "$number" in ''|*[!0-9]*) exit 2;; esac
        patch=$next/patches/$module/$number
        mkdir -p "$patch" "$next/events/$number" || exit 1
        sg_write "$old" > "$patch/old" && sg_write "$new" > "$patch/new" &&
            cp "$patch/old" "$next/events/$number/old" &&
            cp "$patch/new" "$next/events/$number/new" &&
            sg_write line_patch > "$next/events/$number/op" || exit 1
    else
        for patch in "$next/patches/$module"/*; do
            [ -d "$patch" ] || continue
            number=${patch##*/}
            mkdir -p "$next/events/$number" &&
                cp "$patch/new" "$next/events/$number/old" &&
                cp "$patch/old" "$next/events/$number/new" &&
                sg_write line_revert > "$next/events/$number/op" || exit 1
        done
        rm -rf "$next/patches/$module" || exit 1
    fi
    sg_line_compose "$shared" "$next" || exit $?
    sg_copy "$target" "$next/before" && sg_write "$module" > "$next/module" &&
        sg_write "$target" > "$next/path" || exit 1
    { md5 "$next/before" && md5 "$next/bytes" && cat "$shared/build" && sg_print '' && cat "$shared/meta"; } > "$next/hashes" || exit 1
    sg_print "$version" > "$shared/pending.tmp.$$" &&
        mv "$shared/pending.tmp.$$" "$shared/pending" || exit 1
    sync || exit 1
    sg_line_guard "$target" || exit $?
    system=0
    case "$target" in /system/*) sg_remount rw || exit 1; system=1;; esac
    temporary=$target.hmg-seogaemo.$$
    read mode uid gid < "$shared/meta" || exit 1
    rc=0
    cp "$next/bytes" "$temporary" && chown "$uid:$gid" "$temporary" &&
        chmod "$mode" "$temporary" &&
        mv "$temporary" "$target" &&
        sg_equal "$next/bytes" "$target" &&
        [ "$(sg_file_meta "$target")" = "$(cat "$shared/meta")" ] || rc=1
    rm -f "$temporary"
    if [ "$system" -eq 1 ]; then sg_remount_ro; fi
    [ "$rc" -eq 0 ] || exit 1
    sync || exit 1
    sg_line_recover "$target" || exit $?
    if [ "$action" = revert ]; then
        rm -rf "$marker" || exit 1
        remaining=0
        for patch in "$next"/patches/*/*; do [ ! -d "$patch" ] || remaining=1; done
        if [ "$remaining" -eq 0 ]; then
            sg_equal "$shared/bytes" "$target" &&
                [ "$(sg_file_meta "$target")" = "$(cat "$shared/meta")" ] || exit 3
            # A cancelled sibling apply can leave a marker without a patch.
            # Stock is verified and no patches remain, so retire those too.
            for stale in "$SG_DATA_ROOT"/modules/*/line."$path_key"; do
                [ ! -d "$stale" ] || rm -rf "$stale" || exit 1
            done
            rm -rf "$shared"
        fi
    fi
)
sg_line_preflight() (
    set +f
    for marker in "$HMG_SEOGAEMO_STATE"/line.*/ready; do
        [ -f "$marker" ] || continue
        target=$(cat "${marker%/ready}/path") || exit 1
        sg_line_guard "$target" || { sg_restore_conflict "line preflight: $target"; exit 3; }
    done
)
sg_line_revert_all() (
    set +f
    for marker in "$HMG_SEOGAEMO_STATE"/line.*/ready; do
        [ -f "$marker" ] || continue
        target=$(cat "${marker%/ready}/path") || exit 1
        path_key=$(sg_file_key "$target") || exit 1
        shared=$SG_DATA_ROOT/shared-lines/$path_key
        sg_line_transaction "$target" revert || exit $?
    done
)
sg_line_applied() (
    set +f
    path_key=$(sg_file_key "$1") || exit 1
    shared=$SG_DATA_ROOT/shared-lines/$path_key
    [ -f "$shared/active" ] && [ ! -f "$shared/pending" ] || exit 1
    sg_line_guard "$1" || exit $?
    version=$(cat "$shared/active") || exit 1
    for patch in "$shared/versions/$version/patches/${HMG_SEOGAEMO_STATE##*/}"/*; do
        [ ! -d "$patch" ] || exit 0
    done
    exit 1
)

sg_file_replace_line() {
    if sg_line_claim "$1" "$2"; then
        sg_line_text "$3" || return 2
        sg_line_authorize "$1" "$2" || return $?
        sg_line_transaction "$1" apply "$2" "$3"
        return $?
    fi
    sg_validate owns_files "$1" || return 2
    sg_whole_exclusive "$1" || return 3
    [ -f "$1" ] || return 1
    sg_replacement=$HMG_SEOGAEMO_STATE/replace.$$
    sg_ready || return 1
    sg_old=$2; sg_new=$3; sg_matches=0
    : > "$sg_replacement" || return 1
    while IFS= read -r sg_line || [ -n "$sg_line" ]; do
        if [ "$sg_line" = "$sg_old" ]; then
            sg_matches=$((sg_matches + 1))
            sg_line=$sg_new
        fi
        sg_print "$sg_line" >> "$sg_replacement" || return 1
    done < "$1"
    [ "$sg_matches" -eq 1 ] || { rm -f "$sg_replacement"; return 1; }
    sg_commit_file "$1" "$sg_replacement" "" ""
    sg_rc=$?
    rm -f "$sg_replacement"
    return "$sg_rc"
}
sg_file_delete() {
    sg_validate owns_files "$1" || return 2
    sg_whole_exclusive "$1" || return 3
    sg_file_baseline "$1" || return 1
    sg_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || return 1
    if [ -f "$sg_saved/applied-existence" ]; then
        sg_file_guard "$1" || { sg_restore_conflict "file delete: $1"; return 3; }
    fi
    case "$1" in /system/*) sg_remount rw || return 1; sg_system=1;; *) sg_system=0;; esac
    rm -f "$1"; sg_rc=$?
    [ ! -e "$1" ] || sg_rc=1
    if [ "$sg_system" -eq 1 ]; then sg_remount_ro; fi
    [ "$sg_rc" -eq 0 ] || return 1
    sg_file_mark_applied "$1" || return 1
    sg_ledger file_delete "$1" "$sg_saved/bytes" "$sg_saved/applied" "$sg_saved/meta" || return 1
    sg_changed file "$1"
}
sg_bind_mount() {
    sg_validate owns_files "$1" && sg_payload "$2" || return 2
    sg_whole_exclusive "$1" || return 3
    sg_path_safe "$sg_source" && [ "$(sg_file_meta "$sg_source")" = "0644 0 0" ] || return 3
    [ -f "$1" ] || return 1
    sg_file_baseline "$1" || return 1
    sg_bind=$HMG_SEOGAEMO_STATE/bind.$(sg_file_key "$1") || return 1
    if sg_mount_present "$1"; then
        sg_applied "$1" || return 3
        return 0
    fi
    mount -o bind "$sg_source" "$1" || return 1
    sg_equal "$sg_source" "$1" || return 1
    sg_file_mark_applied "$1" || return 1
    sg_print "$1	$2" > "$sg_bind.tmp.$$" &&
        mv "$sg_bind.tmp.$$" "$sg_bind" || return 1
    sg_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || return 1
    sg_ledger bind_mount "$1" "$sg_saved/bytes" "$sg_saved/applied" "$sg_saved/meta" || return 1
    sg_changed file "$1"
}
sg_mount_present() { grep -q " $1 " "${SG_MOUNTS_FILE:-/proc/mounts}" 2>/dev/null; }
sg_reapply_binds() { sg_glob_on _sg_reapply_binds "$@"; }
_sg_reapply_binds() {
    for sg_spec in "$HMG_SEOGAEMO_STATE"/bind.*; do
        [ -f "$sg_spec" ] || continue
        IFS='	' read -r sg_target sg_source_rel < "$sg_spec" || return 1
        sg_bind_mount "$sg_target" "$sg_source_rel" || return 1
    done
}
sg_service_restart() {
    sg_validate services "$1" || return 2
    sg_before_service=$HMG_SEOGAEMO_STATE/service.$1.before.$$
    sg_after_service=$HMG_SEOGAEMO_STATE/service.$1.after.$$
    sg_ready || return 1
    getprop "init.svc.$1" > "$sg_before_service" || return 1
    stop "$1" && start "$1" || return 1
    getprop "init.svc.$1" > "$sg_after_service" || return 1
    [ "$(cat "$sg_after_service")" = running ] || return 1
    sg_ledger service_restart "$1" "$sg_before_service" "$sg_after_service" "" || return 1
    rm -f "$sg_before_service" "$sg_after_service"
}
sg_service_call() {
    [ "$#" -eq 2 ] || return 2
    case "$1" in ''|*[!a-zA-Z0-9_.-]*|.*|*.|*..*|*-*) return 2;; esac
    case "$2" in ''|0*|*[!0-9]*) return 2;; esac
    [ "$2" -le 65535 ] || return 2
    sg_validate service_calls "$1:$2" || return 2
    sg_call_boot=$(cat "${SG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null) || return 1
    case "$sg_call_boot" in ''|*[!a-zA-Z0-9-]*) return 1;; esac
    [ "${#sg_call_boot}" -le 64 ] || return 1
    sg_ready || return 1
    sg_call_output=$HMG_SEOGAEMO_STATE/service-call.$$.out
    sg_call_before=$HMG_SEOGAEMO_STATE/service-call.$$.before
    sg_call_after=$HMG_SEOGAEMO_STATE/service-call.$$.after
    sg_print "no call" > "$sg_call_before" || return 1
    sg_write "$sg_call_boot" > "$HMG_SEOGAEMO_STATE/last-call-boot.tmp.$$" &&
        mv "$HMG_SEOGAEMO_STATE/last-call-boot.tmp.$$" "$HMG_SEOGAEMO_STATE/last-call-boot" &&
        sg_write "pending" > "$HMG_SEOGAEMO_STATE/last-call-result.tmp.$$" &&
        mv "$HMG_SEOGAEMO_STATE/last-call-result.tmp.$$" "$HMG_SEOGAEMO_STATE/last-call-result" || return 1
    "${HMG_SEOGAEMO_SERVICE_BIN:-/system/bin/service}" call "$1" "$2" > "$sg_call_output" 2>&1 & # android44-shell: allow -- service binary defaults to /system/bin/service; override is a host-test seam
    sg_call_pid=$!
    sg_call_wait=0
    while kill -0 "$sg_call_pid" 2>/dev/null && [ "$sg_call_wait" -lt 15 ]; do
        sleep 1
        sg_call_wait=$((sg_call_wait + 1))
    done
    if kill -0 "$sg_call_pid" 2>/dev/null; then
        kill "$sg_call_pid" 2>/dev/null || :
        # Do not let a child that ignores TERM turn the deadline into a hang.
        kill -9 "$sg_call_pid" 2>/dev/null || :
        wait "$sg_call_pid" 2>/dev/null || :
        sg_call_result=timeout
        sg_call_rc=1
    else
        wait "$sg_call_pid"; sg_call_rc=$?
        if [ "$sg_call_rc" -eq 0 ]; then sg_call_result=ok; else sg_call_result=failed; fi
    fi
    SG_SERVICE_CALL_RESPONSE=$(dd if="$sg_call_output" bs=1 count=512 2>/dev/null) || SG_SERVICE_CALL_RESPONSE=
    case "$SG_SERVICE_CALL_RESPONSE" in
        *'Cannot broadcast before boot completed'*|*'fffffffb 00000026 00610043'*)
            sg_call_result=boot-incomplete; sg_call_rc=1 ;;
    esac
    sg_print "$(sg_clean "$SG_SERVICE_CALL_RESPONSE")" > "$sg_call_after" || return 1
    sg_ledger service_call "$1:$2" "$sg_call_before" "$sg_call_after" "" "$sg_call_result" || return 1
    sg_write "$sg_call_result" > "$HMG_SEOGAEMO_STATE/last-call-result.tmp.$$" &&
        mv "$HMG_SEOGAEMO_STATE/last-call-result.tmp.$$" "$HMG_SEOGAEMO_STATE/last-call-result" || return 1
    rm -f "$sg_call_output" "$sg_call_before" "$sg_call_after"
    [ "$sg_call_rc" -eq 0 ]
}
sg_service_call_this_boot() {
    [ -f "$HMG_SEOGAEMO_STATE/last-call-boot" ] || return 1
    sg_seen_boot=$(cat "$HMG_SEOGAEMO_STATE/last-call-boot") || return 1
    sg_now_boot=$(cat "${SG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null) || return 1
    [ -n "$sg_now_boot" ] && [ "$sg_seen_boot" = "$sg_now_boot" ]
}
sg_service_call_ok_this_boot() {
    sg_service_call_this_boot && [ "$(cat "$HMG_SEOGAEMO_STATE/last-call-result" 2>/dev/null)" = ok ]
}
sg_applied() {
    sg_check_build || return 3
    case "$1" in
        /*) sg_key=$(sg_file_key "$1") || return 1
            if [ -f "$HMG_SEOGAEMO_STATE/line.$sg_key/ready" ]; then
                sg_line_applied "$1"; return $?
            fi
            sg_file_applied "$1" ;;
        *) sg_dir=$HMG_SEOGAEMO_STATE/prop.$1
            [ -f "$sg_dir/applied" ] && [ "$(getprop "$1")" = "$(cat "$sg_dir/applied")" ] ;;
    esac
}
# The zygote wrapper may advance this counter before the shell runs again.
# Only decimal counters are accepted as wrapper-owned state.
sg_zygote_finalize_guard() {
    sg_guard=$HMG_SEOGAEMO_STATE/starts
    sg_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$sg_guard") || return 1
    [ -f "$sg_saved/applied" ] || return 0
    [ -f "$sg_guard" ] || return 3
    sg_count=$(cat "$sg_guard") || return 1
    case "$sg_count" in ''|*[!0-9]*) return 3;; esac
    if ! sg_equal "$sg_saved/applied" "$sg_guard"; then
        sg_old_applied=$HMG_SEOGAEMO_STATE/starts.old.$$
        sg_copy "$sg_saved/applied" "$sg_old_applied" || return 1
        sg_file_mark_applied "$sg_guard" || return 1
        sg_ledger zygote_starts "$sg_guard" "$sg_old_applied" "$sg_saved/applied" "$sg_saved/meta" || return 1
        rm -f "$sg_old_applied"
    fi
}
sg_file_baseline_absent() {
    [ ! -e "$1" ] || return 3
    sg_bind_build || return 1
    sg_absent_dir=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$1") || return 1
    [ ! -e "$sg_absent_dir/ready" ] || return 0
    mkdir -p "$sg_absent_dir" || return 1
    sg_write "$1" > "$sg_absent_dir/path.tmp.$$" &&
        mv "$sg_absent_dir/path.tmp.$$" "$sg_absent_dir/path" &&
        sg_write "absent" > "$sg_absent_dir/existence.tmp.$$" &&
        mv "$sg_absent_dir/existence.tmp.$$" "$sg_absent_dir/existence" &&
        sg_write "1" > "$sg_absent_dir/ready.tmp.$$" &&
        mv "$sg_absent_dir/ready.tmp.$$" "$sg_absent_dir/ready"
}
# Only the JAR named in owns_files can nominate a cache namespace. The two
# derived cache locations are fixed by Android's Dalvik naming convention.
sg_dex_cache_track() { sg_glob_on _sg_dex_cache_track "$@"; }
_sg_dex_cache_track() {
    sg_validate owns_files "${SG_TARGET_ROOT:-}$1" || return 2
    case "$1" in /system/framework/*.jar) ;; *) return 2;; esac
    case "$2" in ''|*[!a-zA-Z0-9_.]*) return 2;; esac
    sg_jar=${1##*/}
    sg_cache=${SG_TARGET_ROOT:-}/data/dalvik-cache/system@framework@$sg_jar@classes.dex
    sg_app_dir=${SG_TARGET_ROOT:-}/data/data/$2/app_hmg-seogaemo-wireless-dex
    sg_ready || return 1
    [ ! -f "$HMG_SEOGAEMO_STATE/dex.cache" ] || {
        [ "$(cat "$HMG_SEOGAEMO_STATE/dex.cache")" = "$sg_cache" ] &&
            [ "$(cat "$HMG_SEOGAEMO_STATE/dex.app-dir")" = "$sg_app_dir" ]; return; }
    if [ -d "$sg_app_dir" ]; then sg_dir_existed=present; else sg_dir_existed=absent; fi
    for sg_dex in "$sg_cache" "$sg_app_dir"/* "$sg_app_dir"/.[!.]* "$sg_app_dir"/..?*; do
        [ -e "$sg_dex" ] || {
            if [ "$sg_dex" = "$sg_cache" ]; then
                sg_file_baseline_absent "$sg_dex" || return 1
                sg_changed file "$sg_dex" || return 1
                sg_ledger dex_track "$sg_dex" "$sg_dex" "$sg_dex" "" || return 1
            fi
            continue
        }
        case "${sg_dex##*/}" in *[!a-zA-Z0-9_.@-]*) return 3;; esac
        [ -f "$sg_dex" ] && [ ! -L "$sg_dex" ] || return 3
        sg_file_baseline "$sg_dex" || return 1
        sg_changed file "$sg_dex" || return 1
        sg_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$sg_dex") || return 1
        sg_ledger dex_track "$sg_dex" "$sg_saved/bytes" "$sg_dex" "$sg_saved/meta" || return 1
    done
    sg_write "$sg_cache" > "$HMG_SEOGAEMO_STATE/dex.cache.tmp.$$" &&
        mv "$HMG_SEOGAEMO_STATE/dex.cache.tmp.$$" "$HMG_SEOGAEMO_STATE/dex.cache" &&
        sg_write "$sg_app_dir" > "$HMG_SEOGAEMO_STATE/dex.app-dir.tmp.$$" &&
        mv "$HMG_SEOGAEMO_STATE/dex.app-dir.tmp.$$" "$HMG_SEOGAEMO_STATE/dex.app-dir" &&
        sg_write "$sg_dir_existed" > "$HMG_SEOGAEMO_STATE/dex.dir-existed.tmp.$$" &&
        mv "$HMG_SEOGAEMO_STATE/dex.dir-existed.tmp.$$" "$HMG_SEOGAEMO_STATE/dex.dir-existed"
}
sg_dex_finalize() { sg_glob_on _sg_dex_finalize "$@"; }
_sg_dex_finalize() {
    [ -f "$HMG_SEOGAEMO_STATE/dex.cache" ] || return 0
    sg_cache=$(cat "$HMG_SEOGAEMO_STATE/dex.cache") || return 1
    sg_app_dir=$(cat "$HMG_SEOGAEMO_STATE/dex.app-dir") || return 1
    for sg_dex in "$sg_cache" "$sg_app_dir"/* "$sg_app_dir"/.[!.]* "$sg_app_dir"/..?*; do
        [ -e "$sg_dex" ] || continue
        case "${sg_dex##*/}" in *[!a-zA-Z0-9_.@-]*) return 3;; esac
        [ -f "$sg_dex" ] && [ ! -L "$sg_dex" ] || return 3
        sg_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$sg_dex") || return 1
        if [ ! -f "$sg_saved/ready" ]; then
            # This path was absent at activation; record that baseline now.
            mkdir -p "$sg_saved" || return 1
            sg_write "$sg_dex" > "$sg_saved/path.tmp.$$" && mv "$sg_saved/path.tmp.$$" "$sg_saved/path" || return 1
            sg_write "absent" > "$sg_saved/existence.tmp.$$" && mv "$sg_saved/existence.tmp.$$" "$sg_saved/existence" || return 1
            sg_write "1" > "$sg_saved/ready.tmp.$$" && mv "$sg_saved/ready.tmp.$$" "$sg_saved/ready" || return 1
            sg_changed file "$sg_dex" || return 1
        fi
        if [ -f "$sg_saved/applied" ]; then
            sg_dex_before=$sg_saved/applied
        elif [ -f "$sg_saved/bytes" ]; then sg_dex_before=$sg_saved/bytes
        else sg_dex_before=/dev/null; fi
        sg_dex_old=$HMG_SEOGAEMO_STATE/dex.old.$$
        sg_copy "$sg_dex_before" "$sg_dex_old" || return 1
        sg_file_mark_applied "$sg_dex" || return 1
        sg_ledger dex_generated "$sg_dex" "$sg_dex_old" "$sg_saved/applied" "$sg_saved/meta" || return 1
        rm -f "$sg_dex_old"
    done
}
# Called only for an already-installed wrapper, under the root operation lock.
sg_zygote_upgrade() (
    set +f
    journal=$HMG_SEOGAEMO_STATE/zygote-upgrade
    sg_zygote_sweep || exit 1
    sg_check_build && sg_applied "$sg_stock" && [ -x "$sg_stock" ] || exit 3
    changed=0
    for part in loader jar wrapper; do
        case "$part" in
            loader) target=$sg_lib; source=$sg_loader; mode=0644;;
            jar) target=$sg_framework; source=$sg_jar; mode=0644;;
            wrapper) target=$sg_bin; source=$sg_wrapper; mode=0755;;
        esac
        key=$(sg_file_key "$target") || exit 1
        sg_applied "$target" || sg_zygote_prepared "$target" || {
            sg_restore_conflict "projection payload drift: $target"; exit 3;
        }
        if [ -f "$journal/ready" ]; then
            sg_equal "$source" "$journal/$key/next" || {
                sg_restore_conflict 'resume selected projection payload or restore stock first'; exit 3;
            }
        fi
        sg_equal "$source" "$target" || changed=1
    done
    [ "$changed" -ne 0 ] || [ -f "$journal/ready" ] || exit 0
    # Old fixed updaters can auto-roll back only package/APK, not system hooks.
    # Their health window must keep the previous installed hook generation.
    if [ "${HMG_SEOGAEMO_UPDATE_HEALTH:-}" = 1 ] &&
       [ "${HMG_SEOGAEMO_PROJECTION_ROLLBACK_GUARD:-}" != 1 ]; then
        sg_print 'info.hook_upgrade=deferred until update is finalized'
        exit 0
    fi
    if [ ! -f "$journal/ready" ]; then
        prepare=$HMG_SEOGAEMO_STATE/zygote-prepare.$$
        mkdir -p "$prepare" || exit 1
        for part in loader jar wrapper; do
            case "$part" in
                loader) target=$sg_lib; source=$sg_loader; mode=0644;;
                jar) target=$sg_framework; source=$sg_jar; mode=0644;;
                wrapper) target=$sg_bin; source=$sg_wrapper; mode=0755;;
            esac
            key=$(sg_file_key "$target") || exit 1
            mkdir -p "$prepare/$key" &&
                sg_write "$target" > "$prepare/$key/path" &&
                sg_copy "$source" "$prepare/$key/next" &&
                sg_copy "$target" "$prepare/$key/previous" &&
                sg_print "$mode 0 0" > "$prepare/$key/meta" || exit 1
        done
        sg_write 1 > "$prepare/ready" && sync && mv "$prepare" "$journal" && sync || exit 1
    fi
    sg_restart_required || exit 1
    # The two cache namespaces are runtime-owned and may be regenerated while
    # active. Capture them with the existing derived-cache API before deletion.
    [ -f "$HMG_SEOGAEMO_STATE/dex.cache" ] || exit 1
    sg_dex_finalize || exit 3
    cache=$(cat "$HMG_SEOGAEMO_STATE/dex.cache") || exit 1
    app_dir=$(cat "$HMG_SEOGAEMO_STATE/dex.app-dir") || exit 1
    for target in "$cache" "$app_dir"/* "$app_dir"/.[!.]* "$app_dir"/..?*; do
        [ -e "$target" ] || continue
        sg_path_safe "$target" && [ -f "$target" ] || exit 3
        key=$(sg_file_key "$target") || exit 1
        sg_write 1 > "$journal/dex.$key" && sync || exit 1
        rm -f "$target" || exit 1
    done
    # Deleted app-cache paths no longer appear in the glob on retry. Finalize
    # every journaled absence, including a kill between deletion and marking.
    for marker in "$journal"/dex.*; do
        [ -f "$marker" ] || continue
        key=${marker##*/dex.}
        target=$(cat "$HMG_SEOGAEMO_STATE/file.$key/path") || exit 1
        sg_path_safe "$target" && [ ! -e "$target" ] || exit 3
        sg_file_mark_applied "$target" || exit 1
        sg_ledger dex_invalidate "$target" "$HMG_SEOGAEMO_STATE/file.$key/bytes" /dev/null "" || exit 1
    done
    for part in loader jar wrapper; do
        case "$part" in
            loader) target=$sg_lib; mode=0644;;
            jar) target=$sg_framework; mode=0644;;
            wrapper) target=$sg_bin; mode=0755;;
        esac
        key=$(sg_file_key "$target") || exit 1
        sg_commit_file "$target" "$journal/$key/next" "$mode" 0:0 || exit $?
        sg_ledger zygote_upgrade "$target" "$journal/$key/previous" "$journal/$key/next" "$journal/$key/meta" || exit 1
    done
    # Retire atomically: a kill during recursive cleanup must not leave a
    # half-populated active journal which a retry could mistake for prepared.
    sync && mv "$journal" "$HMG_SEOGAEMO_STATE/zygote-retired.$$" &&
        rm -rf "$HMG_SEOGAEMO_STATE/zygote-retired.$$"
)
sg_zygote_install() {
    sg_payload "$1" || return 2; sg_wrapper=$sg_source
    sg_payload "$2" || return 2; sg_loader=$sg_source
    sg_payload "$3" || return 2; sg_jar=$sg_source
    sg_bin=${SG_TARGET_ROOT:-}/system/bin/app_process
    sg_stock=${SG_TARGET_ROOT:-}/system/bin/app_process.hmg-seogaemo-stock
    sg_lib=${SG_TARGET_ROOT:-}/system/lib/${SG_ZYGOTE_LIB:-libhmg_seogaemo_wireless_hook.so}
    sg_framework=${SG_TARGET_ROOT:-}/system/framework/${SG_ZYGOTE_JAR:-hmg-seogaemo-wireless-hook.jar}
    for sg_target in "$sg_bin" "$sg_stock" "$sg_lib" "$sg_framework" \
        "$HMG_SEOGAEMO_STATE/enable" "$HMG_SEOGAEMO_STATE/enabled" \
        "$HMG_SEOGAEMO_STATE/starts" "$HMG_SEOGAEMO_STATE/disable"; do
        sg_validate owns_files "$sg_target" || return 2
        sg_whole_exclusive "$sg_target" || return 3
    done
    [ -f "$sg_bin" ] || return 3
    if sg_applied "$sg_bin" || [ -f "$HMG_SEOGAEMO_STATE/zygote-upgrade/ready" ]; then
        sg_zygote_upgrade
        return $?
    fi
    [ ! -e "$sg_stock" ] || return 3
    for sg_target in "$sg_bin" "$sg_stock" "$sg_lib" "$sg_framework" \
        "$HMG_SEOGAEMO_STATE/enable" "$HMG_SEOGAEMO_STATE/enabled" \
        "$HMG_SEOGAEMO_STATE/starts" "$HMG_SEOGAEMO_STATE/disable"; do
        sg_file_baseline "$sg_target" || return 1
    done
    sg_stock_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$sg_bin") || return 1
    read sg_stock_mode sg_stock_uid sg_stock_gid < "$sg_stock_saved/meta" || return 1
    sg_empty=$HMG_SEOGAEMO_STATE/zygote.empty.$$
    sg_zero=$HMG_SEOGAEMO_STATE/zygote.zero.$$
    : > "$sg_empty"; sg_write "0" > "$sg_zero"
    sg_rc=0
    sg_commit_file "$sg_stock" "$sg_stock_saved/bytes" "$sg_stock_mode" "$sg_stock_uid:$sg_stock_gid" || sg_rc=1
    if [ "$sg_rc" -eq 0 ]; then sg_commit_file "$sg_lib" "$sg_loader" 0644 0:0 || sg_rc=1; fi
    if [ "$sg_rc" -eq 0 ]; then sg_commit_file "$sg_framework" "$sg_jar" 0644 0:0 || sg_rc=1; fi
    if [ "$sg_rc" -eq 0 ]; then sg_commit_file "$HMG_SEOGAEMO_STATE/starts" "$sg_zero" 0600 0:0 || sg_rc=1; fi
    if [ "$sg_rc" -eq 0 ]; then sg_file_delete "$HMG_SEOGAEMO_STATE/disable" || sg_rc=1; fi
    if [ "$sg_rc" -eq 0 ]; then sg_commit_file "$HMG_SEOGAEMO_STATE/enabled" "$sg_empty" 0600 0:0 || sg_rc=1; fi
    if [ "$sg_rc" -eq 0 ]; then sg_commit_file "$HMG_SEOGAEMO_STATE/enable" "$sg_empty" 0600 0:0 || sg_rc=1; fi
    if [ "$sg_rc" -eq 0 ]; then sg_commit_file "$sg_bin" "$sg_wrapper" 0755 0:0 || sg_rc=1; fi
    rm -f "$sg_empty" "$sg_zero"
    if [ "$sg_rc" -ne 0 ]; then sg_revert_all || sg_log 'zygote rollback blocked'; return 1; fi
    [ -f "$sg_stock" ] && [ -x "$sg_stock" ] && sg_equal "$sg_stock_saved/bytes" "$sg_stock"
}
# Read-only guard for the app_process swap. A module that owns the swap holds a
# file baseline for it (or an upgrade journal); every guarded revert path then
# applies. Without that record nothing we wrote is recoverable, so these (and
# only these) count as evidence of an unrecorded swap and are reported together
# in one conflict line: the stock backup, our hook .so and .jar, and an
# app_process that is not the known stock build (module.properties
# `known_stock.N=<product glob>:<path>:<md5>`). The wrapper's own guard state
# (`enable`, `enabled`, `starts`, `disable` in the module state directory) is
# NOT evidence: the live wrapper recreates `starts` after a revert and `disable`
# is its documented manual off switch. `sg_zygote_guard_sweep` removes them.
# Returns 0 when clean, owned or not applicable, 3 on a conflict.
sg_zygote_foreign() (
    sg_bin=${SG_TARGET_ROOT:-}/system/bin/app_process
    sg_validate owns_files "$sg_bin" || exit 0
    key=$(sg_file_key "$sg_bin") || exit 1
    [ ! -f "$HMG_SEOGAEMO_STATE/file.$key/ready" ] || exit 0
    [ ! -f "$HMG_SEOGAEMO_STATE/zygote-upgrade/ready" ] || exit 0
    # The swap is recorded when the other owner (core hook host or the CarPlay module) holds it.
    set +f
    for owner in "$SG_DATA_ROOT"/modules/*/file."$key"/ready; do
        [ -f "$owner" ] || continue
        case "$owner" in "$HMG_SEOGAEMO_STATE"/*) ;; *) exit 0;; esac
    done
    found=
    for item in "$sg_bin.hmg-seogaemo-stock" \
        "${SG_TARGET_ROOT:-}/system/lib/${SG_ZYGOTE_LIB:-libhmg_seogaemo_wireless_hook.so}" \
        "${SG_TARGET_ROOT:-}/system/framework/${SG_ZYGOTE_JAR:-hmg-seogaemo-wireless-hook.jar}"; do
        if [ -e "$item" ] || [ -L "$item" ]; then
            found="${found:+$found, }${item##*/}"
        fi
    done
    product=$(getprop ro.build.product) || exit 1
    expected=
    while IFS='=' read -r field value; do
        case "$field" in known_stock.*) ;; *) continue;; esac
        glob=${value%%:*}; rest=${value#*:}
        [ "${rest%%:*}" = /system/bin/app_process ] || continue
        case "$product" in $glob) expected=${rest#*:};; esac
    done < "$(sg_manifest_file)"
    unknown=0
    if [ -n "$expected" ] && [ -f "$sg_bin" ]; then
        actual=$(md5 "$sg_bin") || exit 1
        set -- $actual
        [ "${1:-}" = "$expected" ] || unknown=1
    fi
    if [ -n "$found" ]; then
        detail="app_process swap without ownership record: $found"
        [ "$unknown" -eq 0 ] || detail="$detail, app_process (not the known stock build)"
        sg_restore_conflict "$detail"
        exit 3
    fi
    if [ "$unknown" -eq 1 ]; then
        sg_restore_conflict 'app_process is not the known stock build and no module owns the swap'
        exit 3
    fi
    exit 0
)
# Removes stale wrapper guard state (exact names, module state directory only,
# one ledger row each) once `sg_zygote_foreign` found no evidence of a swap. A
# no-op while the module owns the swap. A directory in place of a guard file is
# not ours: conflict, nothing more is touched.
sg_zygote_guard_sweep() (
    sg_bin=${SG_TARGET_ROOT:-}/system/bin/app_process
    sg_validate owns_files "$sg_bin" || exit 0
    key=$(sg_file_key "$sg_bin") || exit 1
    [ ! -f "$HMG_SEOGAEMO_STATE/file.$key/ready" ] || exit 0
    [ ! -f "$HMG_SEOGAEMO_STATE/zygote-upgrade/ready" ] || exit 0
    for name in starts enable enabled disable; do
        item=$HMG_SEOGAEMO_STATE/$name
        if [ -d "$item" ] && [ ! -L "$item" ]; then
            sg_restore_conflict "unexpected directory in wrapper guard state: $name"
            exit 3
        fi
    done
    for name in starts enable enabled disable; do
        item=$HMG_SEOGAEMO_STATE/$name
        [ -e "$item" ] || [ -L "$item" ] || continue
        sg_ledger zygote_guard_sweep "$item" "$item" "" "" swept || exit 1
        rm -f "$item" && [ ! -e "$item" ] && [ ! -L "$item" ] || exit 1
    done
    exit 0
)
# Core hook host: one app_process wrapper shared by installed hook modules (hook_apps).
# Its own ledger owner is the state directory modules/core-hook; the manifest is generated.
sg_core_hook_vars() {
    HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/modules/core-hook
    HMG_SEOGAEMO_MODULE_DIR=$HMG_SEOGAEMO_BASE/core/hook
    SG_ZYGOTE_LIB=libhmg_seogaemo_hook.so
    SG_ZYGOTE_JAR=hmg-seogaemo-hook.jar
}
sg_core_hook_manifest() {
    sg_ch_dir=$SG_DATA_ROOT/core/hook
    sg_ch_t=${SG_TARGET_ROOT:-}
    mkdir -p "$sg_ch_dir/mods" && chmod 700 "$SG_DATA_ROOT/core" "$sg_ch_dir" "$sg_ch_dir/mods" || return 1
    {
        sg_print id=core-hook restart=head_unit
        sg_print "owns_files=$sg_ch_t/system/bin/app_process,$sg_ch_t/system/bin/app_process.hmg-seogaemo-stock,$sg_ch_t/system/lib/libhmg_seogaemo_hook.so,$sg_ch_t/system/framework/hmg-seogaemo-hook.jar,$HMG_SEOGAEMO_STATE/enable,$HMG_SEOGAEMO_STATE/enabled,$HMG_SEOGAEMO_STATE/starts,$HMG_SEOGAEMO_STATE/disable"
        grep '^known_stock\.[0-9]*=.*:/system/bin/app_process:' "$HMG_SEOGAEMO_BASE/modules/wireless-carplay-and-aa.properties" 2>/dev/null || :
    } > "$sg_ch_dir/core-hook.properties.tmp.$$" &&
        mv "$sg_ch_dir/core-hook.properties.tmp.$$" "$sg_ch_dir/core-hook.properties"
}
sg_core_hook_owned() {
    sg_ch_key=$(sg_file_key "${SG_TARGET_ROOT:-}/system/bin/app_process") || return 1
    [ -f "$SG_DATA_ROOT/modules/core-hook/file.$sg_ch_key/ready" ]
}
# Installs the wrapper (or upgrades it to this package) for a module that registered hooks.
sg_core_hook_ensure() (
    set +f
    sg_core_hook_vars
    sg_core_hook_manifest || exit 1
    sg_ready || exit 1
    sg_bind_build || exit 3
    sg_zygote_foreign || exit 3
    if ! sg_restore_material; then sg_zygote_guard_sweep || exit 3; fi
    # Only a first install replaces the running zygote; re-applies keep the live wrapper.
    key=$(sg_file_key "${SG_TARGET_ROOT:-}/system/bin/app_process") || exit 1
    was=0
    [ ! -f "$HMG_SEOGAEMO_STATE/file.$key/applied" ] || was=1
    sg_dex_cache_track /system/framework/hmg-seogaemo-hook.jar android || exit $?
    sg_zygote_install data/app_process data/libhmg_seogaemo_hook.so data/hmg-seogaemo-hook.jar || {
        rc=$?
        sg_revert_all || sg_log 'core hook rollback blocked'
        exit "$rc"
    }
    [ "$was" -eq 1 ] || sg_restart_required || :
)
# Restores stock app_process once no installed module has hooks registered.
sg_core_hook_release() (
    set +f
    for entry in "$SG_DATA_ROOT"/core/hook/mods/*/entry; do [ ! -f "$entry" ] || exit 0; done
    sg_core_hook_vars
    if sg_restore_material; then
        [ -f "$SG_DATA_ROOT/core/hook/core-hook.properties" ] || sg_core_hook_manifest || exit 1
        sg_revert_all || exit $?
        sg_restart_required || :
    fi
    rm -rf "$SG_DATA_ROOT/core/hook/dex" "$SG_DATA_ROOT/core/hook/status"
    for dir in "$SG_DATA_ROOT"/core/hook/mods/*; do [ ! -d "$dir" ] || rmdir "$dir" 2>/dev/null || :; done
    exit 0
)
sg_restore_material() { sg_glob_on _sg_restore_material "$@"; }
_sg_restore_material() {
    for sg_material in "$HMG_SEOGAEMO_STATE"/prop.*/ready "$HMG_SEOGAEMO_STATE"/file.*/ready \
        "$HMG_SEOGAEMO_STATE"/line.*/ready "$HMG_SEOGAEMO_STATE"/bind.* \
        "$HMG_SEOGAEMO_STATE"/changes "$HMG_SEOGAEMO_STATE"/dex.cache \
        "$HMG_SEOGAEMO_STATE"/dir.* "$HMG_SEOGAEMO_STATE"/dir-order; do
        [ ! -f "$sg_material" ] || return 0
    done
    return 1
}
# A restored app_process leaves the live zygote on the wrapper until the head unit
# restarts: record that (best effort) so status and a repeated restore report
# pending-restart instead of "off".
sg_revert_all() {
    # An unrecorded swap is not stock, whatever the snapshots say: refuse first.
    sg_zygote_foreign || return 3
    sg_rv_swap=0
    if sg_validate owns_files "${SG_TARGET_ROOT:-}/system/bin/app_process"; then
        sg_rv_key=$(sg_file_key "${SG_TARGET_ROOT:-}/system/bin/app_process") || return 1
        if [ -f "$HMG_SEOGAEMO_STATE/file.$sg_rv_key/applied" ] || [ -f "$HMG_SEOGAEMO_STATE/zygote-upgrade/ready" ]; then sg_rv_swap=1; fi
    fi
    sg_zygote_guard_sweep || return $?
    sg_revert_all_run; sg_rv_code=$?
    if [ "$sg_rv_code" -eq 0 ] && [ "$sg_rv_swap" -eq 1 ]; then
        sg_restart_required || sg_log 'could not record the pending head unit restart' || :
    fi
    return "$sg_rv_code"
}
sg_revert_all_run() {
    # Consumed snapshots are already stock; a leftover desired bit is not a baseline.
    sg_restore_material || { sg_zygote_sweep; return $?; }
    sg_zygote_finalize_guard || return 3
    sg_dex_finalize || return 3
    sg_restore_preflight || return 3
    sg_line_revert_all || return $?
    [ -f "$HMG_SEOGAEMO_STATE/changes" ] || {
        sg_dirs_revert || return $?
        sg_baseline_clear; return $?;
    }
    sg_reverse=
    while IFS='	' read -r sg_kind sg_target; do
        sg_reverse="$sg_kind:$sg_target $sg_reverse"
    done < "$HMG_SEOGAEMO_STATE/changes"
    for sg_item in $sg_reverse; do
        sg_kind=${sg_item%%:*}; sg_target=${sg_item#*:}
        sg_revert_before=$HMG_SEOGAEMO_STATE/revert-before.$$
        case "$sg_kind" in
            prop)
                sg_saved=$HMG_SEOGAEMO_STATE/prop.$sg_target
                if sg_prop_drift_allowed "$sg_target"; then
                    sg_observed=$(getprop "$sg_target") || return 1
                    sg_write "$sg_observed" > "$sg_revert_before" || return 1
                else
                    sg_copy "$sg_saved/applied" "$sg_revert_before" || return 1
                fi
                sg_prop_restore "$sg_target" || return 3
                sg_ledger revert "$sg_target" "$sg_revert_before" "$sg_saved/live" "" || return 1 ;;
            file)
                sg_saved=$HMG_SEOGAEMO_STATE/file.$(sg_file_key "$sg_target") || return 1
                if [ -f "$sg_saved/applied" ]; then
                    sg_copy "$sg_saved/applied" "$sg_revert_before" || return 1
                else rm -f "$sg_revert_before"; fi
                sg_bind=$HMG_SEOGAEMO_STATE/bind.$(sg_file_key "$sg_target") || return 1
                if [ -f "$sg_bind" ]; then
                    if sg_mount_present "$sg_target"; then umount "$sg_target" || return 1; fi
                    rm -f "$sg_bind"
                fi
                case "$sg_target" in /system/*) sg_remount rw || return 1; sg_system=1;; *) sg_system=0;; esac
                sg_file_restore "$sg_target"; sg_rc=$?
                if [ "$sg_rc" -eq 0 ]; then sg_sweep_temps "$sg_target" || sg_rc=1; fi
                if [ "$sg_system" -eq 1 ]; then sg_remount_ro; fi
                [ "$sg_rc" -eq 0 ] || return "$sg_rc"
                sg_ledger revert "$sg_target" "$sg_revert_before" "$sg_saved/bytes" "$sg_saved/meta" || return 1 ;;
            *) return 1 ;;
        esac
        rm -f "$sg_revert_before"
    done
    if [ -f "$HMG_SEOGAEMO_STATE/dex.app-dir" ] &&
        [ "$(cat "$HMG_SEOGAEMO_STATE/dex.dir-existed")" = absent ]; then
        rmdir "$(cat "$HMG_SEOGAEMO_STATE/dex.app-dir")" 2>/dev/null || true
    fi
    rm -f "$HMG_SEOGAEMO_STATE/dex.cache" "$HMG_SEOGAEMO_STATE/dex.app-dir" "$HMG_SEOGAEMO_STATE/dex.dir-existed"
    sg_dirs_revert || return $?
    sg_baseline_clear
}
# Bounded child waits. The head unit has no timeout binary: callers start the
# child in the background, redirect its output to a file, and pass its PID here.
# Returns the child's status, or 124 after the whole attempt was killed.
# Children are found through toolbox ps (PID is field 2, PPID field 3).
# The whole tree is collected first (one ps snapshot, parent before children),
# then signalled from that fixed list: SIGTERM to every member, and after a
# short grace SIGKILL to every member again. Variables are local to the
# subshell so nothing can overwrite the list; the target is never skipped.
sg_kill_tree() (
    pid=$1; depth=${2:-3}
    case "$pid" in ''|*[!0-9]*) exit 2;; esac
    case "$depth" in ''|*[!0-9]*) exit 2;; esac
    [ "$pid" -gt 1 ] || exit 2
    all=$pid; level=$pid
    list=$(ps 2>/dev/null) || list=
    while [ "$depth" -gt 0 ] && [ -n "$level" ] && [ -n "$list" ]; do
        next=
        while read -r user child parent rest; do
            case "$child:$parent" in *[!0-9:]*|:*|*:) continue;; esac
            case " $level " in *" $parent "*) ;; *) continue;; esac
            case " $all " in *" $child "*) continue;; esac
            next="$next $child"; all="$all $child"
        done <<EOF
$list
EOF
        level=$next
        depth=$((depth - 1))
    done
    for victim in $all; do
        [ "$victim" != "$$" ] && [ "$victim" -gt 1 ] || continue
        kill "$victim" 2>/dev/null || :
    done
    # Escalate once after the grace instead of polling: a not-yet-reaped child
    # still answers kill -0, so liveness checks cannot be trusted here.
    sleep 1
    for victim in $all; do
        [ "$victim" != "$$" ] && [ "$victim" -gt 1 ] || continue
        kill -9 "$victim" 2>/dev/null || :
    done
    exit 0
)
# SIGKILL is not catchable, so the final wait on the target returns as soon as
# the kernel reaps it; only an uninterruptible process could delay it.
sg_bounded_wait() {
    case "$1:$2" in ''|*[!0-9:]*|:*|*:) return 2;; esac
    sg_bw_pid=$1; sg_bw_limit=$2; sg_bw_elapsed=0
    while kill -0 "$sg_bw_pid" 2>/dev/null && [ "$sg_bw_elapsed" -lt "$sg_bw_limit" ]; do
        sleep 1
        sg_bw_elapsed=$((sg_bw_elapsed + 1))
    done
    if kill -0 "$sg_bw_pid" 2>/dev/null; then
        sg_kill_tree "$sg_bw_pid" 3
        wait "$sg_bw_pid" 2>/dev/null || :
        return 124
    fi
    wait "$sg_bw_pid"
}
# Read-only: the boot class path root-spawned app_process needs. Prefer the
# inherited environment, else the init environment file. Prints one validated
# value; fails (printing nothing) when none is usable.
sg_bootclasspath() (
    value=${BOOTCLASSPATH:-}
    if [ -z "$value" ] && [ -f "${SG_INIT_ENVIRON:-/init.environ.rc}" ]; then
        while IFS= read -r line; do
            set -- $line
            if [ "${1:-}" = export ] && [ "${2:-}" = BOOTCLASSPATH ] && [ -n "${3:-}" ]; then value=$3; break; fi
        done < "${SG_INIT_ENVIRON:-/init.environ.rc}"
    fi
    case "$value" in
        /system/*) ;;
        *) exit 1;;
    esac
    case "$value" in *[!a-zA-Z0-9_./:+@-]*) exit 1;; esac
    sg_write "$value"
)
# Private Dalvik cache so our root jars never write into /data/dalvik-cache.
sg_vm_prepare() (
    sg_path_safe "$1" || exit 3
    for dir in "$1" "$1/dalvik-cache"; do
        sg_path_safe "$dir" || exit 3
        [ ! -e "$dir" ] || [ -d "$dir" ] || exit 3
        mkdir -p "$dir" && chmod 700 "$dir" || exit 1
    done
)
# Generated private diagnostics; no stock baseline or caller-selected paths.
# The reader is a Dalvik process spawned as root: it runs in the background with
# output in a private file and is killed after a fixed limit, so a hung VM can
# neither wedge the caller nor keep operation.lock. Unusable output is unknown.
sg_projection_runtime() (
    set +f
    sg_validate owns_files /system/bin/app_process || exit 2
    sg_runtime=$SG_DATA_ROOT/runtime
    sg_projection=$sg_runtime/wireless-carplay-and-aa
    sg_path_safe "$sg_projection" || exit 3
    sg_mode=$1
    case "$sg_mode" in
        prepare|status|applying|clear|tbt-reset) ;;
        *) exit 2 ;;
    esac
    if [ "$sg_mode" = clear ] && [ ! -e "$sg_projection" ]; then exit 0; fi
    for sg_dir in "$sg_runtime" "$sg_projection" "$sg_projection/vm" "$sg_projection/vm/dalvik-cache"; do
        sg_path_safe "$sg_dir" || exit 3
        if [ -e "$sg_dir" ]; then
            [ -d "$sg_dir" ] || exit 3
            set -- $(sg_file_meta "$sg_dir")
            [ "$2:$3" = 0:0 ] || exit 3
        fi
        mkdir -p "$sg_dir" && chown 0:0 "$sg_dir" && chmod 700 "$sg_dir" || exit 1
    done
    [ "$sg_mode" != prepare ] || exit 0
    # Reader failures: status is unknown, applying stays a pending restart,
    # clear cannot be confirmed (nonzero). Nothing here authorizes a write.
    sg_unknown() {
        sg_log "projection reader: $1" || :
        case "$sg_mode" in
            clear)
                # The tree is root-only private state; remove it directly when
                # the reader could not run. A reader refusal never reaches here.
                rm -rf "$sg_projection" && [ ! -e "$sg_projection" ] || exit 1
                rmdir "$sg_runtime" 2>/dev/null || :
                exit 0 ;;
            applying) sg_print state=pending-restart restart=head_unit "detail=$(sg_clean "$1")" ;;
            tbt-reset) sg_print state=failed restart=none "detail=$(sg_clean "$1")"; exit 1 ;;
            *) sg_print state=unknown restart=none "detail=$(sg_clean "$1")" ;;
        esac
        exit 0
    }
    # OTA dispatch enters through update/current; resolve that package pointer
    # before applying the no-symlink guard to the fixed reader artifact.
    sg_helper_dir=$(readlink -f "$HMG_SEOGAEMO_MODULE_DIR") || exit 1
    sg_helper=$sg_helper_dir/data/hmg-seogaemo-projection-runtime.jar
    sg_path_safe "$sg_helper" && [ -f "$sg_helper" ] || exit 1
    sg_boot=$(sg_bootclasspath) || sg_unknown 'BOOTCLASSPATH unavailable'
    sg_process=${SG_TARGET_ROOT:-}/system/bin/app_process
    if [ -f "$sg_process.hmg-seogaemo-stock" ]; then sg_process=$sg_process.hmg-seogaemo-stock; fi
    sg_limit=${SG_READER_TIMEOUT:-15}
    case "$sg_limit" in ''|*[!0-9]*|0) sg_limit=15;; esac
    [ "$sg_limit" -le 120 ] || sg_limit=120
    # Output files of a run that was killed before its trap could remove them: exact
    # reader.{out,err}.<digits> names in the private data root, unless that PID lives.
    for sg_left in "$SG_DATA_ROOT"/reader.out.* "$SG_DATA_ROOT"/reader.err.*; do
        [ -f "$sg_left" ] || [ -L "$sg_left" ] || continue
        sg_left_pid=${sg_left##*/}; sg_left_pid=${sg_left_pid#reader.out.}; sg_left_pid=${sg_left_pid#reader.err.}
        case "$sg_left_pid" in ''|*[!0-9]*) continue;; esac
        if [ "$sg_left_pid" != "$$" ] && kill -0 "$sg_left_pid" 2>/dev/null; then continue; fi
        rm -f "$sg_left"
    done
    sg_out=$SG_DATA_ROOT/reader.out.$$
    sg_err=$SG_DATA_ROOT/reader.err.$$
    rm -f "$sg_out" "$sg_err"
    sg_reader=
    # Hang-up, interrupt or termination ends the whole Dalvik tree, not only this shell.
    trap '[ -z "$sg_reader" ] || sg_kill_tree "$sg_reader" 3; rm -f "$sg_out" "$sg_err"' EXIT
    trap 'exit 1' HUP INT TERM
    (
        ANDROID_DATA="$sg_projection/vm" BOOTCLASSPATH="$sg_boot" CLASSPATH="$sg_helper" exec "$sg_process" /system/bin com.seogaemo.hmg.runtime.HmgSeogaemoProjectionRuntime "$sg_mode" "$SG_DATA_ROOT" # android44-shell: allow -- fixed package reader via stock API19 app_process
    ) < /dev/null > "$sg_out" 2> "$sg_err" &
    sg_reader=$!
    sg_bounded_wait "$sg_reader" "$sg_limit" && sg_code=0 || sg_code=$?
    sg_reader=
    if [ "$sg_code" -eq 124 ]; then sg_unknown "reader timed out after $sg_limit seconds"; fi
    if [ -s "$sg_err" ]; then sg_log "projection reader: $(dd if="$sg_err" bs=1 count=200 2>/dev/null)" || :; fi
    if [ "$sg_mode" = clear ]; then
        # 126 and above: the VM never ran the reader (missing binary, crash).
        if [ "$sg_code" -ge 126 ]; then sg_unknown "reader failed to start (exit $sg_code)"; fi
        exit "$sg_code"
    fi
    sg_state=; sg_restart=; sg_detail=; sg_lines=0; sg_inexact=; sg_blank=
    if [ -f "$sg_out" ] && [ ! -L "$sg_out" ]; then
        sg_size=$(sg_file_size "$sg_out") || sg_size=99999
    else sg_size=99999; fi
    if [ "$sg_size" -le 2048 ]; then
        while IFS= read -r sg_line; do
            sg_lines=$((sg_lines + 1))
            case "$sg_line" in
                state=*) sg_state=${sg_line#state=};;
                restart=*) sg_restart=${sg_line#restart=};;
                detail=*) sg_detail=${sg_line#detail=};;
                info.tbt_inexact=*) sg_inexact=${sg_line#info.tbt_inexact=};;
                info.tbt_blank=*) sg_blank=${sg_line#info.tbt_blank=};;
                *) sg_lines=99;;
            esac
        done < "$sg_out"
    else sg_lines=99; fi
    case "$sg_state:$sg_restart" in
        on:none|failed:none|unknown:none|pending-restart:head_unit|pending-restart:none) ;;
        *) sg_lines=99 ;;
    esac
    # The two optional tbt counters ride along on status/applying: digits only, both or neither.
    case "$sg_mode:$sg_inexact:$sg_blank" in
        status:*[!0-9]*:*|status:*:*[!0-9]*|applying:*[!0-9]*:*|applying:*:*[!0-9]*) sg_lines=99 ;;
        status:?*:?*|applying:?*:?*) sg_lines=$((sg_lines - 2)) ;;
        *::*) ;;
        *) sg_lines=99 ;;
    esac
    if [ "$sg_lines" -ne 3 ] || { [ "$sg_code" -ne 0 ] && { [ "$sg_code" -ne 1 ] || [ "$sg_state" != failed ]; }; }; then
        sg_unknown "reader gave no valid output (exit $sg_code)"
    fi
    sg_print "state=$sg_state" "restart=$sg_restart" "detail=$(sg_clean "$sg_detail")"
    [ -z "$sg_inexact" ] || sg_print "info.tbt_inexact=$sg_inexact" "info.tbt_blank=$sg_blank"
    [ "$sg_state" != failed ] || exit 1
    exit 0
)
# Private runtime directories that a loaded hook creates inside a system app's
# data directory (Context.getDir, so always /data/data/<package>/app_hmg-seogaemo-<name>).
# The module declares each exact directory in `owns_generated_dirs=`. They hold
# only generated diagnostics and Dalvik output: regular files with plain names, no
# baseline. Removal is advisory and never fails a restore: running hook processes
# keep writing until the head unit restarts, so the pass removes what it can (plain
# regular files, then the directory if it is empty) and leaves anything else
# (symlinks, subdirectories, odd names) untouched.
sg_generated_dirs() {
    sg_gd_list=
    sg_manifest=$HMG_SEOGAEMO_BASE/modules/${HMG_SEOGAEMO_STATE##*/}.properties
    [ -f "$sg_manifest" ] || return 0
    while IFS='=' read -r sg_field sg_values; do
        [ "$sg_field" != owns_generated_dirs ] || sg_gd_list=$sg_values
    done < "$sg_manifest"
    sg_print "$sg_gd_list"
}
# When anything is left, or the running hooks can still recreate it (restart
# pending), the pass records a cleanup marker `<data root>/restart-cleanup/<module id>`
# holding the boot id. `sg_restart_cleanup_run` (boot reconcile) retries it after the
# restart and the marker disappears once the declared directories are gone.
sg_generated_dirs_remove() (
    set +f
    list=$(sg_generated_dirs) || list=
    [ -n "$list" ] || exit 0
    id=${HMG_SEOGAEMO_STATE##*/}
    pending=0
    old_ifs=$IFS; IFS=,
    set -f
    set -- $list
    set +f
    IFS=$old_ifs
    for dir do
        case "$dir" in /data/data/*/app_hmg-seogaemo-*) ;; *) sg_log "generated dir declaration ignored: $dir" || :; continue;; esac
        pkg=${dir#/data/data/}; pkg=${pkg%%/*}; leaf=${dir##*/}
        [ "$dir" = "/data/data/$pkg/$leaf" ] || { sg_log "generated dir declaration ignored: $dir" || :; continue; }
        case "$pkg" in ''|*[!a-zA-Z0-9._]*) continue;; esac
        case "$leaf" in *[!a-zA-Z0-9_-]*) continue;; esac
        target=${SG_TARGET_ROOT:-}$dir
        if ! sg_path_safe "$target"; then pending=1; continue; fi
        [ -e "$target" ] || continue
        if [ ! -d "$target" ]; then pending=1; continue; fi
        left=0; count=0
        for entry in "$target"/* "$target"/.[!.]* "$target"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            count=$((count + 1))
            name=${entry##*/}
            case "$name" in *[!a-zA-Z0-9_.@-]*) left=1; continue;; esac
            if [ "$count" -gt 64 ] || [ -L "$entry" ] || [ ! -f "$entry" ]; then left=1; continue; fi
            rm -f "$entry" 2>/dev/null || left=1
        done
        if [ "$left" -eq 0 ] && rmdir "$target" 2>/dev/null; then
            sg_ledger generated_dir_remove "$target" "" "" "" || sg_log "ledger row failed: generated dir $dir" || :
        else
            pending=1
        fi
    done
    marker_dir=$SG_DATA_ROOT/restart-cleanup
    if [ "$pending" -eq 1 ] || sg_restart_pending; then
        boot=$(cat "${SG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null) || boot=
        { mkdir -p "$marker_dir" && chmod 700 "$marker_dir" &&
            sg_write "$boot" > "$marker_dir/$id.tmp.$$" && mv "$marker_dir/$id.tmp.$$" "$marker_dir/$id"; } ||
            sg_log 'could not record the pending generated directory cleanup' || :
    else
        rm -f "$marker_dir/$id"
        rmdir "$marker_dir" 2>/dev/null || :
    fi
    exit 0
)
# Boot-time retry of recorded cleanups, under the caller's operation lock. A marker
# written during the current boot is left alone (hooks may still be writing); one from an
# earlier boot is retried with the module's own declarations. A module that is desired on
# or holds restore material again uses those directories legitimately: its marker is dropped.
sg_restart_cleanup_run() (
    set +f
    dir=$SG_DATA_ROOT/restart-cleanup
    [ -d "$dir" ] && [ ! -L "$dir" ] || exit 0
    boot=$(cat "${SG_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null) || boot=
    for marker in "$dir"/*; do
        [ -f "$marker" ] && [ ! -L "$marker" ] || continue
        id=${marker##*/}
        case "$id" in ''|-*|*-|*--*|*[!a-z0-9-]*) rm -f "$marker"; continue;; esac
        [ -f "$HMG_SEOGAEMO_BASE/modules/$id.properties" ] || { rm -f "$marker"; continue; }
        saved=
        { IFS= read -r saved < "$marker"; } 2>/dev/null || :
        [ -z "$boot" ] || [ "$saved" != "$boot" ] || continue
        (
            HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/modules/$id
            export HMG_SEOGAEMO_STATE
            if [ "$(cat "$SG_DATA_ROOT/desired/$id" 2>/dev/null)" = on ] || sg_restore_material; then
                rm -f "$marker"; exit 0
            fi
            sg_generated_dirs_remove
        ) || :
    done
    rmdir "$dir" 2>/dev/null || :
    exit 0
)
# Directories below /system/etc/hmg-seogaemo that exist without any journal, left by
# builds before directory journaling. Derived from the module manifests' owned file
# paths (ancestors up to the project namespace) so no list is hand-written; rmdir
# only, so a directory that still holds anything is simply kept.
sg_legacy_dirs_cleanup() (
    set +f
    namespace=/system/etc/hmg-seogaemo
    dirs=
    for manifest in "$HMG_SEOGAEMO_BASE"/modules/*.properties; do
        [ -f "$manifest" ] || continue
        while IFS='=' read -r field values; do
            [ "$field" = owns_files ] || continue
            old_ifs=$IFS; IFS=,
            set -f
            set -- $values
            set +f
            IFS=$old_ifs
            for file do
                case "$file" in "$namespace"/*) ;; *) continue;; esac
                dir=${file%/*}
                while [ "$dir" != "$namespace" ]; do
                    case " $dirs " in *" $dir "*) ;; *) dirs="$dirs $dir";; esac
                    dir=${dir%/*}
                done
            done
        done < "$manifest"
    done
    dirs="$dirs $namespace"
    rw=0
    for pass in 1 2 3; do
        for dir in $dirs; do
            target=${SG_TARGET_ROOT:-}$dir
            [ -d "$target" ] && [ ! -L "$target" ] || continue
            sg_path_safe "$target" || continue
            key=$(sg_file_key "$target") || exit 1
            # A journaled directory belongs to the directory transaction.
            [ ! -f "$SG_DATA_ROOT/payload-dirs/$key/ready" ] || continue
            if [ "$rw" -eq 0 ]; then sg_remount rw || exit 1; rw=1; fi
            if rmdir "$target" 2>/dev/null; then
                sg_ledger legacy_dir_remove "$target" "" "" "" || { sg_remount_ro; exit 1; }
            fi
        done
    done
    if [ "$rw" -eq 1 ]; then sg_remount_ro; fi
    exit 0
)
# Dalvik cache entries that earlier builds left in /data/dalvik-cache for our own
# root jars (mapper, update verifier APK, projection reader). Exact derived names
# only: <our install path with @>@classes.dex.
sg_legacy_dex_cleanup() (
    set +f
    cache=${SG_TARGET_ROOT:-}/data/dalvik-cache
    [ -d "$cache" ] || exit 0
    sg_path_safe "$cache" || exit 3
    for prefix in data@nemesis@apps@hmg-seogaemo data@nemesis@backup@hmg-seogaemo@update; do
        for suffix in @core@map@hmg-seogaemo-mapper.jar@classes.dex \
            @app@hmg-seogaemo.apk@classes.dex \
            @modules@wireless-carplay-and-aa.d@data@hmg-seogaemo-projection-runtime.jar@classes.dex; do
            for entry in "$cache/$prefix"*"$suffix"; do
                [ -f "$entry" ] && [ ! -L "$entry" ] || continue
                name=${entry##*/}
                case "$name" in *[!a-zA-Z0-9_.@-]*) continue;; esac
                middle=${name#"$prefix"}; middle=${middle%"$suffix"}
                case "$middle" in ''|@*) ;; *) continue;; esac
                rm -f "$entry" || exit 1
                sg_ledger dex_legacy_remove "$entry" "" "" "" || exit 1
            done
        done
    done
)
# A staged build that is gone (failed stage, removed version directory) must not
# keep Dalvik cache entries of its jars: remove exactly
# update@versions@<digits.dots><our jar suffix>@classes.dex whose version directory
# under "$1" (the update versions directory) no longer exists.
sg_update_dex_prune() (
    set +f
    cache=${SG_TARGET_ROOT:-}/data/dalvik-cache
    [ -d "$cache" ] || exit 0
    sg_path_safe "$cache" || exit 3
    prefix=data@nemesis@backup@hmg-seogaemo@update@versions@
    for suffix in @core@map@hmg-seogaemo-mapper.jar@classes.dex \
        @app@hmg-seogaemo.apk@classes.dex \
        @modules@wireless-carplay-and-aa.d@data@hmg-seogaemo-projection-runtime.jar@classes.dex; do
        for entry in "$cache/$prefix"*"$suffix"; do
            [ -f "$entry" ] && [ ! -L "$entry" ] || continue
            name=${entry##*/}
            case "$name" in *[!a-zA-Z0-9_.@-]*) continue;; esac
            version=${name#"$prefix"}; version=${version%"$suffix"}
            case "$version" in ''|*[!0-9.]*) continue;; esac
            [ ! -e "$1/$version" ] || continue
            rm -f "$entry" || exit 1
        done
    done
)
# The private Dalvik cache of the mapper and update verifier, and scratch caches
# (`core/vm.status.<digits>`) that an interrupted `map status` left behind.
sg_vm_cleanup() (
    set +f
    for vm in "$SG_DATA_ROOT"/core/vm.status.*; do
        case "${vm##*/vm.status.}" in ''|*[!0-9]*) continue;; esac
        [ -d "$vm" ] && [ ! -L "$vm" ] || continue
        rm -rf "$vm" || exit 1
    done
    vm=$SG_DATA_ROOT/core/vm
    [ -e "$vm" ] || exit 0
    sg_path_safe "$vm" && [ -d "$vm" ] || exit 3
    rm -rf "$vm" && [ ! -e "$vm" ]
)
sg_redact() {
    while IFS= read -r sg_rd_line || [ -n "$sg_rd_line" ]; do
        case "$sg_rd_line" in
            *wifimac:' 'EMPTY|*wifimac:' 'SET) sg_print "$sg_rd_line" ;;
            *wifimac*"[]") sg_print 'ro.boot.wifimac: EMPTY' ;;
            *wifimac*"[]"*|*wifimac=) sg_print 'wifimac: EMPTY' ;;
            *wifimac*) sg_print 'wifimac: SET' ;;
            *[Ss][Ee][Rr][Ii][Aa][Ll]*|*[Bb][Tt][Aa][Dd][Dd][Rr]*|*[Ss][Ss][Ii][Dd]*|*[Pp][Ss][Kk]*|*[Pp][Aa][Ss][Ss][Ww]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*|*[Tt][Oo][Kk][Ee][Nn]*|*[Cc][Rr][Ee][Dd][Ee][Nn]*|*[Ii][Mm][Ee][Ii]*|*[Ii][Mm][Ss][Ii]*|*[Ii][Cc][Cc][Ii][Dd]*|*[Vv][Ii][Nn]=*|*[Hh][Ww][Aa][Dd][Dd][Rr]*|*link/ether*|*[Pp][Hh][Oo][Nn][Ee]?[Nn][Uu][Mm]*)
                sg_print '[redacted]' ;;
            *[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]*)
                sg_print '[redacted]' ;;
            *) sg_print "$sg_rd_line" ;;
        esac
    done
}
sg_owner_present() {
    case "$1" in
        nemesis-adb-tcp) [ -d /data/nemesis/apps/adb.tcp ] || [ -d /data/nemesis/backup/adb.tcp ] ;;
        hmgapi) [ -d /data/nemesis/apps/hmgapi ] || [ -f /data/hmgapi/installed.txt ] ;;
        leafia) [ -d /data/nemesis/apps/wireless.carplay.aa ] || [ -d /data/nemesis/backup/wireless.carplay.aa ] ;;
        local-hkmc-factory82) [ -d /data/nemesis/apps/local.hkmc.factory82 ] || [ -d /data/nemesis/backup/local.hkmc.factory82 ] ;;
        *) return 2 ;;
    esac
}
sg_status() {
    case "$1" in off|on|pending-restart|not-implemented) sg_code=0;; conflict) sg_code=3;; incompatible) sg_code=4;; failed) sg_code=1;; *) return 2;; esac
    case "$2" in none|adbd|head_unit) ;; *) return 2;; esac
    sg_detail=$(sg_clean "${3:-}")
    sg_print "state=$1" "restart=$2" "detail=$sg_detail"
    return "$sg_code"
}

# Core car maps are package-owned data. Publish immutable verified files, then
# replace one pointer file so readers see either the prior map or the new map.
hmg_seogaemo_map_work() {
    HMG_SEOGAEMO_MAP_WORK=$SG_DATA_ROOT/car-maps/.work.$$
    [ ! -e "$HMG_SEOGAEMO_MAP_WORK" ] || return 1
    mkdir -p "$HMG_SEOGAEMO_MAP_WORK" && chmod 700 "$SG_DATA_ROOT/car-maps" "$HMG_SEOGAEMO_MAP_WORK"
}
hmg_seogaemo_map_work_cleanup() {
    case "$HMG_SEOGAEMO_MAP_WORK" in "$SG_DATA_ROOT"/car-maps/.work.*) rm -rf "$HMG_SEOGAEMO_MAP_WORK";; *) return 2;; esac
}
hmg_seogaemo_map_publish() {
    hmg_seogaemo_map_input=$1
    [ "$hmg_seogaemo_map_input" = "$HMG_SEOGAEMO_MAP_WORK" ] || return 2
    for hmg_seogaemo_map_name in map.json car.json verified hash-id map-id source layout; do
        [ -s "$hmg_seogaemo_map_input/$hmg_seogaemo_map_name" ] && [ ! -L "$hmg_seogaemo_map_input/$hmg_seogaemo_map_name" ] || return 1
    done
    hmg_seogaemo_map_product=$(getprop ro.build.product)
    case "$hmg_seogaemo_map_product" in ''|*[!a-zA-Z0-9._-]*) return 2;; esac
    hmg_seogaemo_map_hash=$(cat "$hmg_seogaemo_map_input/hash-id")
    hmg_seogaemo_map_id=$(cat "$hmg_seogaemo_map_input/map-id")
    sg_print "$hmg_seogaemo_map_hash" "$hmg_seogaemo_map_id" | grep -Eqv '^[0-9a-f]{32}$' && return 2
    hmg_seogaemo_map_source=$(cat "$hmg_seogaemo_map_input/source")
    case "$hmg_seogaemo_map_source" in bundled|generated) ;; *) return 2;; esac
    hmg_seogaemo_map_layout=$(cat "$hmg_seogaemo_map_input/layout")
    case "$hmg_seogaemo_map_layout" in
        maps/*/*/*/*) case "$hmg_seogaemo_map_layout" in *..*|*[!a-zA-Z0-9_./-]*) return 2;; esac ;;
        *) return 2;;
    esac
    hmg_seogaemo_map_root=$SG_DATA_ROOT/car-maps
    hmg_seogaemo_map_rel=$hmg_seogaemo_map_product/$hmg_seogaemo_map_hash/$hmg_seogaemo_map_id
    hmg_seogaemo_map_final=$hmg_seogaemo_map_root/$hmg_seogaemo_map_rel
    hmg_seogaemo_map_stage=$hmg_seogaemo_map_root/.publish.$$
    mkdir -p "${hmg_seogaemo_map_final%/*}" "$hmg_seogaemo_map_stage" || return 1
    chmod 700 "$hmg_seogaemo_map_root" "$hmg_seogaemo_map_root/$hmg_seogaemo_map_product" "$hmg_seogaemo_map_root/$hmg_seogaemo_map_product/$hmg_seogaemo_map_hash" "$hmg_seogaemo_map_stage" || return 1
    for hmg_seogaemo_map_name in map.json car.json verified hash-id map-id source layout; do
        cp "$hmg_seogaemo_map_input/$hmg_seogaemo_map_name" "$hmg_seogaemo_map_stage/$hmg_seogaemo_map_name" &&
            cmp "$hmg_seogaemo_map_input/$hmg_seogaemo_map_name" "$hmg_seogaemo_map_stage/$hmg_seogaemo_map_name" >/dev/null 2>&1 &&
            chmod 600 "$hmg_seogaemo_map_stage/$hmg_seogaemo_map_name" || { rm -rf "$hmg_seogaemo_map_stage"; return 1; }
    done
    if [ -d "$hmg_seogaemo_map_final" ]; then
        for hmg_seogaemo_map_name in map.json car.json verified layout; do
            cmp "$hmg_seogaemo_map_stage/$hmg_seogaemo_map_name" "$hmg_seogaemo_map_final/$hmg_seogaemo_map_name" >/dev/null 2>&1 ||
                { rm -rf "$hmg_seogaemo_map_stage"; return 3; }
        done
        rm -rf "$hmg_seogaemo_map_stage" || return 1
    else
        mv "$hmg_seogaemo_map_stage" "$hmg_seogaemo_map_final" || { rm -rf "$hmg_seogaemo_map_stage"; return 1; }
    fi
    [ -f "$hmg_seogaemo_map_root/active" ] && cp "$hmg_seogaemo_map_root/active" "$hmg_seogaemo_map_root/.before.$$" || true
    sg_print "$hmg_seogaemo_map_rel" > "$hmg_seogaemo_map_root/active.tmp.$$" &&
        chmod 600 "$hmg_seogaemo_map_root/active.tmp.$$" &&
        mv "$hmg_seogaemo_map_root/active.tmp.$$" "$hmg_seogaemo_map_root/active" || return 1
    HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/core/map
    mkdir -p "$HMG_SEOGAEMO_STATE" || return 1
    sg_ledger map_publish "$hmg_seogaemo_map_root/active" "$hmg_seogaemo_map_root/.before.$$" "$hmg_seogaemo_map_root/active" "" || return 1
    sg_ledger map_contents "$hmg_seogaemo_map_final/map.json" "" "$hmg_seogaemo_map_final/map.json" "" || return 1
    sg_ledger map_contents "$hmg_seogaemo_map_final/car.json" "" "$hmg_seogaemo_map_final/car.json" "" || return 1
    rm -f "$hmg_seogaemo_map_root/.before.$$"
    hmg_seogaemo_map_prune "$hmg_seogaemo_map_root/$hmg_seogaemo_map_product" "$hmg_seogaemo_map_hash/$hmg_seogaemo_map_id" || :
}
# Every verification publishes a new map id and only the active one is read (the hook
# engines read it once at zygote start), so older copies of this product are removed.
hmg_seogaemo_map_prune() (
    set +f
    for dir in "$1"/*/*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        rel=${dir#"$1"/}
        [ "$rel" != "$2" ] || continue
        case "$rel" in *[!0-9a-f/]*) continue;; esac
        rm -rf "$dir"
    done
    for dir in "$1"/*; do [ ! -d "$dir" ] || rmdir "$dir" 2>/dev/null || :; done
)
hmg_seogaemo_map_active_dir() {
    [ -f "$SG_DATA_ROOT/car-maps/active" ] || return 1
    hmg_seogaemo_map_rel=$(cat "$SG_DATA_ROOT/car-maps/active")
    case "$hmg_seogaemo_map_rel" in
        *..*|/*|*[!a-zA-Z0-9_./-]*) return 2;;
        */*/*) ;;
        *) return 2;;
    esac
    [ -f "$SG_DATA_ROOT/car-maps/$hmg_seogaemo_map_rel/verified" ] || return 1
    sg_print "$SG_DATA_ROOT/car-maps/$hmg_seogaemo_map_rel"
}
hmg_seogaemo_map_export() {
    hmg_seogaemo_map_from=$(hmg_seogaemo_map_active_dir) || return 1
    hmg_seogaemo_map_layout=$(cat "$hmg_seogaemo_map_from/layout") || return 1
    case "$hmg_seogaemo_map_layout" in maps/*/*/*/*) ;; *) return 2;; esac
    case "$hmg_seogaemo_map_layout" in *..*|*[!a-zA-Z0-9_./-]*) return 2;; esac
    hmg_seogaemo_map_to=$1/$hmg_seogaemo_map_layout
    mkdir -p "$hmg_seogaemo_map_to" || return 1
    cp "$hmg_seogaemo_map_from/map.json" "$hmg_seogaemo_map_to/map.json" &&
        cp "$hmg_seogaemo_map_from/car.json" "$hmg_seogaemo_map_to/car.json" &&
        cmp "$hmg_seogaemo_map_from/map.json" "$hmg_seogaemo_map_to/map.json" >/dev/null 2>&1 &&
        cmp "$hmg_seogaemo_map_from/car.json" "$hmg_seogaemo_map_to/car.json" >/dev/null 2>&1
}
