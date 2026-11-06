#!/system/bin/sh
# Fixed relative runtime directories; CarPlay may publish runtime/<module>/ logs.
HMG_SEOGAEMO_DIAGNOSTIC_RUNTIME_DIRS=runtime

# Best effort (toolbox has no pkill): print up to three levels of descendants of
# $1 by scanning /proc. Used to stop a probe's grandchildren, not only its shell.
hmg_seogaemo_diag_descendants() {
    diag_frontier=$1; diag_found=; diag_level=0
    while [ "$diag_level" -lt 3 ] && [ -n "$diag_frontier" ]; do
        diag_next=
        for diag_stat in /proc/[0-9]*/stat; do
            diag_line=
            { read -r diag_line < "$diag_stat"; } 2>/dev/null || continue
            set -- ${diag_line#*) }
            for diag_parent in $diag_frontier; do
                [ "$2" = "$diag_parent" ] || continue
                diag_child=${diag_stat#/proc/}
                diag_next="$diag_next ${diag_child%/stat}"
            done
        done
        diag_found="$diag_found$diag_next"; diag_frontier=$diag_next; diag_level=$((diag_level + 1))
    done
    echo $diag_found
}

# Read-only Wi-Fi and USB facts for supporting other radios (e.g. a USB Wi-Fi dongle):
# kernel, loaded modules, network interfaces with their bus and driver, USB ids,
# driver/firmware file names, Wi-Fi init services, Wi-Fi properties and kernel log lines.
# Fixed paths only; HMG_SEOGAEMO_WIFI_ROOT prefixes them for host tests. The caller redacts.
hmg_seogaemo_diag_wifi() {
    wr=${HMG_SEOGAEMO_WIFI_ROOT:-}
    sg_print '# kernel'
    cat "$wr/proc/version"
    sg_print '# modules'
    cat "$wr/proc/modules"
    sg_print '# net'
    for wn in "$wr"/sys/class/net/*; do
        [ -e "$wn" ] || continue
        sg_print "net=${wn##*/} path=$(readlink "$wn") driver=$(readlink "$wn/device/driver")"
        [ ! -f "$wn/operstate" ] || sg_print "operstate=$(cat "$wn/operstate")"
        [ ! -f "$wn/device/uevent" ] || cat "$wn/device/uevent"
    done
    sg_print '# usb'
    for wd in "$wr"/sys/bus/usb/devices/*; do
        [ -e "$wd" ] || continue
        wl="usb=${wd##*/}"
        for wk in idVendor idProduct bDeviceClass bInterfaceClass manufacturer product speed; do
            [ ! -f "$wd/$wk" ] || wl="$wl $wk=$(cat "$wd/$wk")"
        done
        sg_print "$wl"
        [ ! -f "$wd/uevent" ] || grep -e '^DRIVER=' -e '^PRODUCT=' -e '^MODALIAS=' "$wd/uevent"
    done
    sg_print '# files'
    ls -l "$wr/system/lib/modules" "$wr/lib/modules" "$wr/system/wifi" "$wr/system/etc/wifi" \
        "$wr/system/etc/firmware" "$wr/vendor/firmware" "$wr/system/vendor/firmware"
    ls -l "$wr/system/bin/wpa_supplicant" "$wr/system/bin/hostapd" "$wr/system/bin/dhcpcd" \
        "$wr/system/bin/iw" "$wr/system/xbin/iw"
    ls "$wr/system/etc/permissions"
    sg_print '# init'
    grep -h -i -e wpa_supplicant -e p2p_supplicant -e hostapd -e dhcpcd -e insmod -e wlan -e wifi \
        -e firmware "$wr"/init*.rc
    sg_print '# properties'
    getprop | grep -i -e wifi -e wlan -e wpa -e hostapd -e p2p -e dhcp -e usb -e tcc
    sg_print '# dmesg'
    dmesg | grep -i -e usb -e wlan -e wifi -e 80211 -e firmware -e rtl -e rtw -e mt7 -e ath -e bcm -e dhd
}

