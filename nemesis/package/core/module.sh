#!/system/bin/sh
# Fixed installed-module commands: install <sha256>, remove <id>, list, usb-import, install-bundled,
# list-removed <xx>, add-bundled <id>.
# Packages come only from fixed inbox directories, by content digest.
umask 077
base=${0%/*}
base=${base%/core}
SG_DATA_ROOT=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}
HMG_SEOGAEMO_BASE=$base
HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/core/module
export SG_DATA_ROOT HMG_SEOGAEMO_BASE HMG_SEOGAEMO_STATE
. "$base/lib/common.sh"
. "$base/lib/hsm.sh"
case "${1:-}:$#" in list:1|usb-import:1|install-bundled:1|install:2|remove:2|describe:3|list-removed:2|add-bundled:2) ;; *) exit 2;; esac
bundled=$base/bundled
mi_mode=direct
installed=$SG_DATA_ROOT/installed
lock=$SG_DATA_ROOT/operation.lock
lock_owned=0
work=
mi_pid=
cleanup() {
    if [ -n "$mi_pid" ]; then sg_kill_tree "$mi_pid"; wait "$mi_pid" 2>/dev/null || :; fi
    [ -z "$work" ] || rm -rf "$work.hsm" "$work.d" "$work.properties" "$work.touched"
    [ "$lock_owned" -eq 0 ] || rm -rf "$lock"
    return 0
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mi_fail() { sg_status failed none "$1"; exit 1; }
mi_conflict() { sg_status conflict none "$1"; exit 3; }

mi_lock() {
    mkdir -p "$SG_DATA_ROOT" || exit 1
    mi_tries=0
    while ! mkdir "$lock" 2>/dev/null; do
        if [ -f "$lock/pid" ]; then
            mi_holder=$(cat "$lock/pid" 2>/dev/null)
            case "$mi_holder" in ''|*[!0-9]*) ;; *)
                if ! kill -0 "$mi_holder" 2>/dev/null; then rm -rf "$lock"; continue; fi;;
            esac
        fi
        mi_tries=$((mi_tries + 1))
        [ "$mi_tries" -lt 10 ] || mi_fail 'Module operation busy'
        sleep 1
    done
    lock_owned=1
    sg_write "$$" > "$lock/pid"
}

mi_field() {
    mi_value=
    [ -f "$2" ] || return 0
    while IFS='=' read -r mi_key mi_val; do
        [ "$mi_key" = "$1" ] && mi_value=$mi_val
    done < "$2"
    sg_print "$mi_value"
}

mi_snake() {
    mi_chars=$1
    mi_out=
    while [ -n "$mi_chars" ]; do
        mi_c=${mi_chars%"${mi_chars#?}"}
        mi_chars=${mi_chars#?}
        [ "$mi_c" != - ] || mi_c=_
        mi_out=$mi_out$mi_c
    done
    sg_write "$mi_out"
}

mi_list() {
    mi_n=0
    for mi_id in $(sg_module_list "$base"); do
        mi_n=$((mi_n + 1))
        mi_props=$(sg_module_props "$base" "$mi_id")
        if sg_module_builtin "$base" "$mi_id"; then mi_source=builtin; else mi_source=$(mi_field source "$mi_props"); fi
        [ "$mi_source" = bundled ] || [ "$mi_source" = builtin ] || mi_source=direct
        sg_print "info.module_$(mi_snake "$mi_id")=$mi_id,$(mi_field version "$mi_props"),$mi_source,$mi_n"
    done
    sg_status on none 'Module list'
}

# Copies USB packages from <drive>/HSM/ into the app-readable inbox; the app cannot read USB mounts.
mi_usb_import() {
    mi_dest=${SG_HSM_USB_INBOX:-/data/data/com.seogaemo.hmg/files/hsm-usb}
    mi_app=${mi_dest%/*}
    [ -d "$mi_app" ] && [ ! -L "$mi_app" ] || mi_fail 'App storage not ready'
    [ ! -L "$mi_dest" ] || mi_fail 'Could not prepare USB inbox'
    mkdir -p "$mi_dest" && chmod 755 "$mi_dest" || mi_fail 'Could not prepare USB inbox'
    for mi_old in "$mi_dest"/*; do
        [ ! -e "$mi_old" ] && [ ! -L "$mi_old" ] || rm -rf "$mi_old" || mi_fail 'Could not prepare USB inbox'
    done
    mi_n=0
    for mi_drive in ${SG_USB_DIRS:-/storage/usb0 /storage/usb1 /storage/usb2 /mnt/media_rw/usb0 /mnt/media_rw/usb1 /mnt/media_rw/usb2}; do
        grep -q " $mi_drive " "${SG_MOUNTS_FILE:-/proc/mounts}" 2>/dev/null || continue
        for mi_file in "$mi_drive"/HSM/*.hsm "$mi_drive"/HSM/*.HSM "$mi_drive"/hsm/*.hsm "$mi_drive"/hsm/*.HSM; do
            [ -f "$mi_file" ] && [ ! -L "$mi_file" ] || continue
            mi_name=${mi_file##*/}
            mi_name=${mi_name%.*}
            case "$mi_name" in ''|.*|*[!A-Za-z0-9._-]*) continue;; esac
            [ "${#mi_name}" -le 80 ] || continue
            set -- $(ls -ln "$mi_file")
            case "$5" in *[!0-9]*|'') mi_size=$4;; *) mi_size=$5;; esac
            case "$mi_size" in ''|*[!0-9]*) continue;; esac
            [ "$mi_size" -gt 0 ] && [ "$mi_size" -le 10485760 ] || continue
            [ ! -e "$mi_dest/$mi_name.hsm" ] || continue
            [ "$mi_n" -lt 20 ] || break 2
            cp "$mi_file" "$mi_dest/$mi_name.hsm" && chmod 644 "$mi_dest/$mi_name.hsm" ||
                mi_fail 'Could not copy package'
            mi_n=$((mi_n + 1))
        done
    done
    sg_print "info.count=$mi_n"
    sg_status on none "Found $mi_n packages on USB"
}

mi_csv_each() {
    [ -n "$1" ] || return 0
    while IFS= read -r mi_item; do
        case "$2" in
            glob) hsm_ok_glob "$mi_item" ;;
            event) case "$mi_item" in boot|screen_on) ;; *) false;; esac ;;
            known) sg_module_known "$base" "$mi_item" ;;
            id) hsm_ok_id "$mi_item" ;;
            owner) sg_owner_present "$mi_item"; [ $? -ne 2 ] ;;
            resource) hsm_ok_resource "$mi_item" ;;
            *) false ;;
        esac || return 1
    done <<EOF
