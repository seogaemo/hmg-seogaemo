#!/bin/sh
# Wired ADB for a Mac on a USB host port of the head unit.
#
# A Mac attached to a USB host presents Apple's NCM network function. The cable-link
# service (files/cable-link, a transient runtime daemon) speaks NCM through usbfs,
# bridges it to its own TAP interface sgncm0 (192.168.2.249/24 and fe80::c7ad:b) and
# runs files/cable-adbd, whose only listener is bound to that interface on port 5556.
# The stock adbd, its properties and the USB mode are never touched, so nothing
# persistent changes and a head-unit restart alone returns the unit to stock.
#
# The cable adbd accepts only the public keys in <state>/adb_keys. The owner supplies
# them: the import_key action copies HSM/adbkey.pub (the computer's ~/.android/adbkey.pub,
# one key per line) from a USB drive. Keys stay in the module state across off and on.
set -u
. "$HMG_SEOGAEMO_BASE/lib/common.sh"

id=${HMG_SEOGAEMO_STATE##*/}
daemon=cable-link
iface=sgncm0
keys=$HMG_SEOGAEMO_STATE/adb_keys
key_file=HSM/adbkey.pub
max_keys=8
net_root=${SG_SYS_NET_ROOT:-/sys/class/net}
dev_root=${SG_DEV_ROOT:-/dev}
apps_root=${SG_NEMESIS_APPS:-/data/nemesis/apps}
usb_dirs=${SG_USB_DIRS:-/storage/usb0 /storage/usb1 /storage/usb2 /mnt/media_rw/usb0 /mnt/media_rw/usb1 /mnt/media_rw/usb2}
nl='
'

key_count() {
    kc_n=0
    if [ -f "$keys" ] && [ ! -L "$keys" ]; then
        while IFS= read -r kc_line || [ -n "$kc_line" ]; do
            [ -z "$kc_line" ] || kc_n=$((kc_n + 1))
        done < "$keys"
    fi
    sg_write "$kc_n"
}

facts() {
    fa_keys=$(key_count)
    sg_print "info.key_count=$fa_keys"
    if [ "$fa_keys" -gt 0 ]; then sg_print info.has_key=1; else sg_print info.no_key=1; fi
    if [ -d "$net_root/$iface" ]; then
        sg_print info.link=up info.endpoint=192.168.2.249:5556 info.endpoint6=fe80::c7ad:b
    else
        sg_print info.link=waiting
    fi
}

report() {
    if rp_block=$(sg_status "$1" "$2" "$3"); then rp_code=0; else rp_code=$?; fi
    sg_print "$rp_block"
    facts
    exit "$rp_code"
}

desired_on() { [ "$(cat "$SG_DATA_ROOT/desired/$id" 2>/dev/null)" = on ]; }

# The standalone NEMESIS package this module grew out of claims the same USB device and port.
foreign() { [ -d "$apps_root/cn7.mac.cable" ]; }

compatible() {
    if foreign; then report conflict none 'Remove the CN7 Mac USB ADB package first'; fi
    [ "$(getprop ro.build.version.sdk)" = 19 ] && sg_car_mapped ||
        report incompatible none 'Requires Android 4.4 and a car map'
    [ -e "$dev_root/net/tun" ] || [ -e "$dev_root/tun" ] ||
        report incompatible none 'This unit has no TUN device'
    for cp_file in files/cable-link files/cable-adbd; do
        sg_payload "$cp_file" || report failed none "Missing payload $cp_file"
    done
}

running_report() {
    if [ "$(key_count)" -eq 0 ]; then
        report on none 'Import an ADB key from USB to connect'
    elif [ -d "$net_root/$iface" ]; then
        report on none 'Mac connected; ADB on port 5556'
    fi
    report on none 'Waiting for a Mac on the USB port'
}

status() {
    compatible
    if sg_daemon_running "$daemon"; then running_report; fi
    if desired_on; then report failed none 'Cable link is not running'; fi
    report off none 'Wired ADB is off'
}

launch() {
    sg_daemon_start "$daemon" && return 0
    la_code=$?
    sg_log "cable link did not come up ($la_code)" || :
    sg_revert_transient || :
    if [ "$la_code" -eq 3 ]; then report conflict none 'Another module claims the cable link'; fi
    report failed none 'Could not start the cable link'
}

apply() {
    compatible
    launch
    sg_log 'Wired ADB applied' || :
    running_report
}

revert() {
    sg_revert_all || report conflict none 'Could not stop the cable link'
    sg_log 'Wired ADB stopped' || :
    report off none 'Wired ADB is off'
}

watch() {
    case "$1" in boot|screen_on) ;; *) exit 2 ;; esac
    compatible
    launch
    running_report
}

