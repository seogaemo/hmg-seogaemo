#!/bin/sh
set -eu
# The package runtime supplies this file at a fixed path.
# shellcheck disable=SC1091
. "$HMG_SEOGAEMO_BASE/lib/common.sh"

STOCK_PROP=persist.service.adb.tcp.enable
PORT_PROP=persist.adb.tcp.port

wa_compatible() {
    [ "$(getprop ro.build.version.sdk)" = 19 ] || return 1
    sg_car_mapped
}

wa_owners_clear() {
    for owner in nemesis-adb-tcp hmgapi leafia; do
        if sg_owner_present "$owner"; then
            WA_CONFLICT="$owner owns ADB properties"
            return 1
        fi
    done
    return 0
}

# adbd checks the transient override before the persistent TCP port.
wa_effective_port() {
    value=$(getprop service.adb.tcp.port)
    if [ -z "$value" ]; then value=$(getprop "$PORT_PROP"); fi
    sg_write "$value"
}

# /proc tables identify the local port and TCP LISTEN state, without text tools.
# Unknown (unreadable tables) is distinct from a verified absent listener.
wa_listener() {
    readable=0
    for table in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$table" ] || continue
        readable=1
        while read -r slot local remote tcp_state rest; do
            case "$local:$tcp_state" in *:15B3:0A|*:15b3:0A) return 0;; esac
        done < "$table"
    done
    [ "$readable" -eq 1 ] || return 2
    return 1
}

wa_ipv4() {
    case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
    old_ifs=$IFS
    IFS=.
    # Intentional field split on dots; globbing is switched off only for the split.
    # shellcheck disable=SC2086
    set -f; set -- $1; set +f
    IFS=$old_ifs
    [ "$#" -eq 4 ] || return 1
    for octet do
        case "$octet" in ''|*[!0-9]*|????*) return 1 ;; esac
        [ "$octet" -le 255 ] || return 1
    done
}