$(sg_csv_items "$1")
EOF
}

mi_check_props() {
    mi_pkg=$1
    HMG_SEOGAEMO_MODULE_DIR=$mi_pkg
    mi_props=$mi_pkg/module.properties
    mi_product=$(getprop ro.build.product)
    mi_seen=
    while IFS= read -r mi_line || [ -n "$mi_line" ]; do
        case "$mi_line" in ''|'#'*) continue;; *=*) ;; *) mi_fail "HSM-E200 module.properties: malformed line";; esac
        mi_key=${mi_line%%=*}
        mi_val=${mi_line#*=}
        case " $mi_seen " in *" $mi_key "*) mi_fail "HSM-E201 module.properties: duplicate $mi_key";; esac
        mi_seen="$mi_seen $mi_key"
        case "$mi_key" in
            id) hsm_ok_id "$mi_val" && [ "${#mi_val}" -le 48 ] ;;
            version) case "$mi_val" in [0-9]*.[0-9]*.[0-9]*) case "$mi_val" in *[!0-9.]*|*..*) false;; esac;; *) false;; esac ;;
            api) [ "$mi_val" = 1 ] ;;
            cars) [ -n "$mi_val" ] && mi_csv_each "$mi_val" glob ;;
            restart) case "$mi_val" in none|adbd|head_unit) ;; *) false;; esac ;;
            rerun_on) mi_csv_each "$mi_val" event ;;
            depends) mi_csv_each "$mi_val" known ;;
            not_with) mi_csv_each "$mi_val" id ;;
            conflicts) mi_csv_each "$mi_val" owner ;;
            uses) mi_csv_each "$mi_val" resource ;;
            stock_file.[1-9]|stock_file.[1-9][0-9])
                # <path>:<md5> applies to every cars glob; <product glob>:<path>:<md5> to that firmware.
                mi_sf=$mi_val
                case "$mi_sf" in /*) ;; *) hsm_ok_glob "${mi_sf%%:*}" && mi_sf=${mi_sf#*:} ;; esac &&
                hsm_ok_path "${mi_sf%:*}" && case "${mi_sf##*:}" in
                    ????????????????????????????????) case "${mi_val##*:}" in *[!0-9a-f]*) false;; esac ;;
                    *) false ;;
                esac ;;
            hookpoints) [ -f "$mi_pkg/$mi_val" ] && case "$mi_val" in files/*) hsm_ok_src "$mi_val";; *) false;; esac ;;
            setting.[1-9]|setting.[1-9][0-9])
                hsm_setting_decl "${mi_val%%:*}" && hsm_setting_valid "$hsm_sdefault" ;;
            kind) case "$mi_val" in toggle|action) ;; *) false;; esac ;;
            icon) case "$mi_val" in box|wifi|phone|terminal|car|gear|display|speaker|camera|map|power|key|skip|button|link|bolt) ;; *) false;; esac ;;
            raw_shell) [ "$mi_mode" = bundled ] && [ "$mi_val" = 1 ] || mi_fail "HSM-E202 raw_shell is allowed only for modules bundled with HMG-Seogaemo" ;;
            replaces)
                [ "$mi_mode" = bundled ] || mi_fail "HSM-E203 module.properties: unknown key $mi_key"
                mi_rv_ifs=$IFS; IFS=,; mi_rv_ok=1
                for mi_rv in $mi_val; do
                    hsm_ok_id "$mi_rv" && [ "$mi_rv" != "$(mi_field id "$mi_props")" ] || mi_rv_ok=0
                done
                IFS=$mi_rv_ifs
                [ -n "$mi_val" ] && [ "$mi_rv_ok" -eq 1 ] ;;
            replaces_setting.*)
                [ "$mi_mode" = bundled ] || mi_fail "HSM-E203 module.properties: unknown key $mi_key"
                hsm_ok_id "${mi_key#replaces_setting.}" && case ",$(mi_field replaces "$mi_props")," in
                    *",${mi_key#replaces_setting.},"*) grep -q "^setting\.[0-9]*=${mi_val%%:*}:" "$mi_props" ;;
                    *) false ;;
                esac ;;
            hooks) [ "$mi_mode" = bundled ] && [ "$mi_val" = 1 ] && mi_raw "$mi_pkg" || mi_fail "HSM-E203 module.properties: unknown key $mi_key" ;;
            owns_props|reassert_props|owns_files|owns_generated_dirs|services|service_calls|restore|owns_lines.[1-9]|owns_lines.[1-9][0-9])
                [ "$mi_mode" = bundled ] || mi_fail "HSM-E203 module.properties: unknown key $mi_key"
                mi_check_owned "$mi_key" "$mi_val" ;;
            kmods|daemons|owns_ifaces|derived_bins|kmod.*|kmod_params.*|daemon.*|daemon_user.*|derived_bin.*|net_rules.*)
                [ "$mi_mode" = bundled ] || mi_fail "HSM-E203 module.properties: unknown key $mi_key"
                sg_transient_decl_ok "$mi_key" "$mi_val" ;;
            *) mi_fail "HSM-E203 module.properties: unknown key $mi_key" ;;
        esac || mi_fail "HSM-E204 module.properties: bad value for $mi_key"
    done < "$mi_props"
    for mi_required in id version api cars; do
        case " $mi_seen " in *" $mi_required "*) ;; *) mi_fail "HSM-E205 module.properties: missing $mi_required";; esac
    done
    if [ "$(mi_field kind "$mi_props")" = action ]; then
        for mi_key in $mi_seen; do
            case "$mi_key" in
                setting.*|hookpoints|depends|rerun_on|stock_file.*|not_with|hooks|raw_shell|replaces|replaces_setting.*)
                    mi_fail "HSM-E211 module.properties: kind=action cannot declare $mi_key" ;;
            esac
        done
        grep -q '^button ' "$mi_pkg/ui.txt" 2>/dev/null || mi_fail 'HSM-E212 ui.txt: kind=action needs a button block'
    fi
    sg_csv_glob_match "$(mi_field cars "$mi_props")" "$mi_product" || { sg_status incompatible none "Not built for $mi_product"; exit 4; }
    if grep -q '^owns_lines\.[0-9]*=[^:]*@onebin@' "$mi_props"; then
        sg_onebin_path @onebin@ >/dev/null ||
            { sg_status incompatible none "Unsupported onebin: $(getprop ro.mobis.onebindir)"; exit 4; }
    fi
    for mi_key in name summary; do
        grep -q "^$mi_key=" "$mi_pkg/strings/en.txt" 2>/dev/null || mi_fail "HSM-E206 strings/en.txt: missing $mi_key"
    done
    mi_hooks=$(mi_field hookpoints "$mi_props")
    if [ -n "$mi_hooks" ]; then
        while IFS= read -r mi_point || [ -n "$mi_point" ]; do
            case "$mi_point" in ''|*[!a-z0-9_.]*) mi_fail "HSM-E207 $mi_hooks: bad hookpoint ID";; esac
        done < "$mi_pkg/$mi_hooks"
    fi
}

# Declared touched list of a raw_shell bundled module (the runtime enforces it like a built-in's).
mi_check_owned() {
    mi_old_ifs=$IFS
    IFS=,
    for mi_item in $2; do
        IFS=$mi_old_ifs
        case "$1" in
            owns_props|reassert_props) hsm_ok_prop "$mi_item" ;;
            owns_files|owns_generated_dirs) hsm_ok_path "$mi_item" ;;
            services) hsm_ok_service "$mi_item" ;;
            service_calls) hsm_ok_service "${mi_item%:*}" && hsm_ok_code "${mi_item##*:}" ;;
            restore) case "$mi_item" in exact|reboot) ;; *) false;; esac ;;
            owns_lines.*) hsm_ok_path "$(sg_onebin_subst "${2%%:*}" onebin)" && case "$2" in *:?*) ;; *) false;; esac; IFS=$mi_old_ifs; return ;;
        esac || { IFS=$mi_old_ifs; return 1; }
    done
    IFS=$mi_old_ifs
}

mi_raw() { grep -Fxq raw_shell=1 "$1/module.properties"; }

# One line per declared target, in the format hsm_walk touched writes.
mi_declared_touched() {
    while IFS='=' read -r mi_key mi_val; do
        mi_old_ifs=$IFS
        IFS=,
        case "$mi_key" in
            owns_props) for mi_t in $mi_val; do sg_print "prop	$mi_t"; done ;;
            reassert_props) for mi_t in $mi_val; do sg_print "reassert	$mi_t"; done ;;
            owns_files) for mi_t in $mi_val; do sg_print "file	$mi_t"; done ;;
            services) for mi_t in $mi_val; do sg_print "service	$mi_t"; done ;;
            service_calls) for mi_t in $mi_val; do sg_print "call	$mi_t"; done ;;
            owns_lines.*) sg_print "line	$(sg_onebin_path "${mi_val%%:*}"):${mi_val#*:}" ;;
            hooks) sg_print "hook	1" ;;
        esac
        IFS=$mi_old_ifs
    done < "$1/module.properties"
}

# Persistent ownership (stock files, properties, lines, services, hooks) of a generated manifest.
mi_persistent() {
    grep -E '^(owns_props|reassert_props|owns_files|owns_generated_dirs|services|service_calls|restore|hooks|owns_lines\.[0-9]+)=' "$1" 2>/dev/null
}

# replaces=<old>[,<old>...]: a renamed bundled module, or one that merges several, takes over
# the old modules' desired state, settings, baselines and applied records without touching the
# system. Every target an old module owns must be owned by the new one; old modules must be
# bundled and must not share text lines (shared-line patches are keyed by module id).
# migrate/<new> journals the takeover so an interrupted run finishes on the next bundled check.
# When every old module was removed by the owner, the new one stays removed (unless the owner adds it
# back explicitly: mi_explicit=1).
mi_items() {
    for mi_if in "$@"; do mi_persistent "$mi_if"; done | while IFS='=' read -r mi_ik mi_iv; do
        case "$mi_ik" in
            owns_props|reassert_props|owns_files|owns_generated_dirs|services|service_calls)
                mi_iifs=$IFS; IFS=,
                for mi_ix in $mi_iv; do [ -z "$mi_ix" ] || sg_print "$mi_ik=$mi_ix"; done
                IFS=$mi_iifs ;;
            owns_lines.*) sg_print "owns_lines=$mi_iv" ;;
            *) sg_print "$mi_ik=$mi_iv" ;;
        esac
    done
}
# Entries of modules/<old>/ that cannot merge into modules/<new>/ (read-only check).
mi_merge_clash() (
    set +f
    src=$SG_DATA_ROOT/modules/$1; dst=$SG_DATA_ROOT/modules/$mi_id
    for entry in "$src"/* "$src"/.[!.]*; do
        [ -e "$entry" ] || continue
        name=${entry##*/}
        [ -e "$dst/$name" ] || continue
        case "$name" in changes|module.log) continue;; esac
        [ -f "$entry" ] && [ -f "$dst/$name" ] && cmp "$entry" "$dst/$name" >/dev/null 2>&1 && continue
        sg_print "$name"; exit 0
    done
    exit 1
)
mi_merge_state() (
    set +f
    src=$SG_DATA_ROOT/modules/$1; dst=$SG_DATA_ROOT/modules/$mi_id
    [ -d "$src" ] || exit 0
    if [ ! -e "$dst" ]; then mv "$src" "$dst"; exit $?; fi
    for entry in "$src"/* "$src"/.[!.]*; do
        [ -e "$entry" ] || continue
        name=${entry##*/}; target=$dst/$name
        if [ ! -e "$target" ]; then mv "$entry" "$target" || exit 1
        elif [ "$name" = changes ]; then
            while IFS= read -r line; do
                grep -Fxq -- "$line" "$target" || sg_print "$line" >> "$target" || exit 1
            done < "$entry"
            rm -f "$entry"
        elif [ "$name" = module.log ]; then cat "$entry" >> "$target" && rm -f "$entry" || exit 1
        elif [ -f "$entry" ] && cmp "$entry" "$target" >/dev/null 2>&1; then rm -f "$entry"
        else exit 3
        fi
    done
    rmdir "$src"
)
mi_replaces_prepare() {
    mi_migrating=0
    mi_olds=$(mi_field replaces "$work.d/module.properties")
    [ "$mi_mode" = bundled ] && [ -n "$mi_olds" ] || return 0
    mi_journal=$SG_DATA_ROOT/migrate/$mi_id
    mi_rifs=$IFS; IFS=,; set -- $mi_olds; IFS=$mi_rifs
    if [ ! -f "$mi_journal" ]; then
        mi_present=; mi_removed=0
        for mi_old do
            if [ -f "$installed/$mi_old.properties" ]; then mi_present="$mi_present $mi_old"
            elif [ -f "$SG_DATA_ROOT/bundled-removed/$mi_old" ]; then mi_removed=$((mi_removed + 1))
            fi
        done
        if [ -z "$mi_present" ]; then
            if [ "$mi_removed" -eq "$#" ] && [ ! -d "$installed/$mi_id" ] && [ "${mi_explicit:-0}" -ne 1 ]; then
                mkdir -p "$SG_DATA_ROOT/bundled-removed" && : > "$SG_DATA_ROOT/bundled-removed/$mi_id" ||
                    mi_fail 'Could not record module removal'
                sg_status off none "$mi_olds was removed by the owner; $mi_id stays removed"
                exit 0
            fi
            return 0
        fi
        [ ! -d "$installed/$mi_id" ] || mi_conflict "$mi_id and$mi_present are both installed"
        mi_items "$work.properties" > "$work.items.new" || mi_fail 'Could not read module ownership'
        mi_with_settings=0
        for mi_old in $mi_present; do
            [ "$(mi_field source "$installed/$mi_old.properties")" = bundled ] || mi_conflict "$mi_old is not bundled"
            ! grep -q '^owns_lines\.' "$installed/$mi_old.properties" || mi_conflict "$mi_old shares text lines"
            mi_items "$installed/$mi_old.properties" | while IFS= read -r mi_item; do
                grep -Fxq -- "$mi_item" "$work.items.new" || exit 1
            done || mi_conflict "$mi_id does not touch the same targets as $mi_old"
            if mi_clash=$(mi_merge_clash "$mi_old"); then mi_conflict "$mi_id cannot merge $mi_old state: $mi_clash"; fi
            [ ! -e "$SG_DATA_ROOT/settings/$mi_old" ] || mi_with_settings=$((mi_with_settings + 1))
            for mi_area in restart-cleanup peer; do
                [ ! -e "$SG_DATA_ROOT/$mi_area/$mi_old" ] || [ ! -e "$SG_DATA_ROOT/$mi_area/$mi_id" ] ||
                    mi_conflict "$mi_id already has $mi_area state"
            done
        done
        [ "$mi_with_settings" -le 1 ] || mi_conflict "More than one replaced module has settings"
        for mi_area in desired settings; do
            [ ! -e "$SG_DATA_ROOT/$mi_area/$mi_id" ] || mi_conflict "$mi_id already has $mi_area state"
        done
        mkdir -p "$SG_DATA_ROOT/migrate" && sg_write "${mi_present# }" > "$mi_journal" ||
            mi_fail 'Could not record module takeover'
    fi
    mi_present=$(cat "$mi_journal") || mi_fail 'Module takeover journal damaged'
    for mi_old in $mi_present; do
        hsm_ok_id "$mi_old" || mi_fail 'Module takeover journal damaged'
        mi_merge_state "$mi_old" || mi_fail 'Could not move module state'
        if [ "$(cat "$SG_DATA_ROOT/desired/$mi_old" 2>/dev/null)" = on ]; then
            mi_set=$(mi_field "replaces_setting.$mi_old" "$work.d/module.properties")
            if [ -n "$mi_set" ]; then
                mkdir -p "$SG_DATA_ROOT/settings/$mi_id" && chmod 700 "$SG_DATA_ROOT/settings" "$SG_DATA_ROOT/settings/$mi_id" &&
                    sg_write "${mi_set#*:}" > "$SG_DATA_ROOT/settings/$mi_id/${mi_set%%:*}" || mi_fail 'Could not move module state'
            fi
            sg_write on > "$SG_DATA_ROOT/desired/$mi_id" || mi_fail 'Could not move module state'
        fi
        rm -f "$SG_DATA_ROOT/desired/$mi_old"
        for mi_area in settings restart-cleanup peer; do
            if [ -e "$SG_DATA_ROOT/$mi_area/$mi_old" ] && [ ! -e "$SG_DATA_ROOT/$mi_area/$mi_id" ]; then
                mv "$SG_DATA_ROOT/$mi_area/$mi_old" "$SG_DATA_ROOT/$mi_area/$mi_id" || mi_fail 'Could not move module state'
            fi
        done
    done
    mi_migrating=1
}