# A live link keeps the keys its adbd read at start; restart to use the new file.
reload() {
    if sg_daemon_running "$daemon"; then
        sg_daemon_restart "$daemon" || report failed none 'Could not restart the cable link'
    fi
}

# Copies the keys of HSM/adbkey.pub on a USB drive into the module state. A key is the
# 700 base64 characters of adb's RSA-2048 public key structure; an optional user@host
# label is kept when it is plain. The whole file is checked before anything is written,
# and nothing but validated text reaches the state file.
import_key() {
    compatible
    umask 077
    sg_ready || report failed none 'Could not prepare the module state'
    ik_src=
    for ik_drive in $usb_dirs; do
        if [ -f "$ik_drive/$key_file" ] && [ ! -L "$ik_drive/$key_file" ]; then
            ik_src=$ik_drive/$key_file
            break
        fi
    done
    [ -n "$ik_src" ] || report failed none 'No HSM/adbkey.pub on a USB drive'
    ik_size=$(sg_file_size "$ik_src") || report failed none 'Could not read the key file'
    [ "$ik_size" -le 8192 ] || report failed none 'Key file is too large'
    ik_n=0
    ik_text=
    while IFS= read -r ik_line || [ -n "$ik_line" ]; do
        # Intentional field split on blanks; globbing is switched off only for the split.
        set -f; set -- $ik_line; set +f
        [ "$#" -gt 0 ] || continue
        ik_key=$1
        if [ "${#ik_key}" -eq 701 ]; then
            # A Windows line ending leaves one extra byte on a key without a label.
            case "${ik_key#"${ik_key%?}"}" in [A-Za-z0-9+/=]) report failed none 'Invalid ADB public key' ;; esac
            ik_key=${ik_key%?}
        fi
        case "$ik_key" in *[!A-Za-z0-9+/=]*) report failed none 'Invalid ADB public key' ;; esac
        [ "${#ik_key}" -eq 700 ] || report failed none 'Invalid ADB public key'
        ik_n=$((ik_n + 1))
        [ "$ik_n" -le "$max_keys" ] || report failed none 'Too many keys; 8 at most'
        ik_label=
        if [ "$#" -ge 2 ] && [ "${#2}" -le 64 ]; then
            case "$2" in *[!A-Za-z0-9@._-]*) ;; *) ik_label=" $2" ;; esac
        fi
        ik_text=$ik_text$ik_key$ik_label$nl
    done < "$ik_src"
    [ "$ik_n" -gt 0 ] || report failed none 'No ADB public key in the file'
    sg_write "$ik_text" > "$HMG_SEOGAEMO_STATE/adb_keys" || report failed none 'Could not save the keys'
    sg_log "ADB keys imported: $ik_n" || :
    reload
    report on none "ADB keys imported: $ik_n"
}

# An empty file holds no key; the cable link then waits for the next import.
clear_key() {
    umask 077
    sg_ready || report failed none 'Could not prepare the module state'
    : > "$HMG_SEOGAEMO_STATE/adb_keys" || report failed none 'Could not remove the keys'
    sg_log 'ADB keys removed' || :
    reload
    report on none 'ADB keys removed'
}

case "$#:${1:-}" in
    1:status) status ;;
    1:precheck) status ;;
    1:apply) apply ;;
    1:revert) revert ;;
    2:watch) watch "$2" ;;
    2:action)
        case "$2" in
            import_key) import_key ;;
            clear_key) clear_key ;;
            *) exit 2 ;;
        esac ;;
    *) exit 2 ;;
esac