wa_ifconfig_ip() {
    ifconfig "$1" 2>/dev/null | {
        while IFS= read -r line; do
            # Intentional splitting into ifconfig fields; globbing is switched off only for the split.
            # shellcheck disable=SC2086
            set -f; set -- $line; set +f
            next=0
            for token do
                if [ "$next" -eq 1 ]; then
                    candidate=${token#addr:}
                    candidate=${candidate%%/*}
                    if wa_ipv4 "$candidate"; then sg_write "$candidate"; return 0; fi
                    next=0
                fi
                case "$token" in
                    inet) next=1 ;;
                    addr:*)
                        candidate=${token#addr:}
                        candidate=${candidate%%/*}
                        if wa_ipv4 "$candidate"; then sg_write "$candidate"; return 0; fi
                        ;;
                esac
            done
        done
        return 1
    }
}

wa_netcfg_ip() {
    netcfg 2>/dev/null | while read -r name _state address rest; do
        [ "$name" = "$1" ] || continue
        candidate=${address%%/*}
        if wa_ipv4 "$candidate"; then sg_write "$candidate"; return 0; fi
    done
}

wa_iface_ip() {
    wa_ifconfig_ip "$1" || wa_netcfg_ip "$1"
}

wa_old_eth_address() {
    address=$(wa_iface_ip eth0) || return 1
    [ "$address" = 192.168.0.123 ]
}

wa_facts() {
    sg_print "info.effective_port=$(wa_effective_port)" "info.adbd_state=$(getprop init.svc.adbd)"
    if wa_listener; then listener=listening
    else listener_code=$?; listener=unknown; [ "$listener_code" -ne 1 ] || listener=absent; fi
    sg_print "info.adb_listener=$listener"
    # KitKat softap.conf is binary; omitting this key renders the UI fallback.
    wlan_ip=$(wa_iface_ip wlan0) || wlan_ip=
    if [ -n "$wlan_ip" ]; then
        if [ "$wlan_ip" = 192.168.0.1 ] || [ "$(getprop init.svc.hostapd)" = running ]; then
            sg_print "info.hotspot_ip=$wlan_ip" "info.adb_endpoint=$wlan_ip:5555"
        else
            sg_print "info.client_ip=$wlan_ip" "info.client_adb_endpoint=$wlan_ip:5555"
        fi
    fi
}

wa_report() {
    if block=$(sg_status "$1" "$2" "$3"); then code=0; else code=$?; fi
    sg_print "$block"
    wa_facts
    return "$code"
}

wa_observed() {
    [ "$(getprop "$STOCK_PROP")" = 0 ] && [ "$(getprop "$PORT_PROP")" = 5555 ]
}

wa_status() {
    if ! wa_owners_clear; then wa_report conflict none "$WA_CONFLICT"; return $?; fi
    if ! wa_compatible; then
        wa_report incompatible none 'Requires Android 4.4 and a verified car map'; return $?
    fi
    stock_applied=0
    port_applied=0
    if sg_applied "$STOCK_PROP"; then stock_applied=1; fi
    if sg_applied "$PORT_PROP"; then port_applied=1; fi
    if [ "$stock_applied" -eq 1 ] && [ "$port_applied" -eq 1 ]; then
        if ! wa_observed; then
            wa_report conflict none 'ADB properties changed outside HMG-Seogaemo'; return $?
        fi
        if [ "$(wa_effective_port)" != 5555 ]; then
            wa_report conflict none 'ADB configured; service.adb.tcp.port overrides port 5555'
        elif [ "$(getprop init.svc.adbd)" != running ]; then
            wa_report failed none 'ADB configured; adbd stopped or not running'
        elif wa_listener; then
            if wa_old_eth_address; then
                wa_report pending-restart head_unit 'Restart head unit to clear old eth0 address'
            else
                wa_report on adbd 'TCP ADB listening on port 5555; adbd running; stock switch off'
            fi
        elif [ "$?" -eq 1 ]; then
            wa_report failed none 'ADB configured; adbd is not listening on port 5555'
        elif wa_old_eth_address; then
            wa_report pending-restart head_unit 'Restart head unit to clear old eth0 address'
        else
            wa_report on adbd 'TCP ADB configured on port 5555; adbd running; stock switch off'
        fi
    elif [ "$stock_applied" -eq 1 ] || [ "$port_applied" -eq 1 ]; then
        wa_report failed none 'ADB properties only partly applied'
    else
        wa_report off none 'Wireless ADB is off'
    fi
}

wa_apply_failed() {
    reason=$1
    current=$(wa_effective_port)
    if sg_revert_all; then
        restored=$(wa_effective_port)
        if [ "$current" != "$restored" ]; then
            sg_service_restart adbd || reason="$reason; adbd restore restart failed"
        fi
        wa_report failed none "$reason"
    else
        restore_code=$?
        if [ "$restore_code" -eq 3 ]; then
            wa_report conflict none 'ADB properties changed outside HMG-Seogaemo; baseline kept'
        else
            wa_report failed none "$reason; baseline restore failed"
        fi
    fi
}

wa_apply() {
    if ! wa_owners_clear; then wa_report conflict none "$WA_CONFLICT"; return $?; fi
    if ! wa_compatible; then
        wa_report incompatible none 'Requires Android 4.4 and a verified car map'; return $?
    fi
    override=$(getprop service.adb.tcp.port)
    if [ -n "$override" ] && [ "$override" != 5555 ]; then
        wa_report conflict none 'service.adb.tcp.port overrides port 5555'; return $?
    fi
    before=$(wa_effective_port)
    if ! sg_prop_set "$STOCK_PROP" 0 || ! sg_prop_set "$PORT_PROP" 5555 || ! wa_observed; then
        wa_apply_failed 'Could not apply ADB properties'; return $?
    fi
    after=$(wa_effective_port)
    listener_missing=0
    if wa_listener; then :; else [ "$?" -ne 1 ] || listener_missing=1; fi
    if [ "$before" != "$after" ] || [ "$(getprop init.svc.adbd)" != running ] || [ "$listener_missing" -eq 1 ]; then
        if ! sg_service_restart adbd; then
            wa_apply_failed 'Could not restart adbd'; return $?
        fi
        # init starts asynchronously; allow the listener to appear after restart.
        attempts=0
        while ! wa_listener; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 5 ] || break
            sleep 1
        done
    fi
    sg_log 'Wireless ADB applied'
    wa_status
}

wa_revert() {
    if ! wa_owners_clear; then wa_report conflict none "$WA_CONFLICT"; return $?; fi
    before=$(wa_effective_port)
    if sg_revert_all; then :; else
        restore_code=$?
        if [ "$restore_code" -eq 3 ]; then
            wa_report conflict none 'ADB properties changed outside HMG-Seogaemo; baseline kept'
        else
            wa_report failed none 'Could not restore ADB property baseline'
        fi
        return $?
    fi
    after=$(wa_effective_port)
    if [ "$before" != "$after" ] && ! sg_service_restart adbd; then
        wa_report failed none 'Could not restart adbd after restore'; return $?
    fi
    sg_log 'Wireless ADB restored'
    wa_status
}

if [ "$#" -ne 1 ]; then
    echo 'usage: wireless-adb.sh apply|revert|status|precheck' >&2
    exit 2
fi
case "$1" in
    apply) wa_apply ;;
    revert) wa_revert ;;
    status) wa_status ;;
    precheck) wa_status ;;
    *) echo 'usage: wireless-adb.sh apply|revert|status|precheck' >&2; exit 2 ;;
esac
