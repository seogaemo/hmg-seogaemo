#!/system/bin/sh
# Read-only constraint checks for this head unit ("car check").
# Sourced by core/recorder.sh after lib/common.sh. Never writes, never powers the radio.
#
# hmg_seogaemo_preflight prints one line per check on stdout:
#   <id>|<level>|<evidence>|<message>
#   level    ok | warn | block | unknown
#   evidence observed (read from the unit now) | inferred (a guess from indirect signs)
# block = the feature that needs it cannot work on this unit; warn = may fail or needs care.
#
# Test seams (host tests only): SG_TARGET_ROOT prefixes /system paths, SG_SDIO_DIR and
# SG_MMC_DIR replace the sysfs bus directories, SG_CMDLINE_FILE replaces /proc/cmdline.

pf_line() { sg_print "$1|$2|$3|$4"; }

# Characters allowed in a message that the app shows (no pipes, no control characters).
pf_text() { sg_clean "$1"; }

pf_cmdline_word() {
    pf_cw_file=${SG_CMDLINE_FILE:-/proc/cmdline}
    pf_cw_line=
    { read -r pf_cw_line < "$pf_cw_file"; } 2>/dev/null || return 1
    for pf_cw_word in $pf_cw_line; do
        case "$pf_cw_word" in "$1"=*) sg_print "${pf_cw_word#*=}"; return 0;; esac
    done
    return 1
}

pf_count_entries() {
    pf_ce_n=0
    for pf_ce_e in "$1"/*; do
        [ -e "$pf_ce_e" ] || continue
        case "${pf_ce_e##*/}" in $2) pf_ce_n=$((pf_ce_n + 1));; esac
    done
    sg_print "$pf_ce_n"
}

pf_dmesg_count() {
    pf_dc_n=0
    pf_dc_out=$(dmesg 2>/dev/null) || { sg_print 0; return 0; }
    while IFS= read -r pf_dc_l; do
        case "$pf_dc_l" in *"$1"*) pf_dc_n=$((pf_dc_n + 1));; esac
    done <<EOF
$pf_dc_out
EOF
    sg_print "$pf_dc_n"
}

# Wi-Fi hardware: the one constraint that cannot be fixed in software.
pf_wifi_hardware() {
    pf_sdio=$(pf_count_entries "${SG_SDIO_DIR:-/sys/bus/sdio/devices}" '*')
    pf_card=$(pf_count_entries "${SG_MMC_DIR:-/sys/bus/mmc/devices}" 'mmc1:*')
    pf_fail=$(pf_dmesg_count 'failed to power up DHD generic adapter')
    pf_mac=$(pf_cmdline_word androidboot.wifimac) || pf_mac=
    if [ "$pf_sdio" -gt 0 ] || [ "$pf_card" -gt 0 ]; then
        pf_line wifi_hw ok observed 'A Wi-Fi chip answers on the SDIO bus'
    elif [ "$pf_fail" -gt 0 ]; then
        pf_line wifi_hw block observed "The radio was powered but nothing answered on the SDIO bus ($pf_fail failed power-up tries in the kernel log); wireless CarPlay cannot work on this unit"
    elif [ -z "$pf_mac" ]; then
        pf_line wifi_hw warn inferred 'No Wi-Fi chip seen yet and the factory Wi-Fi address is empty; turn Wi-Fi on once, then check again'
    else
        pf_line wifi_hw unknown inferred 'No Wi-Fi chip seen yet; the radio stays off until Wi-Fi is turned on once, then check again'
    fi
}

pf_wifi_radio() {
    pf_drv=$(getprop wlan.driver.status)
    case "$pf_drv" in
        ok) pf_line wifi_radio ok observed 'Wi-Fi driver loaded' ;;
        unloaded|'') pf_line wifi_radio ok observed 'Wi-Fi driver not loaded (radio off)' ;;
        loading|unloading) pf_line wifi_radio warn observed "Wi-Fi driver is $pf_drv; wait or restart the head unit before installing" ;;
        *) pf_line wifi_radio unknown observed "Wi-Fi driver status: $(pf_text "$pf_drv")" ;;
    esac
}

