#!/system/bin/sh
# Fixed car-map commands. The mapper runs in a separate root app_process.
umask 077
[ "$#" -eq 1 ] || exit 2
case "$1" in status|run|verify|export) ;; *) exit 2;; esac
base=${0%/*}
base=${base%/core}
SG_DATA_ROOT=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}
HMG_SEOGAEMO_BASE=$base
HMG_SEOGAEMO_STATE=$SG_DATA_ROOT/core/map
export SG_DATA_ROOT HMG_SEOGAEMO_BASE HMG_SEOGAEMO_STATE
. "$base/lib/common.sh"
map_pid=
map_scratch=
lock_owned=0
cleanup() {
    if [ -n "$map_pid" ]; then
        sg_kill_tree "$map_pid"
        wait "$map_pid" 2>/dev/null || :
    fi
    if [ -n "$map_scratch" ]; then rm -rf "$map_scratch"; rmdir "$SG_DATA_ROOT/core" 2>/dev/null || :; fi
    [ -n "${HMG_SEOGAEMO_MAP_WORK:-}" ] && hmg_seogaemo_map_work_cleanup
    [ "$lock_owned" -eq 0 ] || rm -rf "$lock"
    return 0
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mapper() {
    # Private Dalvik cache: never leave entries for our jar in /data/dalvik-cache.
    # `status` is read-only: it reuses an existing cache, else it runs on a scratch
    # cache that is removed on exit. Only verify and run create core/vm.
    map_vm=$SG_DATA_ROOT/core/vm
    if [ "$1" = status ] && [ ! -e "$map_vm" ]; then
        map_vm=$SG_DATA_ROOT/core/vm.status.$$
        map_scratch=$map_vm
    fi
    sg_vm_prepare "$map_vm" || { sg_print state=failed restart=none 'detail=map VM cache unavailable'; return 1; }
    if map_boot=$(sg_bootclasspath); then BOOTCLASSPATH=$map_boot; export BOOTCLASSPATH; fi
    ANDROID_DATA="$map_vm" CLASSPATH="$base/core/map/hmg-seogaemo-mapper.jar" app_process /system/bin com.seogaemo.hmg.core.map.HmgSeogaemoMapTool \
        "$1" "$base" "$SG_DATA_ROOT" "$2" &
    # This is the app_process PID, not a background shell function.
    map_pid=$!
    # A full scan stays inside the app's 600-second root-call window.
    case "$1" in status) limit=15;; verify) limit=30;; *) limit=590;; esac
    sg_bounded_wait "$map_pid" "$limit" && mapper_code=0 || mapper_code=$?
    map_pid=
    if [ "$mapper_code" -eq 124 ]; then
        sg_print state=failed restart=none 'detail=map command timeout'
        return 1
    fi
    return "$mapper_code"
}
if [ "$1" = status ]; then
    mapper status "$SG_DATA_ROOT/car-maps/.unused"
    exit $?
fi
lock=$SG_DATA_ROOT/operation.lock
mkdir -p "$SG_DATA_ROOT" || exit 1
tries=0
while ! mkdir "$lock" 2>/dev/null; do
    if [ -f "$lock/pid" ]; then
        holder=$(cat "$lock/pid" 2>/dev/null)
        case "$holder" in ''|*[!0-9]*) ;; *)
            if ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi;;
        esac
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || { sg_print "state=failed" "restart=none" "detail=operation busy"; exit 1; }
    sleep 1
done
lock_owned=1
sg_write "$$" > "$lock/pid"
if [ "$1" = export ]; then
    target=
    export_mode=adb
    for drive in ${SG_USB_DIRS:-/storage/usb0 /storage/usb1 /storage/usb2 /mnt/media_rw/usb0 /mnt/media_rw/usb1 /mnt/media_rw/usb2}; do
        grep -q " $drive " "${SG_MOUNTS_FILE:-/proc/mounts}" 2>/dev/null || continue
        target=$drive/HMG-Seogaemo-export/$(date +%Y%m%d-%H%M%S)
        export_mode=usb
        break
    done
    [ -n "$target" ] || target=${SG_EXPORT_ROOT:-/data/local/tmp/hmg-seogaemo-export}/$(date +%Y%m%d-%H%M%S)
    sg_path_safe "$target" || exit 1
    hmg_seogaemo_map_export "$target" || { sg_print "state=failed" "restart=none" "detail=no verified map"; exit 1; }
    sg_export_public "$target" && chmod 0755 "${target%/*}" || exit 1
    # hmg_seogaemo_map_export left the validated layout and active map directory set.
    set -- "$hmg_seogaemo_map_layout/map.json=$hmg_seogaemo_map_from/map.json" \
        "$hmg_seogaemo_map_layout/car.json=$hmg_seogaemo_map_from/car.json"
    [ -z "$hmg_seogaemo_map_incomplete" ] ||
        set -- "$@" "$hmg_seogaemo_map_layout/incomplete.txt=$hmg_seogaemo_map_from/incomplete"
    sg_export_seal "$target" "$export_mode" "$@"
    case $? in
        0) ;;
        4) sg_print "state=failed" "restart=none" "detail=USB write not flushed"; exit 1 ;;
        *) exit 1 ;;
    esac
    if [ -n "$hmg_seogaemo_map_incomplete" ]; then
        sg_print "state=on" "restart=none" "info.export_safe=$export_mode" "info.export_kind=incomplete" "detail=$target"
    else
        sg_print "state=on" "restart=none" "info.export_safe=$export_mode" "detail=$target"
    fi
    exit 0
fi
hmg_seogaemo_map_work || { sg_print "state=failed" "restart=none" "detail=map work unavailable"; exit 1; }
mapper "$1" "$HMG_SEOGAEMO_MAP_WORK" > "$HMG_SEOGAEMO_MAP_WORK/result" 2>&1
code=$?
if [ "$code" -ne 0 ]; then
    dd if="$HMG_SEOGAEMO_MAP_WORK/result" bs=1 count=4096 2>/dev/null
    hmg_seogaemo_map_keep_incomplete "$HMG_SEOGAEMO_MAP_WORK" 2>/dev/null || :
    exit "$code"
fi
if ! hmg_seogaemo_map_publish "$HMG_SEOGAEMO_MAP_WORK"; then
    sg_print "state=failed" "restart=none" "detail=map publish failed"
    exit 1
fi
dd if="$HMG_SEOGAEMO_MAP_WORK/result" bs=1 count=4096 2>/dev/null
