# HMG-Seogaemo restricted module scripts, API 1 (see module-runtime-contract.md).
# Script text is never evaluated: each line is tokenized here and dispatched by
# a fixed case table onto the package API. Source after lib/common.sh.
#
# Environment:
#   HMG_SEOGAEMO_MODULE_DIR  unpacked package (module.properties, strings/, files/)
#   HSM_SETTINGS_DIR         optional directory of saved setting values, one file per key
#   HSM_ACTION               button name for action_is, empty otherwise
#   HSM_RERUN                1 while re-running apply.sh for rerun_on events

HSM_MAX_LINES=512
HSM_MAX_DEPTH=8
hsm_nl='
'

hsm_error() {
    sg_print "HSM-E$1 ${hsm_file##*/}:$hsm_lineno: $2" >&2
    return 2
}

hsm_flush() {
    if [ "$hsm_quoted" -eq 1 ]; then
        [ -n "$hsm_cur" ] || return 2
    elif [ -z "$hsm_cur" ]; then
        return 0
    fi
    hsm_tokens=$hsm_tokens$hsm_cur$hsm_nl
    hsm_count=$((hsm_count + 1))
    hsm_cur=
    hsm_quoted=0
}

hsm_tokenize() {
    hsm_rest=$1
    hsm_tokens=
    hsm_count=0
    hsm_cur=
    hsm_in=0
    hsm_quoted=0
    while [ -n "$hsm_rest" ]; do
        hsm_c=${hsm_rest%"${hsm_rest#?}"}
        hsm_rest=${hsm_rest#?}
        if [ "$hsm_in" -eq 1 ]; then
            case "$hsm_c" in
                '"') hsm_in=0 ;;
                '\')
                    hsm_c=${hsm_rest%"${hsm_rest#?}"}
                    hsm_rest=${hsm_rest#?}
                    case "$hsm_c" in '"'|'\') hsm_cur=$hsm_cur$hsm_c ;; *) return 2 ;; esac ;;
                *) hsm_cur=$hsm_cur$hsm_c ;;
            esac
            continue
        fi
        case "$hsm_c" in
            ' ') hsm_flush || return 2 ;;
            '"')
                [ -z "$hsm_cur" ] && [ "$hsm_quoted" -eq 0 ] || return 2
                hsm_in=1
                hsm_quoted=1 ;;
            '\') return 2 ;;
            *)
                [ "$hsm_quoted" -eq 0 ] || return 2
                hsm_cur=$hsm_cur$hsm_c ;;
        esac
    done
    [ "$hsm_in" -eq 0 ] || return 2
    hsm_flush
}

hsm_ok_prop() { case "$1" in ''|*[!a-zA-Z0-9_.-]*) return 1;; esac; }
hsm_ok_path() {
    case "$1" in /*) ;; *) return 1;; esac
    case "$1" in *..*|*//*|*[!a-zA-Z0-9/._+-]*) return 1;; esac
}
# Resolve only a complete onebin directory component, without evaluating script text.
hsm_line_path() (
    prefix=/system/onebin/@onebin@/
    case "$1" in
        "$prefix"*) hsm_ok_path "/${1#"$prefix"}" || exit 2 ;;
        *) hsm_ok_path "$1" || exit 2 ;;
    esac
    sg_onebin_path "$1"
)
hsm_ok_dir() { case "$1" in */) hsm_ok_path "$1";; *) return 1;; esac; }
hsm_ok_src() {
    case "$1" in files/?*) ;; *) return 1;; esac
    case "$1" in *..*|*//*|*[!a-zA-Z0-9/._+-]*) return 1;; esac
}
hsm_ok_mode() { case "$1" in [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) return 0;; esac; return 1; }
hsm_ok_service() {
    case "$1" in ''|[.-]*|*[.-]|*[!a-zA-Z0-9_.-]*) return 1;; esac
}
hsm_ok_code() {
    case "$1" in ''|0*|*[!0-9]*) return 1;; esac
    [ "${#1}" -le 5 ] && [ "$1" -le 65535 ]
}
hsm_ok_package() { case "$1" in ''|.*|*.|*..*|*[!a-zA-Z0-9_.]*) return 1;; esac; }
hsm_ok_id() { case "$1" in ''|-*|*-|*--*|*[!a-z0-9-]*) return 1;; esac; }
hsm_ok_glob() { case "$1" in ''|*[!A-Za-z0-9.*_-]*) return 1;; esac; }
hsm_ok_name() { case "$1" in ''|*[!a-z0-9_]*) return 1;; esac; }
hsm_ok_value() {
    case "$1" in
        '{setting:'*'}') hsm_v=${1#'{setting:'}; hsm_setting_decl "${hsm_v%'}'}" ;;
        *'{'*|*'}'*) return 1 ;;
    esac
}
hsm_ok_resource() {
    hsm_v=${1%%:*}
    case "$hsm_v" in ''|.*|*.|*..*|*[!a-z0-9._]*) return 1;; esac
    case "$1" in *:*) hsm_ok_name "${1#*:}";; esac
}
hsm_ok_string() {
    case "$1" in @?*) ;; *) return 1;; esac
    hsm_ok_name "${1#@}" || return 1
    grep -q "^${1#@}=" "$HMG_SEOGAEMO_MODULE_DIR/strings/en.txt" 2>/dev/null
}
hsm_ok_payload() {
    hsm_ok_src "$1" || return 1
    [ -f "$HMG_SEOGAEMO_MODULE_DIR/$1" ] && [ ! -L "$HMG_SEOGAEMO_MODULE_DIR/$1" ]
}
hsm_ok_payload_dir() {
    case "$1" in */) hsm_ok_src "${1%/}" || return 1;; *) return 1;; esac
    [ -d "$HMG_SEOGAEMO_MODULE_DIR/$1" ] && [ ! -L "$HMG_SEOGAEMO_MODULE_DIR/${1%/}" ]
}

