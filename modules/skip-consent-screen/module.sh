#!/system/bin/sh
set -u
. "$HMG_SEOGAEMO_BASE/lib/common.sh"

framework=${SG_SKIP_CONSENT_FRAMEWORK:-/system/framework/framework.odex}

result() { sg_status "$1" "$2" "$3"; exit $?; }
desired_on() { [ "$(cat "$SG_DATA_ROOT/desired/skip-consent-screen" 2>/dev/null)" = on ]; }
compatible() {
    [ "$(getprop ro.build.version.sdk)" = 19 ] || return 1
    car=$(sg_car_map) || return 1
    [ -f "$framework" ] || return 1
    set -- $(md5 "$framework" 2>/dev/null)
    # framework.odex must be the stock build this car's map was made from.
    grep -Fq -e "\"/system/framework/framework.odex\": \"${1:-}\"" \
        -e "\"/system/framework/framework.odex\":\"${1:-}\"" "$car"
}
owner_clear() { ! sg_owner_present local-hkmc-factory82; }
status() {
    if desired_on; then
        if sg_service_call_ok_this_boot; then result on none 'Factory call completed this boot; verify notice on car'; fi
        if sg_service_call_this_boot; then result pending-restart head_unit 'Factory call failed; inspect ledger'; fi
        result pending-restart head_unit 'Restart head unit to activate startup notice skip'
    fi
    if sg_service_call_this_boot; then
        sg_print "info.desired=off"
        result pending-restart head_unit 'Restart head unit to restore the stock startup notice'
    fi
    result off none 'Stock startup notice enabled'
}
precheck() {
    if ! owner_clear; then result conflict none 'Uninstall local.hkmc.factory82 first'; fi
    if ! compatible; then result incompatible none 'No car map for this firmware, or framework.odex is not its stock build'; fi
    result off none 'Restart required after enabling and disabling'
}
apply() {
    if ! owner_clear; then result conflict none 'Uninstall local.hkmc.factory82 first'; fi
    if ! compatible; then result incompatible none 'No car map for this firmware, or framework.odex is not its stock build'; fi
    result pending-restart head_unit 'Restart head unit to activate startup notice skip'
}
revert() {
    if sg_service_call_this_boot; then
        sg_print "info.desired=off"
        result pending-restart head_unit 'Restart head unit to restore the stock startup notice'
    fi
    result off none 'Stock startup notice enabled'
}
boot_ready() {
    attempts=0
    while [ "$(getprop sys.boot_completed)" != 1 ]; do
        [ "$attempts" -lt 10 ] || return 1
        sleep 1
        attempts=$((attempts + 1))
    done
}
factory_ready() {
    attempts=0
    while [ "$attempts" -lt 20 ]; do
        response=$("${HMG_SEOGAEMO_SERVICE_BIN:-/system/bin/service}" check com.hkmc.factory 2>&1) || response= # android44-shell: allow -- service binary defaults to /system/bin/service; override is a host-test seam
        case "$response" in *'com.hkmc.factory: found'*) return 0;; esac
        sleep 1
        attempts=$((attempts + 1))
    done
    return 1
}
watch() {
    case "$1" in boot|screen_on) ;; *) exit 2;; esac
    desired_on || exit 3
    owner_clear || result conflict none 'Uninstall local.hkmc.factory82 first'
    compatible || result incompatible none 'No car map for this firmware, or framework.odex is not its stock build'
    if [ "$1" = boot ] && sg_service_call_ok_this_boot; then result on none 'Already called this boot'; fi
    boot_ready || result failed none 'Android boot did not complete'
    factory_ready || result failed none 'Factory Binder service unavailable'
    sg_service_call com.hkmc.factory 82
    call_code=$?
    case "$SG_SERVICE_CALL_RESPONSE" in
        *'Cannot broadcast before boot completed'*|*'fffffffb 00000026 00610043'*)
            boot_ready || result failed none 'Factory call ran before Android boot completed'
            sleep 1
            sg_service_call com.hkmc.factory 82 || result failed none 'Factory Binder retry failed'
            ;;
        *) [ "$call_code" -eq 0 ] || result failed none 'Factory Binder call failed' ;;
    esac
    result on none 'Factory Binder call recorded; verify screen on car'
}

[ "$#" -ge 1 ] || exit 2
case "$1" in
    status) [ "$#" -eq 1 ] || exit 2; status ;;
    precheck) [ "$#" -eq 1 ] || exit 2; precheck ;;
    apply) [ "$#" -eq 1 ] || exit 2; apply ;;
    revert) [ "$#" -eq 1 ] || exit 2; revert ;;
    watch) [ "$#" -eq 2 ] || exit 2; watch "$2" ;;
    *) exit 2 ;;
esac
