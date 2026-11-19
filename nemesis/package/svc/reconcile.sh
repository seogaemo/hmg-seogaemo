#!/system/bin/sh
umask 077
base=${0%/*}
base=${base%/svc}
# Pin this process to its payload even if update/current changes during a retry.
base=$(readlink -f "$base") || exit 1
journal=/data/nemesis/backup/hmg-seogaemo/update/journal
if [ "${HMG_SEOGAEMO_UPDATE_HEALTH:-}" != 1 ] && [ -f "$journal" ]; then
    IFS= read -r phase < "$journal" || :
    case "$phase" in phase=applying|phase=auto-rollback|phase=rollback)
        /system/bin/sh "$base/core/update.sh" rollback || exit 1 ;;
    esac
fi
# The installed entry owns USB APK recovery, including when a failed repair
# retained an older OTA selection that predates pending-install support.
state=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}
# The pending request was explicitly published by a USB install, so it is
# completed even when a failed stock restore paused automatic module calls
# (install-pending.sh still refuses while an uninstall is queued).
if [ -f "$state/app-install/pending" ]; then
    /system/bin/sh "$base/svc/install-pending.sh" >> "$state/reconcile.log" 2>&1 || :
    if [ -f "$state/app-install/pending" ]; then
        # An unsuccessful update of an existing APK must still reapply modules.
        # Only a never-completed first install suppresses missing-APK cleanup.
        case "$(pm path com.seogaemo.hmg 2>/dev/null)" in package:*) ;; *) exit 1;; esac
    fi
fi
# Generated app directories that a restore could not remove while the hooks were
# still running are retried here after the restart. This only deletes our own
# diagnostic files, so it also runs while automatic module calls are paused.
restart_cleanup() {
    [ -d "$state/restart-cleanup" ] || return 0
    cleanup_lock=$state/operation.lock
    cleanup_tries=0
    while ! mkdir "$cleanup_lock" 2>/dev/null; do
        cleanup_holder=$(cat "$cleanup_lock/pid" 2>/dev/null)
        case "$cleanup_holder" in ''|*[!0-9]*) ;; *)
            if ! kill -0 "$cleanup_holder" 2>/dev/null; then rm -rf "$cleanup_lock"; continue; fi ;;
        esac
        cleanup_tries=$((cleanup_tries + 1))
        [ "$cleanup_tries" -lt 10 ] || return 0
        sleep 1
    done
    echo "$$" > "$cleanup_lock/pid"
    (
        SG_DATA_ROOT=$state
        HMG_SEOGAEMO_BASE=$base
        export SG_DATA_ROOT HMG_SEOGAEMO_BASE
        . "$base/lib/common.sh"
        sg_restart_cleanup_run
    ) >> "$state/reconcile.log" 2>&1 || :
    rm -rf "$cleanup_lock"
}
restart_cleanup
[ ! -f "$state/stock/paused" ] || exit 0
current=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}/update/current
delegate_current() {
    if [ -L "$current" ] && [ -f "$current/svc/reconcile.sh" ] && [ -r "$current/svc/reconcile.sh" ] &&
            [ "$(readlink -f "$base")" != "$(readlink -f "$current")" ]; then
        exec /system/bin/sh "$current/svc/reconcile.sh" "$@"
    fi
}
delegate_current "$@"
selected_current=
[ ! -L "$current" ] || selected_current=$(readlink -f "$current")
retry_worker=0
check_current() {
    [ "$retry_worker" -eq 1 ] || delegate_current "$@"
    if [ "$retry_worker" -eq 1 ]; then
        [ "$(cat "$retry_dir/pid" 2>/dev/null)" = "$retry_claim" ] || exit 0
    fi
    retry_current=
    [ ! -L "$current" ] || retry_current=$(readlink -f "$current")
    [ "$selected_current" = "$retry_current" ] || exit "$failed"
}
state=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}
root=$base/bin/hmg-seogaemo-root
log=$state/reconcile.log
mkdir -p "$state" || exit 1
# A failed stock restore retains desired on for the failed module, but must
# never automatically reapply it on the next boot.
[ ! -f "$state/stock/paused" ] || exit 0
failed=0
ready_wait=2
ready_attempt=0
while :; do
    [ ! -f "$state/stock/paused" ] || exit 0
    check_current "$@"
    if [ "$(getprop sys.boot_completed)" = 1 ]; then
        case "$(pm path android 2>/dev/null)" in package:*) break;; esac
    fi
    ready_attempt=$((ready_attempt + 1))
    if [ "${HMG_SEOGAEMO_UPDATE_HEALTH:-}" = 1 ] && [ "$ready_attempt" -gt 6 ]; then
        echo 'Android not ready for OTA health' >> "$log"
        exit 1
    fi
    sleep "$ready_wait"
    [ "$ready_wait" -ge 30 ] || ready_wait=$((ready_wait * 2))
    [ "$ready_wait" -le 30 ] || ready_wait=30
done
# Modules bundled with this package are installed (or updated in place) before anything is applied.
[ ! -f "$base/core/module.sh" ] ||
    SG_DATA_ROOT=$state /system/bin/sh "$base/core/module.sh" install-bundled >> "$log" 2>&1 < /dev/null || :
reverse=
for id in $(cat "$base/modules.list" "$state/installed.list" 2>/dev/null); do
    [ "$id" = package-compat ] || reverse="$id $reverse"   # compatibility entry, not a module
done
failed=0
missing_apk=0
case "$(pm path com.seogaemo.hmg 2>/dev/null)" in package:*) ;; *) missing_apk=1; echo 'APK missing: reverting modules' >> "$log";; esac
for id in $reverse; do
    [ ! -f "$state/stock/paused" ] || exit "$failed"
    desired=$(cat "$state/desired/$id" 2>/dev/null)
    [ "$desired" = on ] && [ "$missing_apk" -eq 0 ] && continue
    baseline=0
    for item in "$state/modules/$id"/prop.*/ready "$state/modules/$id"/file.*/ready \
        "$state/modules/$id"/line.*/ready "$state/modules/$id"/bind.* \
        "$state/modules/$id"/changes "$state/modules/$id"/dex.cache \
        "$state/modules/$id"/dir.* "$state/modules/$id"/dir-order "$state/modules/$id"/part.*/ready; do
        [ -f "$item" ] && baseline=1
    done
    [ "$baseline" -eq 1 ] || continue
    if HMG_SEOGAEMO_RECONCILE=1 /system/bin/sh "$root" "$id" revert >> "$log" 2>&1; then
        echo "reverted $id" >> "$log"
    else echo "revert failed: $id" >> "$log"; failed=1; fi
done
map_ready() {
    map_result=$(/system/bin/sh "$root" map status 2>/dev/null) &&
        echo "$map_result" | grep -Fxq state=on && return 0
    [ ! -f "$state/stock/paused" ] || return 1
    map_result=$(/system/bin/sh "$root" map verify 2>/dev/null) &&
        echo "$map_result" | grep -Fxq state=on
}
dependency_deferred() {
    [ -f "$base/modules.graph" ] || return 1
    for graph_file in "$base/modules.graph" "$state/installed.graph"; do
        [ -f "$graph_file" ] || continue
        while read -r graph_id graph_dep graph_excludes; do
            [ "$graph_id" = "$id" ] || continue
            deps=${graph_dep#depends=}
            old_ifs=$IFS; IFS=,
            for dep in $deps; do
                case " $deferred " in *" $dep "*) IFS=$old_ifs; return 0;; esac
            done
            IFS=$old_ifs
        done < "$graph_file"
    done
    return 1
}
apply_pending() {
    deferred=
    map_checked=0
    map_ok=0
    for id in $pending; do
        [ ! -f "$state/stock/paused" ] || exit "$failed"
        check_current "$@"
        [ "$missing_apk" -eq 0 ] || continue
        [ "$(cat "$state/desired/$id" 2>/dev/null)" = on ] || continue
        if dependency_deferred; then
            deferred="$deferred $id"
            echo "deferred $id: dependency awaits verified map" >> "$log"
            continue
        fi
        if [ -s "$base/hookpoints.required/$id" ] || [ -s "$state/installed/$id.hookpoints" ]; then
            if [ "$map_checked" -eq 0 ]; then
                map_checked=1
                map_ready && map_ok=1
            fi
            # Verification may take time: re-read intent before any apply.
            [ ! -f "$state/stock/paused" ] || exit "$failed"
            check_current "$@"
            case "$(pm path com.seogaemo.hmg 2>/dev/null)" in package:*) ;; *) exit "$failed";; esac
            [ "$(cat "$state/desired/$id" 2>/dev/null)" = on ] || continue
            if [ "$map_ok" -eq 0 ]; then
                deferred="$deferred $id"
                echo "deferred $id: verified map unavailable" >> "$log"
                continue
            fi
        fi
        if HMG_SEOGAEMO_RECONCILE=1 /system/bin/sh "$root" "$id" apply >> "$log" 2>&1; then
            echo "applied $id" >> "$log"
        else echo "apply failed: $id" >> "$log"; failed=1; fi
    done
}
retry_cleanup() {
    [ -n "$retry_claim" ] || return 0
    [ "$(cat "$retry_dir/pid" 2>/dev/null)" != "$retry_claim" ] || rm -rf "$retry_dir"
}
retry_deferred() {
    retry_worker=1
    unset HMG_SEOGAEMO_UPDATE_HEALTH
    retry_claim=
    trap retry_cleanup EXIT
    trap 'exit 0' INT TERM
    cd / || exit 1
    # The parent publishes $!; $$ here still identifies the original shell.
    # Wait for that publication before taking responsibility for cleanup.
    ready=0
    while [ "$ready" -lt 5 ]; do
        { read -r retry_pid retry_owner < "$retry_dir/pid"; } 2>/dev/null || :
        if [ "$retry_owner" = "$$" ] && [ "$retry_pid" != "$$" ]; then
            retry_claim="$retry_pid $retry_owner"
            break
        fi
        ready=$((ready + 1))
        sleep 1
    done
    [ -n "$retry_claim" ] || exit 0
    # Each pass costs two JVMs: back off and give up after a bounded number of
    # tries per boot (the next boot, or any module action, starts fresh).
    retry_tries=0
    while [ -n "$deferred" ]; do
        case "$retry_tries" in
            0) retry_wait=30;; 1) retry_wait=60;; 2) retry_wait=120;; *) retry_wait=300;;
        esac
        if [ "$retry_tries" -ge "8" ]; then
            echo "deferred map retries exhausted after $retry_tries attempts:$deferred" >> "$log"
            exit 0
        fi
        retry_tries=$((retry_tries + 1))
        sleep "$retry_wait"
        [ ! -f "$state/stock/paused" ] || exit 0
        case "$(pm path com.seogaemo.hmg 2>/dev/null)" in package:*) ;; *) exit 0;; esac
        # New payload services own their retries. Never delegate from an old
        # continuation or carry its deferred IDs into the newly selected code.
        check_current
        pending=$deferred
        apply_pending
    done
}
start_retry() {
    retry_dir=$state/reconcile-retry
    if ! mkdir "$retry_dir" 2>/dev/null; then
        # Allow a concurrent launcher to publish its reservation. An interrupted
        # mkdir before publication must not suppress retries for the whole boot.
        ready=0
        while [ ! -s "$retry_dir/pid" ] && [ "$ready" -lt 5 ]; do
            ready=$((ready + 1))
            sleep 1
        done
        retry_pid=
        { read -r retry_pid retry_owner < "$retry_dir/pid"; } 2>/dev/null || :
        case "$retry_pid" in ''|*[!0-9]*) ;; *)
            if kill -0 "$retry_pid" 2>/dev/null; then
                [ "$(cat "$retry_dir/base" 2>/dev/null)" != "$base" ] || return 0
                # A selected new payload may continue before the old worker wakes.
                # Its owner token prevents the old worker deleting this claim.
            fi;;
        esac
        rm -rf "$retry_dir"
        mkdir "$retry_dir" 2>/dev/null || return 0
    fi
    echo "$base" > "$retry_dir/base"
    echo "$$ $$" > "$retry_dir/pid"
    trap '' HUP
    # Redirect inside the subshell with exec: mksh otherwise retains saved
    # copies of the caller's descriptors for the lifetime of the continuation.
    (exec </dev/null >> "$log" 2>&1; retry_deferred) &
    retry_pid=$!
    echo "$retry_pid $$" > "$retry_dir/ready"
    mv "$retry_dir/ready" "$retry_dir/pid"
}
# Read-only scan for other packages that overlap ours; the app shows it on the Car tab.
[ ! -f "$base/core/foreign.sh" ] || /system/bin/sh "$base/core/foreign.sh" status > /dev/null 2>&1 < /dev/null || :
pending=$(cat "$base/modules.list" "$state/installed.list" 2>/dev/null | grep -Fvx package-compat)
apply_pending
# NEMESIS starts this background service at boot and install/update.
# OTA health also returns after this bounded pass; a deferred module still needs
# a continuation if the previous payload had no worker during this boot.
if [ -n "$deferred" ]; then
    check_current "$@"
    start_retry
fi
exit "$failed"