hsm_setting_decl() {
    hsm_ok_name "$1" || return 1
    hsm_stype=
    while IFS='=' read -r hsm_field hsm_decl; do
        case "$hsm_field" in setting.[1-9]|setting.[1-9][0-9]) ;; *) continue;; esac
        [ "${hsm_decl%%:*}" = "$1" ] || continue
        hsm_decl=${hsm_decl#*:}
        hsm_stype=${hsm_decl%%:*}
        hsm_sdefault=${hsm_decl#*:}
        break
    done < "$HMG_SEOGAEMO_MODULE_DIR/module.properties"
    [ -n "$hsm_stype" ]
}

hsm_setting_valid() {
    case "$hsm_stype" in
        toggle) case "$1" in on|off) return 0;; esac; return 1 ;;
        'choice('*')')
            hsm_v=${hsm_stype#'choice('}
            case "|${hsm_v%')'}|" in *"|$1|"*) ;; *) return 1;; esac
            hsm_ok_name "$1" ;;
        'number('*'..'*')')
            hsm_v=${hsm_stype#'number('}
            hsm_v=${hsm_v%')'}
            case "$1" in ''|-|*[!0-9-]*|?*-*) return 1;; esac
            [ "$1" -ge "${hsm_v%..*}" ] && [ "$1" -le "${hsm_v#*..}" ] ;;
        *) return 1 ;;
    esac
}

hsm_setting_value() {
    hsm_setting_decl "$1" || return 2
    hsm_saved=
    if [ -n "${HSM_SETTINGS_DIR:-}" ] && [ -f "$HSM_SETTINGS_DIR/$1" ]; then
        hsm_saved=$(cat "$HSM_SETTINGS_DIR/$1")
    fi
    if [ -n "$hsm_saved" ] && hsm_setting_valid "$hsm_saved"; then
        sg_print "$hsm_saved"
    else
        sg_print "$hsm_sdefault"
    fi
}

hsm_value() {
    case "$1" in
        '{setting:'*'}') hsm_v=${1#'{setting:'}; hsm_setting_value "${hsm_v%'}'}" ;;
        *) sg_print "$1" ;;
    esac
}

hsm_res_overlap() {
    [ "$1" = "$2" ] && return 0
    case "$1" in "$2".*) return 0;; esac
    case "$2" in "$1".*) return 0;; esac
    return 1
}

hsm_module_props() {
    if [ -f "$SG_DATA_ROOT/installed/$1.properties" ]; then
        sg_print "$SG_DATA_ROOT/installed/$1.properties"
    else
        sg_print "$HMG_SEOGAEMO_BASE/modules/$1.properties"
    fi
}