# After the new module is published: it takes the first old one's catalog position, the old
# packages are dropped, and the ledger records each takeover under the new id.
mi_replaces_finish() {
    [ "$mi_migrating" -eq 1 ] || return 0
    : > "$SG_DATA_ROOT/installed.list.tmp.$$" || mi_fail 'Could not update module list'
    mi_placed=0
    for mi_other in $(cat "$SG_DATA_ROOT/installed.list" 2>/dev/null); do
        case " $mi_present " in *" $mi_other "*) mi_other=$mi_id;; esac
        if [ "$mi_other" = "$mi_id" ]; then
            [ "$mi_placed" -eq 0 ] || continue
            mi_placed=1
        fi
        sg_print "$mi_other" >> "$SG_DATA_ROOT/installed.list.tmp.$$" || mi_fail 'Could not update module list'
    done
    mv "$SG_DATA_ROOT/installed.list.tmp.$$" "$SG_DATA_ROOT/installed.list" || mi_fail 'Could not update module list'
    for mi_old in $mi_present; do
        rm -rf "$installed/$mi_old" "$installed/$mi_old.properties" "$installed/$mi_old.hookpoints" ||
            mi_fail "Could not remove $mi_old"
    done
    mi_graph || mi_fail 'Could not update module list'
    for mi_old in $mi_present; do
        (HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/modules/$mi_id; sg_ledger module_takeover "$mi_old" "" "" "" ok) ||
            mi_fail 'Could not record module takeover'
    done
    rm -f "$SG_DATA_ROOT/migrate/$mi_id"
    sg_log "$mi_id took over $mi_present" || :
}

