#!/bin/sh
# Wi-Fi radios for Korean firmware (verified on NEEV KOR 260902), one role per radio.
#
# Built-in radio (stock Broadcom, wlan0), setting builtin_role:
#   client      exposes the stock Wi-Fi client menu: android.hardware.wifi feature XML and
#               persist.wifi.state=3 (this was the wifi-client module). On NEEV.KOR.260902
#               featurexml.cfg has no android.hardware.wifi removal line and stock
#               HKMC_WifiSettings gates its client menu on that PackageManager feature
#               (verified on the car 2026-11-03). No stock file reads persist.wifi.state.
#   carplay_ap  left to the stock hotspot Android starts for wireless CarPlay/Android Auto
#   off         untouched
# USB radio (Realtek 88x2bu/8851bu adapter, interface rtwlan0), setting usb_role:
#   client      driver, wpa_supplicant -Dnl80211 and dhcpcd; the network is chosen in the app
#   carplay_ap  driver, hostapd (nl80211) and dnsmasq on 192.168.50.1/24, one INPUT accept rule
#   off         untouched
# USB effects are transient runtime records (gone at a restart); boot reconcile and the
# screen_on watch create them again. Only one radio may be carplay_ap; that hotspot is
# published for other modules with sg_peer_publish (read with sg_peer_info wifi <key>).
set -u
. "$HMG_SEOGAEMO_BASE/lib/common.sh"

xml=/system/etc/permissions/android.hardware.wifi.xml
prop=persist.wifi.state
value=3
id=${HMG_SEOGAEMO_STATE##*/}
usb_iface=rtwlan0
ap_ip=192.168.50.1
ap_channel=6
usb_devices=${SG_USB_DEVICES_DIR:-/sys/bus/usb/devices}
net_root=${SG_SYS_NET_ROOT:-/sys/class/net}
inbox=${HMG_SEOGAEMO_WIFI_INBOX:-/data/data/com.seogaemo.hmg/files/wifi}
applying=0

result() { sg_status "$1" "$2" "$3"; exit $?; }

role() {
    rl_value=$(cat "$SG_DATA_ROOT/settings/$id/$1" 2>/dev/null) || rl_value=
    case "$rl_value" in off|client|carplay_ap) sg_write "$rl_value" ;; *) sg_write "$2" ;; esac
}
usb_role=$(role usb_role off)

desired_file_on() { [ "$(cat "$SG_DATA_ROOT/desired/$id" 2>/dev/null)" = on ]; }
desired_on() { [ "$applying" -eq 1 ] || desired_file_on; }

xml_ours() {
    [ -f "$xml" ] &&
        cmp "$HMG_SEOGAEMO_MODULE_DIR/files/android.hardware.wifi.xml" "$xml" >/dev/null 2>&1
}
pm_wifi() { pm list features 2>/dev/null | grep -Fxq 'feature:android.hardware.wifi'; }