hsm_uses_on() {
    hsm_want=${1%%:*}
    hsm_wmode=
    case "$1" in *:*) hsm_wmode=${1#*:};; esac
    hsm_others=
    for hsm_desired in "$SG_DATA_ROOT"/desired/*; do
        [ -f "$hsm_desired" ] && hsm_others="$hsm_others ${hsm_desired##*/}"
    done
    for hsm_other in $hsm_others; do
        hsm_ok_id "$hsm_other" || continue
        hsm_desired=$SG_DATA_ROOT/desired/$hsm_other
        [ "$hsm_other" != "${HMG_SEOGAEMO_STATE##*/}" ] || continue
        [ "$(cat "$hsm_desired")" = on ] || continue
        hsm_uses=
        while IFS='=' read -r hsm_field hsm_val; do
            [ "$hsm_field" = uses ] && hsm_uses=$hsm_val
        done < "$(hsm_module_props "$hsm_other")"
        hsm_old_ifs=$IFS
        IFS=,
        for hsm_entry in $hsm_uses; do
            hsm_res=${hsm_entry%%:*}
            hsm_mode=use
            case "$hsm_entry" in *:*) hsm_mode=${hsm_entry#*:};; esac
            hsm_res_overlap "$hsm_want" "$hsm_res" || continue
            if [ -z "$hsm_wmode" ] || [ "$hsm_wmode" = "$hsm_mode" ]; then
                IFS=$hsm_old_ifs
                return 0
            fi
        done
        IFS=$hsm_old_ifs
    done
    return 1
}

hsm_hookpoints_ok() {
    /system/bin/sh "$HMG_SEOGAEMO_BASE/core/hmg-seogaemo-map.sh" status 2>/dev/null | grep -qx 'state=on'
}

hsm_cond() {
    hsm_cop=$1
    shift
    hsm_neg=0
    if [ "$1" = not ]; then hsm_neg=1; shift; fi
    [ "$#" -ge 1 ] || { hsm_error 111 "missing condition"; return; }
    hsm_name=$1
    shift
    case "$hsm_name:$#" in
        setting_is:2) hsm_setting_decl "$1" && hsm_setting_valid "$2" ;;
        prop_is:2) hsm_ok_prop "$1" && hsm_ok_value "$2" ;;
        file_exists:1|file_missing:1) hsm_line_path "$1" >/dev/null ;;
        file_has_line:2) hsm_line_path "$1" >/dev/null && sg_line_text "$2" ;;
        file_md5_is:2) hsm_ok_path "$1" && [ "${#2}" -eq 32 ] && case "$2" in *[!0-9a-f]*) false;; *) true;; esac ;;
        car_is:1) hsm_ok_glob "$1" ;;
        module_on:1) hsm_ok_id "$1" ;;
        hookpoints_ok:0) true ;;
        uses_on:1) hsm_ok_resource "$1" ;;
        action_is:1) hsm_ok_name "$1" ;;
        setting_is:*|prop_is:*|file_exists:*|file_missing:*|file_has_line:*|file_md5_is:*|car_is:*|module_on:*|hookpoints_ok:*|uses_on:*|action_is:*)
            hsm_error 111 "wrong argument count for $hsm_name"; return ;;
        *) hsm_error 110 "unknown condition: $hsm_name"; return ;;
    esac || { hsm_error 112 "bad argument for $hsm_name"; return; }
    [ "$hsm_cop" = eval ] || return 0
    case "$hsm_name" in
        setting_is) [ "$(hsm_setting_value "$1")" = "$2" ] ;;
        prop_is) [ "$(getprop "$1")" = "$(hsm_value "$2")" ] ;;
        file_exists) [ -e "$(hsm_line_path "$1")" ] ;;
        file_missing) [ ! -e "$(hsm_line_path "$1")" ] ;;
        file_has_line) grep -Fxq -e "$2" "$(hsm_line_path "$1")" ;;
        file_md5_is) [ -f "$1" ] && [ ! -L "$1" ] && [ "$(sg_md5 "$1")" = "$2" ] ;;
        car_is) case "$(getprop ro.build.product)" in $1) true;; *) false;; esac ;;
        module_on) [ "$(cat "$SG_DATA_ROOT/desired/$1" 2>/dev/null)" = on ] ;;
        hookpoints_ok) hsm_hookpoints_ok ;;
        uses_on) hsm_uses_on "$1" ;;
        action_is) [ "${HSM_ACTION:-}" = "$1" ] ;;
    esac
    hsm_result=$?
    if [ "$hsm_neg" -eq 1 ]; then
        [ "$hsm_result" -ne 0 ]
    else
        [ "$hsm_result" -eq 0 ]
    fi
    [ $? -eq 0 ] && return 0
    return 1
}