# Ownership lines of a generated manifest, compared before replacing a bundled module that is on.
mi_ownership() {
    grep -E '^(owns_props|reassert_props|owns_files|owns_generated_dirs|services|service_calls|restore|hooks|owns_lines\.[0-9]+|kmods|daemons|owns_ifaces|kmod\.[^=]*|kmod_params\.[^=]*|daemon\.[^=]*|net_rules\.[0-9]+)=' "$1" 2>/dev/null
}
# Transient declarations (kernel modules, daemons, network rules, interfaces) copied verbatim.
# Derived programs and daemon users only shape private state-directory files, so they are not
# ownership (mi_ownership).
mi_transient() {
    grep -E '^(kmods|daemons|owns_ifaces|derived_bins|kmod\.[^=]*|kmod_params\.[^=]*|daemon\.[^=]*|daemon_user\.[^=]*|derived_bin\.[^=]*|net_rules\.[0-9]+)=' "$1" 2>/dev/null || :
}

# describe must fit the app's 8 KiB root output (two string files, ui.txt and
# prefixes), so text members are capped in bytes, lines and value length here.
mi_check_text() {
    for mi_text in "$1"/strings/*.txt "$1/ui.txt"; do
        [ -f "$mi_text" ] || continue
        mi_name=${mi_text#"$1"/}
        mi_cap=2048; mi_max=64
        [ "$mi_name" != ui.txt ] || { mi_cap=1024; mi_max=32; }
        mi_size=$(sg_file_size "$mi_text") || mi_fail "HSM-E208 $mi_name: unreadable"
        [ "$mi_size" -le "$mi_cap" ] || mi_fail "HSM-E208 $mi_name: larger than $mi_cap bytes"
        ! LC_ALL=C grep -q '[[:cntrl:]]' "$mi_text" || mi_fail "HSM-E103 $mi_name: control characters"
        mi_count=0
        while IFS= read -r mi_line || [ -n "$mi_line" ]; do
            case "$mi_line" in ''|'#'*) continue;; esac
            mi_count=$((mi_count + 1))
            [ "$mi_count" -le "$mi_max" ] || mi_fail "HSM-E208 $mi_name: more than $mi_max entries"
            if [ "$mi_name" = ui.txt ]; then
                [ "${#mi_line}" -le 200 ] || mi_fail "HSM-E209 $mi_name: line longer than 200 characters"
                continue
            fi
            case "$mi_line" in *=*) ;; *) mi_fail "HSM-E209 $mi_name: line without key=value";; esac
            mi_key=${mi_line%%=*}
            mi_val=${mi_line#*=}
            case "$mi_key" in ''|*[!a-z0-9_]*) mi_fail "HSM-E209 $mi_name: bad key $mi_key";; esac
            [ "${#mi_key}" -le 40 ] && [ "${#mi_val}" -le 200 ] ||
                mi_fail "HSM-E209 $mi_name: key over 40 or value over 200 characters"
        done < "$mi_text"
    done
}

mi_describe() {
    hsm_ok_id "$1" || exit 2
    case "$2" in [a-z][a-z]) ;; *) exit 2;; esac
    ! sg_module_builtin "$base" "$1" || mi_fail "$1 is a built-in module"
    mi_pkg=$installed/$1
    mi_gen=$installed/$1.properties
    [ -f "$mi_gen" ] && [ -d "$mi_pkg" ] || mi_fail "$1 is not installed"
    for mi_key in version source restart depends excludes uses; do
        sg_print "info.$mi_key=$(mi_field "$mi_key" "$mi_gen")"
    done
    if grep -Fxq restore=reboot "$mi_gen"; then sg_print info.restore=reboot; else sg_print info.restore=exact; fi
    if grep -Fxq kind=action "$mi_gen"; then sg_print info.kind=action; else sg_print info.kind=toggle; fi
    mi_icon=$(mi_field icon "$mi_pkg/module.properties")
    sg_print "info.icon=${mi_icon:-box}"
    while IFS='=' read -r mi_key mi_val; do
        case "$mi_key" in setting.[1-9]|setting.[1-9][0-9]) sg_print "info.setting_${mi_key#setting.}=$mi_val";; esac
    done < "$mi_pkg/module.properties"
    if [ -f "$mi_pkg/ui.txt" ]; then
        mi_n=0
        while IFS= read -r mi_line || [ -n "$mi_line" ]; do
            case "$mi_line" in ''|'#'*) continue;; esac
            mi_n=$((mi_n + 1))
            sg_print "info.ui_$mi_n=$mi_line"
        done < "$mi_pkg/ui.txt"
    fi
    mi_locales=en
    [ "$2" = en ] || mi_locales="en $2"
    for mi_locale in $mi_locales; do
        mi_text=$mi_pkg/strings/$mi_locale.txt
        [ -f "$mi_text" ] || continue
        while IFS= read -r mi_line || [ -n "$mi_line" ]; do
            case "$mi_line" in ''|'#'*) continue;; esac
            sg_print "info.str_$mi_line"
        done < "$mi_text"
    done
    sg_status on none "Module description"
}

mi_check_ui() {
    [ -f "$1/ui.txt" ] || return 0
    HMG_SEOGAEMO_MODULE_DIR=$1
    hsm_file=$1/ui.txt
    hsm_lineno=0
    while IFS= read -r mi_line || [ -n "$mi_line" ]; do
        hsm_lineno=$((hsm_lineno + 1))
        hsm_tokenize "$mi_line" || { hsm_error 102 "bad quoting"; exit 2; }
        set -f
        mi_old_ifs=$IFS
        IFS=$hsm_nl
        set -- $hsm_tokens
        IFS=$mi_old_ifs
        set +f
        [ "$#" -ge 1 ] || continue
        mi_block=$1
        shift
        case "$mi_block" in
            status|toggle|choice|number|info|warning|value|button|enable|open|pick_app) ;;
            '#'*) continue ;;
            *) hsm_error 110 "unknown block: $mi_block"; exit 2 ;;
        esac
        for mi_arg in "$@"; do
            case "$mi_arg" in
                setting=*) hsm_setting_decl "${mi_arg#setting=}" ;;
                label=@*|confirm=@*) hsm_ok_string "${mi_arg#*=}" ;;
                @*) hsm_ok_string "$mi_arg" ;;
                key=*|name=*|when=*) hsm_ok_name "${mi_arg#*=}" ;;
                module=*) hsm_ok_id "${mi_arg#module=}" ;;
                screen=*) case "${mi_arg#screen=}" in wifi_settings|wifi_networks) ;; *) false;; esac ;;
                danger=1) [ "$mi_block" = button ] ;;
                slot=head|slot=swrc) [ "$mi_block" = pick_app ] ;;
                *) false ;;
            esac || { hsm_error 112 "bad argument for $mi_block"; exit 2; }
        done
    done < "$1/ui.txt"
}

mi_collides() {
    sg_transient_clash "$work.d/module.properties" "$mi_id" && return 0
    mi_old_ifs=$IFS
    # A bundled module that takes over renamed ones (replaces=) owns their targets by design.
    mi_taken=
    [ "$mi_mode" != bundled ] || mi_taken=$(mi_field replaces "$work.d/module.properties")
    for mi_other in $(sg_module_list "$base"); do
        [ "$mi_other" != "$mi_id" ] || continue
        case ",$mi_taken," in *",$mi_other,"*) continue;; esac
        mi_other_props=$(sg_module_props "$base" "$mi_other")
        [ -f "$mi_other_props" ] || continue
        mi_other_files=,$(mi_field owns_files "$mi_other_props"),
        while IFS="$(sg_write '	')" read -r mi_kind mi_target; do
            case "$mi_kind" in
                file)
                    case "$mi_other_files" in *",$mi_target,"*) sg_print "$mi_other"; return 0;; esac
                    while IFS='=' read -r mi_key mi_val; do
                        case "$mi_key" in owns_lines.*) [ "$(sg_line_decl "$mi_val")" != "$mi_target:${mi_val#*:}" ] || { sg_print "$mi_other"; return 0; };; esac
                    done < "$mi_other_props" ;;
                line)
                    case "$mi_other_files" in *",${mi_target%%:*},"*) sg_print "$mi_other"; return 0;; esac
                    while IFS='=' read -r mi_key mi_val; do
                        case "$mi_key" in owns_lines.*) [ "$(sg_line_decl "$mi_val")" != "$mi_target" ] || { sg_print "$mi_other"; return 0; };; esac
                    done < "$mi_other_props" ;;
            esac
        done < "$work.touched"
    done
    IFS=$mi_old_ifs
    return 1
}

mi_generate() {
    mi_src=$work.d/module.properties
    mi_out=$work.properties
    mi_props_csv=; mi_reassert=; mi_files=; mi_services=; mi_calls=; mi_lines=0; mi_hooks=0
    while IFS="$(sg_write '	')" read -r mi_kind mi_target; do
        case "$mi_kind" in
            prop) mi_props_csv=$mi_props_csv${mi_props_csv:+,}$mi_target ;;
            reassert) mi_reassert=$mi_reassert${mi_reassert:+,}$mi_target ;;
            file) mi_files=$mi_files${mi_files:+,}$mi_target ;;
            service) mi_services=$mi_services${mi_services:+,}$mi_target ;;
            call) mi_calls=$mi_calls${mi_calls:+,}$mi_target ;;
            line) mi_lines=$((mi_lines + 1)) ;;
            hook) mi_hooks=1 ;;
        esac
    done < "$work.touched"
    mi_action=0
    [ "$(mi_field kind "$mi_src")" != action ] || mi_action=1
    if [ "$mi_action" -eq 1 ]; then
        if [ -n "$mi_props_csv$mi_reassert$mi_files$mi_services" ] || [ "$mi_lines" -ne 0 ] || [ "$mi_hooks" -ne 0 ]; then
            mi_fail 'HSM-E213 apply.sh: kind=action may only use call_service'
        fi
    fi
    mi_restart=$(mi_field restart "$mi_src")
    mi_excludes=$(mi_field not_with "$mi_src")
    # App hooks load at zygote start through the shared core hook host.
    [ "$mi_hooks" -eq 0 ] || mi_restart=head_unit
    {
        sg_print "id=$mi_id" "version=$(mi_field version "$mi_src")" api=1 "source=$mi_mode" \
            "cars=$(mi_field cars "$mi_src")" "restart=$mi_restart" \
            "depends=$(mi_field depends "$mi_src")" "excludes=$mi_excludes" \
            "conflicts=$(mi_field conflicts "$mi_src")" "uses=$(mi_field uses "$mi_src")" \
            "watch=$(mi_field rerun_on "$mi_src")" "owns_props=$mi_props_csv" \
            "reassert_props=$mi_reassert" "owns_files=$mi_files" "services=$mi_services" \
            "service_calls=$mi_calls"
        [ "$mi_hooks" -eq 0 ] || sg_print hooks=1
        [ "$mi_action" -eq 0 ] || sg_print kind=action
        [ -z "$mi_bundle_md5" ] || sg_print "bundle_sha256=$mi_bundle_md5"
        mi_transient "$mi_src"
        if [ "$mi_rawshell" -eq 1 ]; then
            sg_print raw_shell=1
            mi_v=$(mi_field owns_generated_dirs "$mi_src"); [ -z "$mi_v" ] || sg_print "owns_generated_dirs=$mi_v"
            mi_v=$(mi_field restore "$mi_src"); [ -z "$mi_v" ] || sg_print "restore=$mi_v"
        elif [ "$mi_action" -eq 0 ] && [ -n "$mi_calls" ] && [ -z "$mi_props_csv$mi_files$mi_services" ] && [ "$mi_lines" -eq 0 ]; then
            sg_print restore=reboot
        fi
        mi_n=0
        while IFS="$(sg_write '	')" read -r mi_kind mi_target; do
            [ "$mi_kind" = line ] || continue
            mi_n=$((mi_n + 1))
            sg_print "owns_lines.$mi_n=$mi_target"
        done < "$work.touched"
        mi_n=0
        while IFS='=' read -r mi_key mi_val; do
            case "$mi_key" in stock_file.*) ;; *) continue;; esac
            case "$mi_val" in
                /*) ;;
                *) mi_n=$((mi_n + 1)); sg_print "known_stock.$mi_n=$mi_val"; continue ;;
            esac
            while IFS= read -r mi_glob; do
                mi_n=$((mi_n + 1))
                sg_print "known_stock.$mi_n=$mi_glob:$mi_val"
            done <<EOF
$(sg_csv_items "$(mi_field cars "$mi_src")")
EOF
        done < "$mi_src"
    } > "$mi_out"
}

mi_graph() {
    : > "$SG_DATA_ROOT/installed.graph.tmp.$$" || return 1
    for mi_gid in $(cat "$SG_DATA_ROOT/installed.list" 2>/dev/null); do
        mi_gprops=$installed/$mi_gid.properties
        sg_print "$mi_gid	depends=$(mi_field depends "$mi_gprops")	excludes=$(mi_field excludes "$mi_gprops")" \
            >> "$SG_DATA_ROOT/installed.graph.tmp.$$" || return 1
    done
    mv "$SG_DATA_ROOT/installed.graph.tmp.$$" "$SG_DATA_ROOT/installed.graph"
}

mi_extract() {
    mi_vm=$SG_DATA_ROOT/core/vm
    sg_vm_prepare "$mi_vm" || mi_fail 'Package helper unavailable'
    if mi_boot=$(sg_bootclasspath); then BOOTCLASSPATH=$mi_boot; export BOOTCLASSPATH; fi
    ANDROID_DATA="$mi_vm" CLASSPATH="$base/core/hsm/hmg-seogaemo-hsm.jar" app_process /system/bin com.seogaemo.hmg.core.hsm.HmgSeogaemoHsmExtract \
        extract "$work.hsm" "$work.d" "$1" > "$work.extract" 2>&1 &
    mi_pid=$!
    sg_bounded_wait "$mi_pid" 60 && mi_code=0 || mi_code=$?
    mi_pid=
    mi_result=$(dd if="$work.extract" bs=1 count=200 2>/dev/null)
    rm -f "$work.extract"
    [ "$mi_code" -ne 124 ] || mi_fail 'Package check timed out'
    [ "$mi_code" -eq 0 ] || mi_fail "Package rejected: $(sg_clean "${mi_result#error }")"
}

mi_install() {
    case "$1" in ????????????????????????????????????????????????????????????????) ;; *) exit 2;; esac
    case "$1" in *[!0-9a-f]*) exit 2;; esac
    mi_source=
    for mi_inbox in ${SG_HSM_INBOX:-/data/data/com.seogaemo.hmg/files/hsm /data/local/tmp/hsm}; do
        if [ -f "$mi_inbox/$1.hsm" ] && [ ! -L "$mi_inbox/$1.hsm" ]; then mi_source=$mi_inbox/$1.hsm; break; fi
    done
    [ -n "$mi_source" ] || mi_fail 'Package not found'
    mi_bundle_md5=
    mi_install_file "$mi_source" "$1"
}

# Installs one package file; mi_mode is direct (inbox) or bundled (this package's bundled/).
mi_install_file() {
    [ ! -f "$SG_DATA_ROOT/uninstall/pending" ] || mi_conflict 'Uninstall pending'
    mkdir -p "$SG_DATA_ROOT/staging" "$installed" && chmod 700 "$SG_DATA_ROOT/staging" "$installed" ||
        mi_fail 'Could not prepare staging'
    work=$SG_DATA_ROOT/staging/$2.$$
    cp "$1" "$work.hsm" || mi_fail 'Could not copy package'
    mi_extract "$2"
    mi_id=$(mi_field id "$work.d/module.properties")
    hsm_ok_id "$mi_id" || mi_fail 'HSM-E204 module.properties: bad value for id'
    ! sg_module_builtin "$base" "$mi_id" || mi_conflict "$mi_id is a built-in module"
    if [ "$mi_mode" = direct ] && [ -f "$bundled/$mi_id.hsm" ]; then mi_conflict "$mi_id is bundled with HMG-Seogaemo"; fi
    HSM_MODULE_ID=$mi_id
    mi_check_props "$work.d"
    mi_check_text "$work.d"
    HMG_SEOGAEMO_MODULE_DIR=$work.d
    mi_rawshell=0
    if mi_raw "$work.d"; then
        mi_rawshell=1
        [ -f "$work.d/module.sh" ] || mi_fail 'HSM-E210 module.sh: missing'
        for mi_kind in check status; do
            [ ! -f "$work.d/$mi_kind.sh" ] || hsm_walk "$work.d/$mi_kind.sh" "$mi_kind" validate || exit 2
        done
        mi_check_ui "$work.d"
        mi_declared_touched "$work.d" > "$work.touched"
    else
        [ ! -f "$work.d/module.sh" ] || mi_fail 'HSM-E210 module.sh: needs raw_shell'
        hsm_walk "$work.d/apply.sh" apply validate || exit 2
        for mi_kind in check status; do
            [ ! -f "$work.d/$mi_kind.sh" ] || hsm_walk "$work.d/$mi_kind.sh" "$mi_kind" validate || exit 2
        done
        mi_check_ui "$work.d"
        hsm_walk "$work.d/apply.sh" apply touched > "$work.touched" || exit 2
    fi
    if mi_other=$(mi_collides); then mi_conflict "Changes the same file or line as $mi_other"; fi
    mi_generate
    mi_replaces_prepare
    if [ -d "$installed/$mi_id" ]; then
        if [ "$(cat "$SG_DATA_ROOT/desired/$mi_id" 2>/dev/null)" = on ] ||
            (HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/modules/$mi_id; sg_restore_material); then
            # A bundled module may be replaced while on only when it touches exactly the same targets.
            [ "$mi_mode" = bundled ] && [ "$(mi_ownership "$installed/$mi_id.properties")" = "$(mi_ownership "$work.properties")" ] ||
                mi_conflict "Turn $mi_id off before updating it"
        fi
    fi
    rm -rf "$installed/$mi_id.new" "$installed/$mi_id.old"
    mv "$work.d" "$installed/$mi_id.new" || mi_fail 'Could not publish module'
    if [ -d "$installed/$mi_id" ]; then mv "$installed/$mi_id" "$installed/$mi_id.old" || mi_fail 'Could not publish module'; fi
    mv "$installed/$mi_id.new" "$installed/$mi_id" &&
        mv "$work.properties" "$installed/$mi_id.properties" || mi_fail 'Could not publish module'
    rm -rf "$installed/$mi_id.old" "$installed/$mi_id.hookpoints"
    mi_hooks=$(mi_field hookpoints "$installed/$mi_id/module.properties")
    if [ -n "$mi_hooks" ]; then
        cp "$installed/$mi_id/$mi_hooks" "$installed/$mi_id.hookpoints" || mi_fail 'Could not publish module'
    fi
    grep -Fxq "$mi_id" "$SG_DATA_ROOT/installed.list" 2>/dev/null ||
        sg_print "$mi_id" >> "$SG_DATA_ROOT/installed.list" || mi_fail 'Could not record module'
    mi_graph || mi_fail 'Could not record module'
    mi_replaces_finish
    sg_ledger module_install "$mi_id" "" "" "" ok || :
    sg_status on none "Installed $mi_id $(mi_field version "$installed/$mi_id.properties")"
}

# Installs or updates one package of bundled/ (the caller checked that the owner has not removed it).
# Each runs in its own subshell so one bad package never stops the others.
mi_bundled_one() {
    mi_bid=$1
    # The build writes each package's SHA-256 beside it; the extractor verifies the archive against it.
    mi_sum=$(cat "$bundled/$mi_bid.sha256" 2>/dev/null)
    case "$mi_sum" in ????????????????????????????????????????????????????????????????) ;; *) return 0;; esac
    case "$mi_sum" in *[!0-9a-f]*) return 0;; esac
    if [ -f "$installed/$mi_bid.properties" ] && [ "$(mi_field bundle_sha256 "$installed/$mi_bid.properties")" = "$mi_sum" ] &&
            [ ! -f "$SG_DATA_ROOT/migrate/$mi_bid" ]; then
        return 0
    fi
    mi_any=1
    mi_out=$(lock_owned=0; work=; trap cleanup EXIT; mi_mode=bundled; mi_bundle_md5=$mi_sum
        mi_install_file "$bundled/$mi_bid.hsm" "$mi_sum" 2>&1)
    sg_print "bundled $mi_bid: $(sg_clean "$mi_out")"
}

# Installs or updates every package in bundled/ that the owner has not removed.
mi_install_bundled() {
    mi_any=0
    for mi_file in "$bundled"/*.hsm; do
        [ -f "$mi_file" ] && [ ! -L "$mi_file" ] || continue
        mi_bid=${mi_file##*/}
        mi_bid=${mi_bid%.hsm}
        hsm_ok_id "$mi_bid" || continue
        [ ! -f "$SG_DATA_ROOT/bundled-removed/$mi_bid" ] || continue
        mi_bundled_one "$mi_bid"
    done
    [ "$mi_any" -eq 0 ] || sg_log 'bundled modules checked'
    sg_status on none 'Bundled modules checked'
}