# Radios the wifi module can use: the stock built-in client capability, and a USB adapter
# that the bundled drivers bind (the wifi module's files/usb-ids.txt, read from sysfs ids).
pf_wifi_radios() {
    pf_root=${SG_TARGET_ROOT:-}
    # Driver and firmware ship even without the chip; failed power-ups with nothing on SDIO mean none.
    if [ "$(getprop tcc.wifi.vendor)" = broadcom ] && [ -s "$pf_root/system/wifi/bcmdhd.ko" ] &&
            [ -s "$pf_root/system/wifi/fw_bcmdhd.bin" ] &&
            { [ "$(pf_count_entries "${SG_SDIO_DIR:-/sys/bus/sdio/devices}" '*')" -gt 0 ] ||
                [ "$(pf_dmesg_count 'failed to power up DHD generic adapter')" -eq 0 ]; }; then
        pf_line wifi_builtin ok observed 'Built-in Wi-Fi present (Broadcom)'
    else
        pf_line wifi_builtin warn observed 'No built-in Wi-Fi; Wi-Fi needs a USB adapter'
    fi
    pf_table=$(sg_module_dir "${HMG_SEOGAEMO_BASE:-}" wifi 2>/dev/null)/files/usb-ids.txt
    pf_other=
    for pf_dev in "${SG_USB_DEVICES_DIR:-/sys/bus/usb/devices}"/*; do
        [ -f "$pf_dev/idVendor" ] && [ -f "$pf_dev/idProduct" ] || continue
        pf_vid=$(cat "$pf_dev/idVendor" 2>/dev/null); pf_pid=$(cat "$pf_dev/idProduct" 2>/dev/null)
        if [ -f "$pf_table" ]; then
            while read -r pf_v pf_p pf_mod pf_model; do
                [ "$pf_v:$pf_p" = "$pf_vid:$pf_pid" ] || continue
                pf_line wifi_usb ok observed "$(pf_text "$pf_model ($pf_vid:$pf_pid, driver $pf_mod) is supported")"
                return 0
            done < "$pf_table"
        fi
        # Realtek parts the bundled drivers do not bind (hubs and card readers share the vendor).
        [ "$pf_vid" != 0bda ] || pf_other=$pf_vid:$pf_pid
    done
    if [ -n "$pf_other" ]; then
        pf_line wifi_usb unknown observed "USB device $(pf_text "$pf_other") is not a supported Wi-Fi adapter"
    else
        pf_line wifi_usb unknown observed 'No supported USB Wi-Fi adapter connected'
    fi
}

# Other packages: one catalogue, core/foreign.sh. The check only reports; cleaning is the Car tab's.
pf_conflicts() {
    pf_cf_out=$(SG_SYSTEM_ROOT=${SG_TARGET_ROOT:-} /system/bin/sh "${HMG_SEOGAEMO_BASE:-}/core/foreign.sh" status 2>/dev/null)
    case "$pf_cf_out" in *info.count=*) ;; *)
        pf_line conflict_scan unknown inferred 'Could not read the other-package scan'
        return 0 ;;
    esac
    pf_cf_api= ; pf_cf_leafia= ; pf_cf_adb= ; pf_cf_other=
    while IFS= read -r pf_cf_line; do
        case "$pf_cf_line" in info.item_*) ;; *) continue;; esac
        # "<item-id>,<class>", so every pattern ends at the comma.
        case "${pf_cf_line#*=}" in
            pkg-hmgapi*|hmgapi-*) pf_cf_api=1 ;;
            pkg-leafia,*|leafia-*|app-process-leafia,*) pf_cf_leafia=1 ;;
            pkg-adb-tcp,*|adb-tcp-orphan,*) pf_cf_adb=1 ;;
            foreign-logs,*) ;;
            *) pf_cf_other=1 ;;
        esac
    done <<EOF
$pf_cf_out
EOF
    if [ -n "$pf_cf_api" ]; then
        pf_line conflict_hmgapi block observed 'HMG-API is installed or left files behind; clean it in Car settings first'
    else
        pf_line conflict_hmgapi ok observed 'HMG-API not installed'
    fi
    if [ -n "$pf_cf_leafia" ]; then
        pf_line conflict_leafia block observed 'HMG Leafia Plus is installed or left files behind; clean it in Car settings first'
    else
        pf_line conflict_leafia ok observed 'HMG Leafia Plus not installed'
    fi
    [ -z "$pf_cf_adb" ] ||
        pf_line conflict_adbtcp warn observed 'A NEMESIS ADB TCP package is installed and may hold the network settings'
    [ -z "$pf_cf_other" ] ||
        pf_line conflict_other warn observed 'Another package left items behind; see Car settings to clean them'
}

pf_native_libs() {
    pf_root=${SG_TARGET_ROOT:-}
    pf_known=
    pf_module=$(sg_module_dir "${HMG_SEOGAEMO_BASE:-}" wireless-carplay-and-aa 2>/dev/null)
    for pf_rec in "$pf_module"/files/recipes/*.recipe "$pf_module"/payload/recipes/*.recipe "$pf_module"/recipes/*.recipe; do
        [ -f "$pf_rec" ] || continue
        while IFS=' ' read -r pf_kw pf_a pf_b; do
            [ "$pf_kw" = native ] && pf_known="$pf_known $pf_a"
        done < "$pf_rec"
    done
    for pf_lib in libCarPlayCore libCarPlayAudio libCarPlayUtils libautoreceiver_infobank libiap2session; do
        pf_path=$pf_root/system/lib/$pf_lib.so
        if [ ! -f "$pf_path" ]; then
            pf_line "lib_$pf_lib" warn observed "$pf_lib.so is missing"
            continue
        fi
        set -- $(md5 "$pf_path" 2>/dev/null)
        pf_sum=$1
        case "$pf_sum" in ''|*[!0-9a-f]*) pf_line "lib_$pf_lib" unknown observed "$pf_lib.so hash unreadable"; continue;; esac
        case " $pf_known " in
            *" $pf_sum "*) pf_line "lib_$pf_lib" ok observed "$pf_lib.so matches a known recipe ($pf_sum)" ;;
            *) pf_line "lib_$pf_lib" unknown observed "$pf_lib.so hash $pf_sum is not named by a recipe" ;;
        esac
    done
}

# Each installed module states its own constraints through its precheck verb.
pf_modules() {
    pf_base=${HMG_SEOGAEMO_BASE:-}
    [ -n "$pf_base" ] && [ -f "$pf_base/bin/hmg-seogaemo-root" ] || return 0
    for pf_id in $(sg_module_list "$pf_base"); do
        pf_out=$(/system/bin/sh "$pf_base/bin/hmg-seogaemo-root" "$pf_id" precheck 2>/dev/null)
        pf_state=; pf_detail=
        while IFS='=' read -r pf_k pf_v; do
            case "$pf_k" in state) pf_state=$pf_v;; detail) pf_detail=$pf_v;; esac
        done <<EOF
$pf_out
EOF
        case "$pf_state" in
            off|on|pending-restart|not-implemented) pf_line "module_$pf_id" ok observed "can be used${pf_detail:+: $(pf_text "$pf_detail")}" ;;
            conflict) pf_line "module_$pf_id" warn observed "$(pf_text "${pf_detail:-conflict}")" ;;
            incompatible) pf_line "module_$pf_id" block observed "$(pf_text "${pf_detail:-incompatible}")" ;;
            failed) pf_line "module_$pf_id" warn observed "precheck failed: $(pf_text "${pf_detail:-no detail}")" ;;
            *) pf_line "module_$pf_id" unknown observed 'precheck gave no answer' ;;
        esac
    done
}

hmg_seogaemo_preflight() {
    pf_product=$(getprop ro.build.product)
    case "$pf_product" in
        NEEV.KOR.*.260902) pf_line firmware ok observed "Ioniq 5 KOR 260902 ($pf_product)" ;;
        *.KOR.*) pf_line firmware warn observed "Korean head unit ($pf_product); only the Ioniq 5 KOR 260902 is verified on a car" ;;
        '') pf_line firmware unknown observed 'ro.build.product is empty' ;;
        *) pf_line firmware block observed "Unsupported firmware: $(pf_text "$pf_product")" ;;
    esac
    [ "$(getprop ro.build.version.release)" = 4.4.2 ] &&
        pf_line android ok observed 'Android 4.4.2' ||
        pf_line android block observed "Android $(pf_text "$(getprop ro.build.version.release)") (4.4.2 required)"
    case "$(getprop ro.mobis.onebindir)" in
        *_kr) pf_line onebin ok observed "onebin $(pf_text "$(getprop ro.mobis.onebindir)")" ;;
        *) pf_line onebin block observed "onebin $(pf_text "$(getprop ro.mobis.onebindir)") (a Korean *_kr folder is required)" ;;
    esac
    [ "$(getprop sys.boot_completed)" = 1 ] &&
        pf_line boot ok observed 'Android finished booting' ||
        pf_line boot warn observed 'Android has not finished booting; results may be incomplete'
    if [ "$(getprop persist.service.adb.tcp.enable)" = 1 ]; then
        pf_line adb_tcp warn observed 'The stock ADB over network switch is on; it uses the hotspot subnet and stops wireless CarPlay'
    else
        pf_line adb_tcp ok observed 'The stock ADB over network switch is off'
    fi
    pf_conflicts
    pf_wifi_hardware
    pf_wifi_radio
    pf_wifi_radios
    pf_native_libs
    pf_modules
}