hsm_allowed() {
    case "$hsm_kind:$1" in
        apply:set_prop|apply:put_file|apply:patch_file|apply:put_files|apply:replace_line|apply:put_partition) ;;
        apply:restart_service|apply:call_service|apply:hook_apps|apply:app_data_dir) ;;
        check:block|check:warn|status:info|status:fail|*:log) ;;
        *) return 1 ;;
    esac
}

hsm_verb_check() {
    hsm_name=$1
    shift
    case "$hsm_name" in
        set_prop|put_file|patch_file|put_files|replace_line|put_partition|restart_service|call_service|hook_apps|app_data_dir|block|warn|info|fail|log) ;;
        *) hsm_error 110 "unknown verb: $hsm_name"; return ;;
    esac
    hsm_allowed "$hsm_name" || { hsm_error 113 "$hsm_name is not allowed in ${hsm_file##*/}"; return; }
    hsm_reassert=0
    if [ "$hsm_name" = set_prop ] && [ "${1:-}" = --reassert ]; then hsm_reassert=1; shift; fi
    case "$hsm_name:$#" in
        set_prop:2) hsm_ok_prop "$1" && hsm_ok_value "$2" ;;
        put_file:2|put_file:3) hsm_ok_path "$1" && hsm_ok_payload "$2" && { [ "$#" -eq 2 ] || hsm_ok_mode "$3"; } ;;
        patch_file:2) hsm_ok_path "$1" && hsm_ok_payload "$2" ;;
        put_files:2|put_files:3) hsm_ok_dir "$1" && hsm_ok_payload_dir "$2" && { [ "$#" -eq 2 ] || hsm_ok_mode "$3"; } ;;
        replace_line:3) hsm_line_path "$1" >/dev/null && hsm_ok_value "$2" && hsm_ok_value "$3" ;;
        put_partition:3) hsm_ok_payload "$3" && sg_partition_claim_ok "$(hsm_partition_claim "$@")" ;;
        restart_service:1) hsm_ok_service "$1" ;;
        call_service:2) hsm_ok_service "$1" && hsm_ok_code "$2" ;;
        hook_apps:[3-9]|hook_apps:[1-9][0-9]) hsm_ok_hook "$@" ;;
        app_data_dir:*) hsm_error 120 "app_data_dir is not provided by this runtime yet"; return ;;
        block:1|warn:1|fail:1) hsm_ok_string "$1" ;;
        info:3)
            hsm_ok_name "$1" && case "$2" in
                prop) hsm_ok_prop "$3" ;;
                setting) hsm_setting_decl "$3" ;;
                *) false ;;
            esac ;;
        log:*) [ "$#" -ge 1 ] ;;
        *) hsm_error 111 "wrong argument count for $hsm_name"; return ;;
    esac || { hsm_error 112 "bad argument for $hsm_name"; return; }
    case "$hsm_name" in replace_line)
        case "$2" in '{setting:'*) hsm_error 112 "stock line must be literal"; return;; esac ;;
    esac
    [ "$hsm_op" = touched ] || return 0
    case "$hsm_name" in
        set_prop)
            sg_print "prop	$1"
            [ "$hsm_reassert" -eq 0 ] || sg_print "reassert	$1" ;;
        put_file|patch_file) sg_print "file	$1" ;;
        put_files)
            for hsm_src in "$HMG_SEOGAEMO_MODULE_DIR/$2"*; do
                [ -f "$hsm_src" ] && [ ! -L "$hsm_src" ] || continue
                sg_print "file	$1${hsm_src##*/}"
            done ;;
        replace_line) sg_print "line	$(hsm_line_path "$1"):$2" ;;
        put_partition) sg_print "part	$(hsm_partition_claim "$@")" ;;
        restart_service) sg_print "service	$1" ;;
        call_service) sg_print "call	$1:$2" ;;
        hook_apps)
            hsm_hdir=$(hsm_hook_dir)
            sg_print "file	$hsm_hdir/hook.jar" "file	$hsm_hdir/entry" "file	$hsm_hdir/processes" "hook	1" ;;
    esac
}

hsm_put_file() {
    hsm_ok_path "$1" || return 2
    sg_payload_dirs "$1" || return 1
    sg_file_put "$1" "$2" "${3:-644}" 0:0
}