# Read-only: bundled packages the owner removed, for the app's Add screen. info.removed_N=<id>,<version>,<icon>
# and info.removed_N_name / _summary from the package's strings (en, then the requested locale).
mi_list_removed() {
    case "$1" in [a-z][a-z]) ;; *) exit 2;; esac
    mi_n=0
    for mi_file in "$bundled"/*.hsm; do
        [ -f "$mi_file" ] && [ ! -L "$mi_file" ] || continue
        mi_bid=${mi_file##*/}
        mi_bid=${mi_bid%.hsm}
        hsm_ok_id "$mi_bid" || continue
        [ -f "$SG_DATA_ROOT/bundled-removed/$mi_bid" ] && [ ! -f "$installed/$mi_bid.properties" ] || continue
        mi_n=$((mi_n + 1))
        mi_props=$base/modules/$mi_bid.properties
        mi_icon=$(mi_field icon "$mi_props")
        sg_print "info.removed_$mi_n=$mi_bid,$(mi_field version "$mi_props"),${mi_icon:-box}"
        mi_locales=en
        [ "$1" = en ] || mi_locales="en $1"
        for mi_locale in $mi_locales; do
            mi_text=$bundled/$mi_bid.strings.$mi_locale
            [ -f "$mi_text" ] || continue
            while IFS='=' read -r mi_key mi_val; do
                case "$mi_key" in name|summary) sg_print "info.removed_${mi_n}_$mi_key=$mi_val";; esac
            done < "$mi_text"
        done
    done
    sg_status on none 'Removed built-in modules'
}