hmg_seogaemo_diagnostics() (
    diag=$1/diagnostics
    # Raw (unredacted) bytes are staged only in a private 0700 directory under
    # the state tree, never in the export folder that lives on removable media.
    # Only redacted, size-capped files are written into "$diag". A killed run
    # (SIGKILL cannot be trapped) leaves its staging directory here; the next
    # run sweeps exactly diagnostics-tmp.<digits> directories of dead processes.
    umask 077
    for stale in "$SG_DATA_ROOT"/diagnostics-tmp.*; do
        case "${stale##*/diagnostics-tmp.}" in ''|*[!0-9]*) continue;; esac
        [ -d "$stale" ] && [ ! -L "$stale" ] || continue
        ! kill -0 "${stale##*.}" 2>/dev/null || continue
        rm -rf "$stale"
    done
    stage=$SG_DATA_ROOT/diagnostics-tmp.$$
    rm -rf "$stage"
    mkdir -p "$SG_DATA_ROOT" && mkdir "$stage" && chmod 0700 "$stage" || exit 1
    trap 'diag_code=$?; rm -rf "$stage"; exit "$diag_code"' 0
    trap 'exit 1' 1 2 3 15
    mkdir -p "$diag" || exit 1
    count=0
    : > "$diag/manifest.txt"
    redact() {
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                *[Ss][Ss][Ii][Dd]*|*[Pp][Ss][Kk]*|*[Pp][Aa][Ss][Ss]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*|*[Tt][Oo][Kk][Ee][Nn]*|*[Cc][Rr][Ee][Dd]*) sg_print '[redacted sensitive line]';;
                *) sg_print "$line";;
            esac
        done
    }
    reserve() {
        [ "$count" -lt 32 ] || { sg_print "omitted budget: $1" >> "$diag/manifest.txt"; return 1; }
        count=$((count + 1))
    }
    copy_log() {
        [ -f "$1" ] && sg_path_safe "$1" || return 0
        reserve "$2" || return 0
        mkdir -p "$diag/${2%/*}" || return 1
        bytes=$(sg_file_size "$1") || return 1
        # Block-sized reads from the regular file (a byte-at-a-time dd on a
        # head unit is far too slow); keep the last $keep blocks (default 16 = 64 KiB).
        keep=${3:-16}
        blocks=$(((bytes + 4095) / 4096))
        skip=0
        if [ "$blocks" -gt "$keep" ]; then
            skip=$((blocks - keep))
            sg_print "truncated to last $((keep * 4096)) bytes: $2" >> "$diag/manifest.txt"
        fi
        # Stage the block read in a file so the line loop reads a seekable
        # descriptor (buffered) instead of a pipe (one syscall per byte).
        dd if="$1" bs=4096 skip="$skip" count="$keep" 2>/dev/null > "$stage/raw"
        {
            # A tail can begin inside a credential line: discard that fragment.
            if [ "$skip" -gt 0 ]; then IFS= read -r fragment || :; fi
            redact
        } < "$stage/raw" > "$stage/stage"
        rm -f "$stage/raw"
        # Redaction can lengthen short lines; cap from a file, never a pipe
        # (a short pipe read would make a block-counted dd stop early).
        dd if="$stage/stage" bs=4096 count="$keep" 2>/dev/null > "$diag/$2"
        rm -f "$stage/stage"
    }
    probe() {
        name=$1; shift
        # Bound duration. Output goes to a file, never a pipe, so a lingering
        # grandchild cannot block this function; status alone is read-only.
        : > "$stage/probe"
        (
            /system/bin/sh "$base/bin/hmg-seogaemo-root" "$@" > "$stage/probe" 2>&1 < /dev/null &
            pid=$!
            (
                n=0
                while [ "$n" -lt 10 ]; do
                    sleep 1
                    kill -0 "$pid" 2>/dev/null || exit 0
                    n=$((n + 1))
                done
                kill $(hmg_seogaemo_diag_descendants "$pid") "$pid" 2>/dev/null
            ) > /dev/null 2>&1 < /dev/null &
            guard=$!
            wait "$pid"
            code=$?
            kill "$guard" 2>/dev/null || :
            wait "$guard" 2>/dev/null || :
            kill $(hmg_seogaemo_diag_descendants "$pid") 2>/dev/null || :
            sg_print "probe exit=$code: $name" >> "$diag/manifest.txt"
        )
        dd if="$stage/probe" bs=4096 count=16 2>/dev/null > "$stage/raw"
        redact < "$stage/raw" > "$stage/stage"
        rm -f "$stage/raw"
        dd if="$stage/stage" bs=4096 count=16 2>/dev/null > "$diag/$name"
        rm -f "$stage/probe" "$stage/stage"
    }
    for source in "$SG_DATA_ROOT"/reconcile.log* "$SG_DATA_ROOT"/watcher.log*; do
        copy_log "$source" "logs/${source##*/}" || exit 1
    done
    for area in stock uninstall update; do
        for leaf in result module-output journal log uninstall.log runner.log; do
            copy_log "$SG_DATA_ROOT/$area/$leaf" "$area/$leaf" || exit 1
        done
    done
    probe map-status.txt map status
    props='ro.build.product ro.build.version.release ro.build.version.sdk ro.product.device ro.product.model ro.product.board ro.build.fingerprint sys.boot_completed service.adb.tcp.port init.svc.adbd init.svc.hostapd'
    : > "$diag/owned-paths.txt"
    for id in $(sg_module_list "$base"); do
        case "$id" in ''|*[!a-z0-9-]*|-*|*--*|*-) continue;; esac
        probe "module-$id-status.txt" "$id" status
        copy_log "$SG_DATA_ROOT/modules/$id/module.log" "modules/$id/module.log" || exit 1
        paths=$(sg_module_dir "$base" "$id")
        manifest=$(sg_module_props "$base" "$id")
        if [ -f "$manifest" ]; then
            while IFS='=' read -r key value; do
                case "$key" in
                    owns_props) props="$props $value";;
                    owns_files) paths="$paths $value";;
                    owns_lines.*) paths="$paths ${value%%:*}";;
                esac
            done < "$manifest"
        fi
        (
            IFS=' ,'
            for path in $paths; do
                case "$path" in /*) ;; *) continue;; esac
                sg_print "module=$id path=$path"
                ls -ldn "$path" 2>&1
                while [ "$path" != / ]; do
                    path=${path%/*}
                    [ -n "$path" ] || path=/
                    ls -ldn "$path" 2>&1
                done
            done
        ) > "$stage/stage"
        dd if="$stage/stage" bs=4096 count=2 2>/dev/null >> "$diag/owned-paths.txt"
        rm -f "$stage/stage"
    done
    (
        IFS=' ,'
        for prop in $props; do
            case "$prop" in ''|*[!a-zA-Z0-9_.-]*) continue;; esac
            case "$prop" in
                *[Ss][Ss][Ii][Dd]*|*[Pp][Ss][Kk]*|*[Pp][Aa][Ss][Ss]*|*[Ss][Ee][Cc][Rr][Ee][Tt]*|*[Tt][Oo][Kk][Ee][Nn]*|*[Kk][Ee][Yy]*|*[Cc][Rr][Ee][Dd]*) sg_print "$prop=[redacted]";;
                *) sg_print "$prop=$(getprop "$prop")" | redact;;
            esac
        done
    ) > "$stage/stage"
    dd if="$stage/stage" bs=4096 count=16 2>/dev/null > "$diag/properties.txt"
    rm -f "$stage/stage"
    # Fixed area, bounded depth, text logs/receipts only; never copy configs.
    for area in $HMG_SEOGAEMO_DIAGNOSTIC_RUNTIME_DIRS; do
        for source in "$SG_DATA_ROOT/$area"/* "$SG_DATA_ROOT/$area"/*/* "$SG_DATA_ROOT/$area"/*/*/* "$SG_DATA_ROOT/$area"/wireless-carplay-and-aa/apps/*/*; do
            case "${source##*/}" in
                *.log|*.log.1|*.txt|result|module-output) copy_log "$source" "${source#"$SG_DATA_ROOT/"}" || exit 1;;
            esac
        done
    done
    # CarPlay turn-by-turn records (DiPO's generated maneuver/lane summaries and
    # journals, no credentials): fixed names, copied whole outside the log budget,
    # at most 1 MiB + 64 KiB per file (12 files, about 13 MiB).
    tbt=${HMG_SEOGAEMO_DIPO_RUNTIME:-/data/data/com.daudio.app.dipo/app_hmg-seogaemo-wireless-runtime}
    for name in tbt-icons.txt tbt-lanes.txt tbt-icons.journal tbt-icons.journal.1 tbt-icons.journal.2 \
        tbt-icons.journal.3 tbt-icons.journal.4 tbt-icons.journal.5 tbt-lanes.journal tbt-lanes.journal.1 \
        tbt-lanes.journal.2 tbt-lanes.journal.3; do
        [ -f "$tbt/$name" ] && sg_path_safe "$tbt/$name" || continue
        mkdir -p "$diag/tbt" || exit 1
        dd if="$tbt/$name" bs=4096 count=272 2>/dev/null > "$diag/tbt/$name"
    done
    # Problem report extras: Android log (all, or only lines from our area), NEMESIS log, the
    # app's own view (fixed file the app writes before exporting) and a one-page summary.
    case "${HMG_SEOGAEMO_EXPORT_LOGS:-none}" in all|ours)
        logcat -d -v time > "$stage/logcat.txt" 2>/dev/null || :
        if [ "$HMG_SEOGAEMO_EXPORT_LOGS" = ours ]; then
            grep -i -e hmg-seogaemo -e nemesis -e dipo -e iap2 -e projection -e carplay -e AndroidRuntime \
                "$stage/logcat.txt" > "$stage/logcat.sel" 2>/dev/null || :
            mv "$stage/logcat.sel" "$stage/logcat.txt"
        fi
        copy_log "$stage/logcat.txt" logs/logcat.txt 128 || exit 1
        rm -f "$stage/logcat.txt"
        nemesis log dump > "$stage/nemesis.txt" 2>&1 < /dev/null || :
        copy_log "$stage/nemesis.txt" logs/nemesis.txt 32 || exit 1
        rm -f "$stage/nemesis.txt"
        hmg_seogaemo_diag_wifi > "$stage/raw" 2>&1 < /dev/null || :
        redact < "$stage/raw" > "$stage/stage"
        sg_redact < "$stage/stage" > "$stage/raw"
        dd if="$stage/raw" bs=4096 count=16 2>/dev/null > "$diag/wifi-usb.txt"
        rm -f "$stage/raw" "$stage/stage"
        # Kernel build options (which Wi-Fi/USB drivers could load); compressed binary, no personal data.
        [ ! -f "${HMG_SEOGAEMO_WIFI_ROOT:-}/proc/config.gz" ] ||
            dd if="${HMG_SEOGAEMO_WIFI_ROOT:-}/proc/config.gz" bs=4096 count=64 2>/dev/null > "$diag/kernel-config.gz"
        copy_log "${HMG_SEOGAEMO_APP_STATE:-/data/data/com.seogaemo.hmg/files/report/app-state.txt}" app/app-state.txt || exit 1
        {
            sg_print "HMG-Seogaemo problem report" "time=$(date)" "logs=$HMG_SEOGAEMO_EXPORT_LOGS"
            grep '^package-version=' "$base/NEMESIS.data" 2>/dev/null
            sg_print "product=$(getprop ro.build.product)"
            for status in "$diag"/map-status.txt "$diag"/module-*-status.txt; do
                [ -f "$status" ] || continue
                name=${status##*/}
                while IFS= read -r line; do
                    case "$line" in state=*|detail=*) sg_print "${name%.txt}: $line";; esac
                done < "$status"
            done
        } > "$diag/summary.txt"
        sg_print "report logs: $HMG_SEOGAEMO_EXPORT_LOGS (logcat 512 KiB, NEMESIS 128 KiB, Wi-Fi/USB 64 KiB, kernel config 256 KiB)" >> "$diag/manifest.txt" ;;
    esac
    sg_print 'limits: 32 logs, 64 KiB each; status 64 KiB/10 seconds each; metadata 8 KiB/module; properties 64 KiB; turn-by-turn records 1 MiB + 64 KiB each' >> "$diag/manifest.txt"
)