# The range a put_partition line owns: <name>:<offset>:<payload size>.
hsm_partition_claim() { sg_print "$1:$2:$(sg_file_size "$HMG_SEOGAEMO_MODULE_DIR/$3")"; }

hsm_module_id() { sg_print "${HSM_MODULE_ID:-${HMG_SEOGAEMO_STATE##*/}}"; }
hsm_hook_dir() { sg_print "$SG_DATA_ROOT/core/hook/mods/$(hsm_module_id)"; }
hsm_ok_hook() {
    case "$1" in *.jar) hsm_ok_payload "$1" || return 1;; *) return 1;; esac
    case "$2" in ''|.*|*.|*..*|*[!A-Za-z0-9_.$]*) return 1;; *.*) ;; *) return 1;; esac
    shift 2
    for hsm_proc in "$@"; do
        case "$hsm_proc" in ''|*[!a-zA-Z0-9_.:]*) return 1;; esac
    done
}

# Registers the module's hook jar with the core hook host (runtime API).
hsm_hook_apps() { sg_hook_register "$@"; }

hsm_has_baseline() {
    [ -f "$HMG_SEOGAEMO_STATE/prop.$1/ready" ]
}

hsm_verb_run() {
    hsm_name=$1
    shift
    case "$hsm_name" in
        set_prop)
            [ "$1" != --reassert ] || shift
            if [ "${HSM_RERUN:-0}" = 1 ] && ! hsm_has_baseline "$1"; then
                sg_log "rerun refused new baseline for $1"
                return 1
            fi
            sg_prop_set "$1" "$(hsm_value "$2")" ;;
        put_file) hsm_put_file "$@" ;;
        put_files)
            hsm_files=
            for hsm_src in "$HMG_SEOGAEMO_MODULE_DIR/$2"*; do
                [ -f "$hsm_src" ] && [ ! -L "$hsm_src" ] || continue
                hsm_files=$hsm_files${hsm_src##*/}$hsm_nl
            done
            hsm_old_ifs=$IFS
            IFS=$hsm_nl
            for hsm_src in $hsm_files; do
                IFS=$hsm_old_ifs
                hsm_put_file "$1$hsm_src" "$2$hsm_src" "${3:-644}" || return
            done
            IFS=$hsm_old_ifs ;;
        patch_file) sg_file_put_delta "$@" ;;
        replace_line) sg_file_replace_line "$(hsm_line_path "$1")" "$2" "$(hsm_value "$3")" ;;
        put_partition)
            if [ "${HSM_RERUN:-0}" = 1 ] && [ ! -f "$(sg_partition_dir "$(hsm_partition_claim "$@")")/ready" ]; then
                sg_log "rerun refused new baseline for $1"
                return 1
            fi
            sg_partition_put "$1" "$2" "$3" ;;
        restart_service) sg_service_restart "$1" ;;
        call_service) sg_service_call "$1" "$2" ;;
        hook_apps) hsm_hook_apps "$@" ;;
        log) sg_log "$*" ;;
        warn) sg_print "warn=$1" ;;
        block) sg_print "block=$1"; return 3 ;;
        fail) sg_print "fail=$1" ;;
        info)
            case "$2" in
                prop) hsm_v=$(getprop "$3") ;;
                setting) hsm_v=$(hsm_setting_value "$3") ;;
            esac
            sg_print "info.$1=$(sg_clean "$hsm_v")" ;;
    esac
}