wifi_capable() {
    # Stock init sets the vendor at boot; libhardware_legacy loads this driver
    # and normal firmware on demand. SDIO and wlan0 can both vanish with power
    # off, so enumeration and wlan.driver.status cannot gate initial enable.
    [ "$(getprop tcc.wifi.vendor 2>/dev/null)" = broadcom ] &&
        [ -f /system/wifi/bcmdhd.ko ] && [ -s /system/wifi/bcmdhd.ko ] &&
        [ -f /system/wifi/fw_bcmdhd.bin ] && [ -s /system/wifi/fw_bcmdhd.bin ] &&
        ! builtin_missing
}
# Some cars ship the Broadcom driver and firmware without the chip (a tester's NEEV KOR car,
# 2026-11-07): nothing answers on SDIO and bcmdhd logs failed power-ups, the same evidence as the
# preflight wifi_hw check. Kernel log only, so the hint is lost once the log rotates.
builtin_missing() {
    for bm_dev in "${SG_SDIO_DIR:-/sys/bus/sdio/devices}"/*; do [ ! -e "$bm_dev" ] || return 1; done
    # The owner's chip probe (action wifi_probe) leaves a marker that outlives the kernel log.
    bm_mark=$(cat "$SG_DATA_ROOT/wifi-chip" 2>/dev/null) || bm_mark=
    [ "$bm_mark" != seen ] || return 1
    [ "$bm_mark" != absent ] || return 0
    dmesg 2>/dev/null | grep -Fq 'failed to power up DHD generic adapter'
}
# The app hides the built-in role without the radio, so the unset default must not be the client.
if wifi_capable; then builtin_role=$(role builtin_role client); else builtin_role=$(role builtin_role off); fi

# Prints "<vendor>:<product> <kernel module> <model>" for the first connected USB adapter
# that a bundled driver binds (files/usb-ids.txt, taken from the drivers' device id tables).
usb_adapter() {
    ua_table=$HMG_SEOGAEMO_MODULE_DIR/files/usb-ids.txt
    [ -f "$ua_table" ] || return 1
    for ua_dev in "$usb_devices"/*; do
        [ -f "$ua_dev/idVendor" ] && [ -f "$ua_dev/idProduct" ] || continue
        ua_vid=$(cat "$ua_dev/idVendor" 2>/dev/null) || continue
        ua_pid=$(cat "$ua_dev/idProduct" 2>/dev/null) || continue
        while read -r ua_v ua_p ua_mod ua_model; do
            case "$ua_v" in ''|'#'*) continue ;; esac
            [ "$ua_v" = "$ua_vid" ] && [ "$ua_p" = "$ua_pid" ] || continue
            sg_print "$ua_vid:$ua_pid $ua_mod $ua_model"
            return 0
        done < "$ua_table"
    done
    return 1
}

external_owner() {
    sg_owner_present leafia ||
        [ -f /data/nemesis/apps/wireless.projection/NEMESIS.data ]
}

parse_client_ip() {
    mode=$1
    iface=$2
    line=
    while IFS= read -r line || [ -n "$line" ]; do
        set -f; set -- $line; set +f
        ip=
        if [ "$mode" = netcfg ]; then
            [ "$#" -gt 0 ] || continue
            [ "$1" = "$iface" ] || continue
            shift
            for field do
                case "$field" in */*) ip=${field%%/*}; break ;; esac
            done
        else
            while [ "$#" -gt 1 ]; do
                if [ "$1" = inet ]; then
                    shift
                    ip=${1#addr:}
                    break
                fi
                shift
            done
        fi
        # A hotspot owns 192.168.0.1 (stock) or 192.168.50.1 (ours); never report it as a client IP.
        case "$ip" in
            ''|0.0.0.0|192.168.0.1|"$ap_ip"|*[!0-9.]*|.*|*..*|*.) continue ;;
            *.*.*.*) sg_print "$ip"; break ;;
        esac
    done
}

# The unit has no wpa_cli for wlan0; a non-hotspot IPv4 address means DHCP finished.
client_ip() {
    [ -e "$net_root/$1" ] || return 0
    ip=$(ifconfig "$1" 2>/dev/null | parse_client_ip ifconfig "$1")
    [ -n "$ip" ] || ip=$(netcfg 2>/dev/null | parse_client_ip netcfg "$1")
    [ -z "$ip" ] || sg_print "$ip"
}

ap_active() {
    [ "$(getprop init.svc.hostapd 2>/dev/null)" = running ] && return 0
    ifconfig wlan0 2>/dev/null | grep -Eq '(^|[ :])192\.168\.0\.1([ /]|$)'
}

projection_desired() {
    [ "$(cat "$SG_DATA_ROOT/desired/wireless-carplay-and-aa" 2>/dev/null)" = on ]
}

compatible() {
    case "$(getprop ro.build.product 2>/dev/null)" in
        *.KOR.*) ;;
        *) result incompatible none 'Unsupported firmware' ;;
    esac
}

one_hotspot() {
    if [ "$1" = carplay_ap ] && [ "$2" = carplay_ap ]; then
        result conflict none 'Only one radio can run the CarPlay hotspot'
    fi
}
# The built-in radio cannot be a client and serve the stock hotspot at the same time.
hotspot_left() { [ "$1" != client ] || [ "$2" = carplay_ap ]; }
roles_ok() {
    one_hotspot "$1" "$2"
    if ! hotspot_left "$1" "$2" && projection_desired; then
        result conflict none 'Wireless CarPlay needs a hotspot: turn it off or give the USB adapter the CarPlay hotspot role'
    fi
}

# Refuse built-in targets this module did not write; shared by precheck and apply.
unowned_changes() {
    if external_owner; then result conflict none 'Another package owns Wi-Fi feature files'; fi
    if sg_applied "$xml" || sg_applied "$prop"; then return 0; fi
    if [ -e "$xml" ]; then
        if xml_ours; then result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'; fi
        result conflict none 'Existing Wi-Fi feature XML differs'
    fi
    if [ -n "$(getprop "$prop" 2>/dev/null)" ]; then
        [ "$(getprop "$prop" 2>/dev/null)" != "$value" ] ||
            result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'
        result conflict none 'persist.wifi.state is set outside this module'
    fi
}

state_value() {
    sv_file=$HMG_SEOGAEMO_STATE/$1
    [ -f "$sv_file" ] || return 1
    while IFS='=' read -r sv_key sv_value; do
        [ "$sv_key" != "$2" ] || { sg_write "$sv_value"; return 0; }
    done < "$sv_file"
    return 1
}

random_hex() {
    rh_raw=$(cat "${SG_UUID_FILE:-/proc/sys/kernel/random/uuid}" 2>/dev/null) || return 1
    rh_out=
    while [ -n "$rh_raw" ]; do
        rh_char=${rh_raw%"${rh_raw#?}"}
        rh_raw=${rh_raw#?}
        case "$rh_char" in [0-9a-f]) rh_out=$rh_out$rh_char ;; esac
    done
    [ "${#rh_out}" -eq 32 ] && sg_write "$rh_out"
}
first_chars() {
    fc_in=$1; fc_out=; fc_n=0
    while [ "$fc_n" -lt "$2" ] && [ -n "$fc_in" ]; do
        fc_out=$fc_out${fc_in%"${fc_in#?}"}
        fc_in=${fc_in#?}
        fc_n=$((fc_n + 1))
    done
    sg_write "$fc_out"
}

ap_credentials() {
    [ -n "$(state_value usb-ap ssid)" ] && [ -n "$(state_value usb-ap pass)" ] && return 0
    ac_a=$(random_hex) && ac_b=$(random_hex) || return 1
    sg_ready || return 1
    sg_print "ssid=HMG-Seogaemo-$(first_chars "$ac_a" 4)" "pass=$(first_chars "$ac_b" 20)" > "$HMG_SEOGAEMO_STATE/usb-ap"
}

usb_hostapd_conf() {
    sg_ready || return 1
    sg_print "interface=$usb_iface" driver=nl80211 "ssid=$(state_value usb-ap ssid)" country_code=KR \
        hw_mode=g "channel=$ap_channel" ieee80211n=1 wmm_enabled=1 auth_algs=1 wpa=2 \
        wpa_key_mgmt=WPA-PSK rsn_pairwise=CCMP "wpa_passphrase=$(state_value usb-ap pass)" \
        > "$HMG_SEOGAEMO_STATE/usb-hostapd.conf"
}

# The network chosen in the app: ssid as hex, psk as the 64-hex WPA key or "none" (open).
usb_wpa_conf() {
    sg_ready || return 1
    wc_ssid=$(state_value usb-network ssid) || wc_ssid=
    wc_psk=$(state_value usb-network psk) || wc_psk=
    {
        sg_print "ctrl_interface=$HMG_SEOGAEMO_STATE/wpa" update_config=0 ap_scan=1
        if [ -n "$wc_ssid" ]; then
            sg_print 'network={' "	ssid=$wc_ssid" '	scan_ssid=1'
            if [ "$wc_psk" = none ]; then sg_print '	key_mgmt=NONE'; else sg_print "	psk=$wc_psk"; fi
            sg_print '}'
        fi
    } > "$HMG_SEOGAEMO_STATE/usb-wpa.conf"
}

wait_iface() {
    wi_n=0
    while [ ! -d "$net_root/$usb_iface" ]; do
        [ "$wi_n" -lt 10 ] || return 1
        sleep 1
        wi_n=$((wi_n + 1))
    done
}

usb_kmod() {
    uk_adapter=$(usb_adapter) || return 1
    set -f; set -- $uk_adapter; set +f
    sg_write "$2"
}

usb_live() {
    [ "$usb_role" != off ] || return 0
    ul_kmod=$(usb_kmod) || return 0
    sg_kmod_loaded "$ul_kmod" || return 1
    case "$usb_role" in
        client) sg_daemon_running usb-wpa && sg_daemon_running usb-dhcp ;;
        carplay_ap) sg_daemon_running usb-hostapd && sg_daemon_running usb-dnsmasq ;;
    esac
}

# Brings the USB role up; every step is idempotent while it runs. An absent adapter is
# not an error (boot reconcile must not fail): the screen_on watch retries.
usb_apply() {
    [ "$usb_role" != off ] || return 0
    ua_kmod=$(usb_kmod) || { sg_log 'USB Wi-Fi adapter not connected'; return 0; }
    sg_kmod_load "$ua_kmod" || { ua_failed $? "load $ua_kmod"; return $?; }
    wait_iface || { sg_log "no $usb_iface after loading $ua_kmod"; return 1; }
    case "$usb_role" in
        client)
            usb_wpa_conf || { ua_failed $? 'write usb-wpa.conf'; return $?; }
            sg_daemon_start usb-wpa || { ua_failed $? 'start usb-wpa'; return $?; }
            sg_daemon_start usb-dhcp || { ua_failed $? 'start usb-dhcp'; return $?; } ;;
        carplay_ap)
            { ap_credentials && usb_hostapd_conf; } || { ua_failed $? 'write hotspot config'; return $?; }
            # The address also brings rtwlan0 up, which hostapd expects before it starts.
            sg_iface_addr "$usb_iface" "$ap_ip/24" || { ua_failed $? "address $usb_iface"; return $?; }
            sg_daemon_start usb-hostapd || { ua_rc=$?; hostapd_logcat; ua_failed "$ua_rc" 'start usb-hostapd'; return $?; }
            sg_daemon_start usb-dnsmasq || { ua_failed $? 'start usb-dnsmasq'; return $?; }
            sg_net_rule 1 || { ua_failed $? 'add INPUT rule'; return $?; } ;;
    esac
}
# Android hostapd reports to logcat, not to its output; keep its lines beside the daemon logs.
# No -t: it counts unfiltered lines, and this unit logs hundreds per second.
hostapd_logcat() { logcat -d -v time -s hostapd > "$HMG_SEOGAEMO_STATE/daemon.usb-hostapd.logcat.log" 2>/dev/null || :; }
# Logs which USB bring-up step failed (the app only shows a generic failure); returns its code.
ua_failed() {
    sg_log "USB Wi-Fi: $2 failed ($1)" || :
    return "$1"
}

# The CarPlay hotspot for other modules (contract: peer info). ready=stock means Android
# runs the built-in hotspot itself; credentials then come from WifiManager.
publish() {
    if [ "$usb_role" = carplay_ap ]; then
        pb_ready=0
        if usb_kmod >/dev/null && usb_live; then pb_ready=1; fi
        sg_peer_publish radio=usb "interface=$usb_iface" "ip=$ap_ip" "ssid=$(state_value usb-ap ssid)" \
            "passphrase=$(state_value usb-ap pass)" "channel=$ap_channel" "ready=$pb_ready"
    elif [ "$builtin_role" = carplay_ap ]; then
        sg_peer_publish radio=builtin interface=wlan0 ip=192.168.0.1 ssid= passphrase= channel= ready=stock
    else
        sg_peer_publish radio=none interface= ip= ssid= passphrase= channel= ready=0
    fi
}

facts() {
    if wifi_capable; then sg_print info.builtin_present=1; else sg_print info.builtin_present=0; fi
    # No chip on SDIO and no earlier probe result: the app offers the confirmed chip probe.
    if sg_wifi_chip_seen; then sg_print info.chip=seen; else
        case "$(cat "$SG_DATA_ROOT/wifi-chip" 2>/dev/null)" in
            absent) sg_print info.chip=absent ;;
            *) sg_print info.chip=unknown info.chip_unknown=1 ;;
        esac
    fi
    sg_print "info.builtin_role=$builtin_role" "info.usb_role=$usb_role"
    [ "$builtin_role" != client ] || sg_print info.builtin_client=1
    fa_ip=$(client_ip wlan0)
    [ -z "$fa_ip" ] || sg_print "info.client_ip=$fa_ip" "info.client_adb_endpoint=$fa_ip:5555"
    if fa_adapter=$(usb_adapter); then
        set -f; set -- $fa_adapter; set +f
        sg_print info.usb_present=1 "info.usb_id=$1" "info.usb_model=$3"
        [ "$usb_role" != client ] || sg_print info.usb_client=1
        fa_ip=$(client_ip "$usb_iface")
        [ -z "$fa_ip" ] || sg_print "info.usb_ip=$fa_ip"
    else
        sg_print info.usb_present=0
    fi
    if [ "$usb_role" = carplay_ap ] && fa_ssid=$(state_value usb-ap ssid); then
        sg_print "info.ap_ssid=$fa_ssid" "info.ap_ip=$ap_ip"
    fi
}

precheck() {
    compatible
    # The app's plan turns wireless CarPlay off before this module when needed, so only warn.
    one_hotspot "$builtin_role" "$usb_role"
    if [ "$builtin_role" = client ]; then
        wifi_capable || result incompatible none 'Stock Broadcom Wi-Fi capability unavailable'
        unowned_changes
    fi
    if ! hotspot_left "$builtin_role" "$usb_role" && { projection_desired || ap_active; }; then
        sg_print "warn.carplay_active=1"
    fi
    if [ "$usb_role" != off ] && ! usb_adapter >/dev/null; then sg_print "warn.usb_absent=1"; fi
    result off none ''
}

status() {
    facts
    st_builtin=0
    if sg_applied "$xml" && sg_applied "$prop"; then
        pm_wifi || result pending-restart head_unit 'Wi-Fi feature awaits head-unit restart'
        st_builtin=1
    elif sg_applied "$xml" || sg_applied "$prop"; then
        result conflict none 'Wi-Fi client changes are only partly applied'
    else
        # Leftovers only block the built-in client role; the USB roles never touch them.
        if [ "$builtin_role" = client ] && [ -e "$xml" ]; then
            if xml_ours; then result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'; fi
            result conflict none 'Existing Wi-Fi feature XML differs'
        fi
        if [ "$builtin_role" = client ] && [ -n "$(getprop "$prop" 2>/dev/null)" ]; then
            [ "$(getprop "$prop" 2>/dev/null)" != "$value" ] ||
                result conflict none 'Wi-Fi settings left by another package; clean them up in the Car tab'
            result conflict none 'persist.wifi.state is set outside this module'
        fi
        if pm_wifi; then
            # PackageManager drops the removed feature only at the next restart.
            desired_on || sg_print info.desired=off
            result pending-restart head_unit 'Wi-Fi feature awaits removal at restart'
        fi
    fi
    if ! desired_on; then
        [ "$st_builtin" -eq 0 ] || result on none ''
        sg_kmod_loaded 88x2bu || sg_kmod_loaded 8851bu || result off none ''
    fi
    [ "$builtin_role" != client ] || [ "$st_builtin" -eq 1 ] || result off none 'Built-in Wi-Fi client not applied'
    [ "$builtin_role" = client ] || [ "$st_builtin" -eq 0 ] ||
        result conflict none 'Built-in Wi-Fi client is still applied'
    if [ "$usb_role" != off ]; then
        usb_adapter >/dev/null || result on none 'USB Wi-Fi adapter not connected'
        usb_live || result failed none 'USB Wi-Fi is not running'
    fi
    result on none ''
}

usb_failed() {
    uf_code=$1
    # A first enable leaves nothing behind; a running module keeps its built-in role.
    if desired_file_on; then sg_revert_transient || :; else sg_revert_all || :; fi
    publish || :
    case "$uf_code" in
        3) result conflict none 'USB Wi-Fi driver or interface is used by something else' ;;
        4) result incompatible none 'USB Wi-Fi driver does not match this kernel' ;;
        *) result failed none 'Could not bring up USB Wi-Fi' ;;
    esac
}

apply() {
    applying=1
    compatible
    roles_ok "$builtin_role" "$usb_role"
    if [ "$builtin_role" = client ]; then
        wifi_capable || result incompatible none 'Stock Broadcom Wi-Fi capability unavailable'
        unowned_changes
        if ! sg_applied "$xml" || ! sg_applied "$prop"; then
            if sg_applied "$xml" || sg_applied "$prop"; then
                result conflict none 'Wi-Fi client changes are partly applied'
            fi
            sg_file_put "$xml" files/android.hardware.wifi.xml 0644 root:root ||
                result failed none 'Could not apply Wi-Fi feature XML'
            if ! sg_prop_set "$prop" "$value"; then
                sg_revert_all || :
                result failed none 'Could not set persist.wifi.state'
            fi
            if ! sg_applied "$xml" || ! sg_applied "$prop"; then
                result failed none 'Could not verify applied Wi-Fi client changes'
            fi
            sg_log 'built-in Wi-Fi client applied'
        fi
    elif sg_applied "$xml" || sg_applied "$prop"; then
        result conflict none 'Built-in Wi-Fi client is still applied; turn Wi-Fi off first'
    fi
    usb_apply || usb_failed $?
    publish || result failed none 'Could not publish the hotspot'
    # PackageManager may already report the feature (e.g. reapply before a restart).
    status
}

watch() {
    case "$1" in boot|screen_on) ;; *) exit 2 ;; esac
    applying=1
    compatible
    usb_apply || usb_failed $?
    publish || :
    status
}

revert() {
    if ! sg_revert_all; then
        result conflict none 'Wi-Fi changes drifted; baselines retained'
    fi
    sg_peer_publish || :
    if pm_wifi; then
        sg_print info.desired=off
        result pending-restart head_unit 'Wi-Fi feature awaits removal at restart'
    fi
    result off none ''
}

setting_ok() {
    so_builtin=$builtin_role
    so_usb=$usb_role
    case "$1" in
        builtin_role) so_builtin=$2 ;;
        usb_role) so_usb=$2 ;;
        *) exit 2 ;;
    esac
    case "$2" in off|client|carplay_ap) ;; *) exit 2 ;; esac
    roles_ok "$so_builtin" "$so_usb"
    result off none ''
}

# Visible networks of the USB adapter in client role. The unit may have no wpa_cli;
# then only typing a network name works. info.net_<n>=<signal dBm>,<psk|open|wep|eap>,<ssid>
# with the SSID escaped by wpa_cli (\xNN, \\, \").
scan() {
    [ "$usb_role" = client ] || result conflict none 'USB Wi-Fi is not in client mode'
    sg_daemon_running usb-wpa || result failed none 'USB Wi-Fi client is not running'
    if [ ! -f /system/bin/wpa_cli ]; then
        sg_print info.scan=unavailable
        result on none 'This unit cannot list networks'
    fi
    sc_ctrl=$HMG_SEOGAEMO_STATE/wpa
    /system/bin/wpa_cli -p "$sc_ctrl" -i "$usb_iface" scan >/dev/null 2>&1 || :
    sleep 4
    sc_out=$(/system/bin/wpa_cli -p "$sc_ctrl" -i "$usb_iface" scan_results 2>/dev/null) ||
        result failed none 'Could not list networks'
    sc_n=0
    sc_seen=/
    while IFS='	' read -r sc_bssid sc_freq sc_level sc_flags sc_ssid; do
        case "$sc_bssid" in ??:??:??:??:??:??) ;; *) continue ;; esac
        [ -n "$sc_ssid" ] && [ "${#sc_ssid}" -le 180 ] || continue
        case "$sc_seen" in *"/$sc_ssid/"*) continue ;; esac
        sc_seen=$sc_seen$sc_ssid/
        case "$sc_level" in -[0-9]*|[0-9]*) ;; *) sc_level=-100 ;; esac
        case "$sc_flags" in *EAP*) sc_sec=eap ;; *WPA*|*RSN*) sc_sec=psk ;; *WEP*) sc_sec=wep ;; *) sc_sec=open ;; esac
        sc_n=$((sc_n + 1))
        sg_print "info.net_$sc_n=$sc_level,$sc_sec,$sc_ssid"
        [ "$sc_n" -lt 20 ] || break
    done <<EOF
$sc_out
EOF
    sg_print info.scan=ok "info.count=$sc_n"
    result on none "Found $sc_n networks"
}

# Takes the network the app wrote to its fixed inbox file usb-join (ssid=<hex>,
# psk=<64 hex>|none), keeps it in the module state and reconnects the client.
join() {
    [ "$usb_role" = client ] || result conflict none 'USB Wi-Fi is not in client mode'
    jn_file=$inbox/usb-join
    [ -f "$jn_file" ] && [ ! -L "$jn_file" ] || result failed none 'No network request'
    jn_ssid=; jn_psk=
    while IFS='=' read -r jn_key jn_value; do
        case "$jn_key" in ssid) jn_ssid=$jn_value ;; psk) jn_psk=$jn_value ;; esac
    done < "$jn_file"
    case "$jn_ssid" in ''|*[!0-9a-f]*) result failed none 'Invalid network name' ;; esac
    [ "${#jn_ssid}" -le 64 ] && [ $((${#jn_ssid} % 2)) -eq 0 ] || result failed none 'Invalid network name'
    case "$jn_psk" in
        none) ;;
        *[!0-9a-f]*|'') result failed none 'Invalid network key' ;;
        *) [ "${#jn_psk}" -eq 64 ] || result failed none 'Invalid network key' ;;
    esac
    sg_ready || result failed none 'Could not save the network'
    sg_print "ssid=$jn_ssid" "psk=$jn_psk" > "$HMG_SEOGAEMO_STATE/usb-network" ||
        result failed none 'Could not save the network'
    sg_log 'USB Wi-Fi network changed'
    if sg_daemon_running usb-wpa; then
        usb_wpa_conf || result failed none 'Could not save the network'
        sg_daemon_restart usb-wpa && sg_daemon_restart usb-dhcp ||
            result failed none 'Could not reconnect USB Wi-Fi'
    fi
    result on none 'Network saved'
}

# Owner action (after the app's confirmation): wake the built-in Wi-Fi chip once and put the
# switch back. See sg_wifi_probe in the runtime.
probe() {
    compatible
    sg_wifi_probe; pr_rc=$?
    case "$pr_rc" in
        0) result on none 'Wi-Fi chip found' ;;
        10) result on none 'No Wi-Fi chip appeared' ;;
        *) result failed none 'Wi-Fi chip check failed' ;;
    esac
}

case "$#:${1:-}" in
    1:status) status ;;
    1:precheck) precheck ;;
    1:apply) apply ;;
    1:revert) revert ;;
    2:watch) watch "$2" ;;
    3:setting-ok) setting_ok "$2" "$3" ;;
    2:action)
        case "$2" in
            wifi_scan) scan ;;
            wifi_join) join ;;
            wifi_probe) probe ;;
            *) exit 2 ;;
        esac ;;
    *) exit 2 ;;
esac