# The owner adds a removed bundled module back: drop the marker and install just that package. On failure
# the marker returns, so nothing changes.
mi_add_bundled() {
    hsm_ok_id "$1" || exit 2
    [ -f "$bundled/$1.hsm" ] && [ ! -L "$bundled/$1.hsm" ] || mi_fail "$1 is not a bundled module"
    [ -f "$SG_DATA_ROOT/bundled-removed/$1" ] || mi_fail "$1 was not removed"
    [ ! -f "$installed/$1.properties" ] || mi_fail "$1 is already installed"
    rm -f "$SG_DATA_ROOT/bundled-removed/$1" || mi_fail 'Could not update module list'
    mi_any=0
    mi_explicit=1
    mi_bundled_one "$1"
    if [ ! -f "$installed/$1.properties" ]; then
        mkdir -p "$SG_DATA_ROOT/bundled-removed" && : > "$SG_DATA_ROOT/bundled-removed/$1" || :
        mi_fail "Could not add $1"
    fi
    sg_status on none "Added $1"
}

mi_remove() {
    hsm_ok_id "$1" || exit 2
    mi_id=$1
    ! sg_module_builtin "$base" "$mi_id" || mi_conflict "$mi_id is a built-in module"
    [ -f "$installed/$mi_id.properties" ] || mi_fail "$mi_id is not installed"
    for mi_other in $(cat "$SG_DATA_ROOT/installed.list" 2>/dev/null); do
        [ "$mi_other" != "$mi_id" ] || continue
        case ",$(mi_field depends "$installed/$mi_other.properties")," in
            *",$mi_id,"*) mi_conflict "$mi_other depends on $mi_id" ;;
        esac
    done
    mi_state=$SG_DATA_ROOT/modules/$mi_id
    if [ "$(cat "$SG_DATA_ROOT/desired/$mi_id" 2>/dev/null)" = on ] ||
        (HMG_SEOGAEMO_STATE=$mi_state; sg_restore_material); then
        mi_out=$(HMG_SEOGAEMO_STATE=$mi_state HMG_SEOGAEMO_MODULE_DIR=$installed/$mi_id \
            /system/bin/sh "$base/core/hsm-module.sh" revert 2>&1)
        mi_code=$?
        case "$mi_out" in *state=off*|*state=pending-restart*) ;; *) mi_code=1;; esac
        if [ "$mi_code" -ne 0 ]; then
            sg_print "$mi_out"
            exit "$mi_code"
        fi
    fi
    (HMG_SEOGAEMO_STATE=$mi_state; ! sg_restore_material) || mi_conflict "$mi_id still has changes to restore"
    : > "$SG_DATA_ROOT/installed.list.tmp.$$" || mi_fail 'Could not update module list'
    for mi_other in $(cat "$SG_DATA_ROOT/installed.list" 2>/dev/null); do
        [ "$mi_other" = "$mi_id" ] || sg_print "$mi_other" >> "$SG_DATA_ROOT/installed.list.tmp.$$"
    done
    mv "$SG_DATA_ROOT/installed.list.tmp.$$" "$SG_DATA_ROOT/installed.list" || mi_fail 'Could not update module list'
    mi_graph || mi_fail 'Could not update module list'
    rm -rf "$installed/$mi_id" "$installed/$mi_id.properties" "$installed/$mi_id.hookpoints" "$SG_DATA_ROOT/settings/$mi_id" \
        "$SG_DATA_ROOT/desired/$mi_id" "$mi_state"
    if [ "$(mi_field source "$installed/$mi_id.properties" 2>/dev/null)" = bundled ] || [ -f "$bundled/$mi_id.hsm" ]; then
        mkdir -p "$SG_DATA_ROOT/bundled-removed" && : > "$SG_DATA_ROOT/bundled-removed/$mi_id" || :
    fi
    sg_ledger module_remove "$mi_id" "" "" "" ok || :
    case "$mi_out" in *state=pending-restart*)
        sg_print info.desired=off
        sg_status pending-restart head_unit "Removed $mi_id; restart the head unit to finish"; exit $? ;;
    esac
    sg_status off none "Removed $mi_id"
}

case "$1" in
    list) mi_list ;;
    usb-import) mi_usb_import ;;
    describe) mi_describe "$2" "$3" ;;
    install) mi_lock; mi_install "$2" ;;
    install-bundled) mi_lock; mi_install_bundled ;;
    list-removed) mi_list_removed "$2" ;;
    add-bundled) mi_lock; mi_add_bundled "$2" ;;
    remove) mi_lock; mi_remove "$2" ;;
esac