hsm_active() { case "$hsm_stack" in *[FDd]*) return 1;; esac; }
hsm_top() { hsm_t=${hsm_stack#"${hsm_stack%?}"}; }

# hsm_walk FILE KIND OP
#   KIND: apply | check | status (which verbs the file may use)
#   OP:   validate | touched | run
# validate and touched visit every branch; run follows the taken branches.
hsm_walk() {
    hsm_file=$1
    hsm_kind=$2
    hsm_op=$3
    [ -f "$hsm_file" ] && [ ! -L "$hsm_file" ] || { hsm_lineno=0; hsm_error 100 "missing script"; return; }
    if LC_ALL=C grep -q '[[:cntrl:]]' "$hsm_file"; then
        hsm_lineno=0
        hsm_error 103 "control characters (including tab and CR) are not allowed"
        return
    fi
    hsm_lineno=0
    hsm_stack=
    hsm_wantthen=0
    while IFS= read -r hsm_line || [ -n "$hsm_line" ]; do
        hsm_lineno=$((hsm_lineno + 1))
        [ "$hsm_lineno" -le "$HSM_MAX_LINES" ] || { hsm_error 101 "more than $HSM_MAX_LINES lines"; return; }
        while :; do case "$hsm_line" in ' '*) hsm_line=${hsm_line#' '};; *) break;; esac; done
        while :; do case "$hsm_line" in *' ') hsm_line=${hsm_line%' '};; *) break;; esac; done
        case "$hsm_line" in ''|'#'*) continue;; esac
        if [ "$hsm_wantthen" -eq 1 ]; then
            [ "$hsm_line" = then ] || { hsm_error 104 "expected then"; return; }
            hsm_wantthen=0
            continue
        fi
        hsm_inline=0
        case "$hsm_line" in
            *' ; then') hsm_line=${hsm_line%' ; then'}; hsm_inline=1 ;;
            *'; then') hsm_line=${hsm_line%'; then'}; hsm_inline=1 ;;
        esac
        hsm_tokenize "$hsm_line" || { hsm_error 102 "bad quoting"; return; }
        hsm_old_ifs=$IFS
        IFS=$hsm_nl
        set -f
        set -- $hsm_tokens
        set +f
        IFS=$hsm_old_ifs
        case "$1" in
            if)
                shift
                [ "${#hsm_stack}" -lt "$HSM_MAX_DEPTH" ] || { hsm_error 106 "if nested deeper than $HSM_MAX_DEPTH"; return; }
                if [ "$hsm_op" = run ] && hsm_active; then
                    if hsm_cond eval "$@"; then hsm_stack=${hsm_stack}T; else
                        [ $? -eq 1 ] || return 2
                        hsm_stack=${hsm_stack}F
                    fi
                else
                    hsm_cond check "$@" || return
                    if [ "$hsm_op" = run ]; then hsm_stack=${hsm_stack}D; else hsm_stack=${hsm_stack}T; fi
                fi
                [ "$hsm_inline" -eq 1 ] || hsm_wantthen=1 ;;
            elif)
                shift
                [ -n "$hsm_stack" ] || { hsm_error 105 "elif without if"; return; }
                hsm_top
                case "$hsm_t" in t|d) hsm_error 105 "elif after else"; return;; esac
                hsm_parent=${hsm_stack%?}
                if [ "$hsm_op" = run ] && [ "$hsm_t" = F ]; then
                    if hsm_cond eval "$@"; then hsm_stack=${hsm_parent}T; else
                        [ $? -eq 1 ] || return 2
                        hsm_stack=${hsm_parent}F
                    fi
                else
                    hsm_cond check "$@" || return
                    [ "$hsm_op" != run ] || hsm_stack=${hsm_parent}D
                fi
                [ "$hsm_inline" -eq 1 ] || hsm_wantthen=1 ;;
            else|fi|then)
                [ "$#" -eq 1 ] && [ "$hsm_inline" -eq 0 ] || { hsm_error 111 "$1 takes no arguments"; return; }
                [ "$1" != then ] || { hsm_error 104 "unexpected then"; return; }
                [ -n "$hsm_stack" ] || { hsm_error 105 "$1 without if"; return; }
                hsm_top
                hsm_parent=${hsm_stack%?}
                if [ "$1" = fi ]; then
                    hsm_stack=$hsm_parent
                else
                    case "$hsm_t" in
                        T) hsm_stack=${hsm_parent}d ;;
                        F) hsm_stack=${hsm_parent}t ;;
                        D) hsm_stack=${hsm_parent}d ;;
                        *) hsm_error 105 "second else"; return ;;
                    esac
                    [ "$hsm_op" = run ] || hsm_stack=${hsm_parent}t
                fi ;;
            *)
                [ "$hsm_inline" -eq 0 ] || { hsm_error 104 "unexpected then"; return; }
                if [ "$hsm_op" = run ]; then
                    hsm_active || continue
                    hsm_verb_check "$@" || return
                    hsm_verb_run "$@" || return
                else
                    hsm_verb_check "$@" || return
                fi ;;
        esac
    done < "$hsm_file"
    [ "$hsm_wantthen" -eq 0 ] || { hsm_error 104 "expected then"; return; }
    [ -z "$hsm_stack" ] || { hsm_error 105 "missing fi"; return; }
    return 0
}
