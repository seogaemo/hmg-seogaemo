#!/bin/sh
# Module-local fake-root test. No host firmware paths are touched.
set -eu
HERE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
car_shell=${HMG_SEOGAEMO_TEST_SHELL:-$(command -v mksh || command -v sh)}
export TEST_CAR_SHELL=$car_shell
export HMG_SEOGAEMO_TEST_COMMON="$HERE/../../nemesis/package/lib/common.sh"
. "$HMG_SEOGAEMO_TEST_COMMON"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SG_WIRELESS_TEST_ROOT=$T/root HMG_SEOGAEMO_BASE=$T/base HMG_SEOGAEMO_STATE=$T/state HMG_SEOGAEMO_MODULE_DIR=$HERE
export TEST_PROPS=$T/props TEST_STATE=$T/state SG_DATA_ROOT=/data/nemesis/backup/hmg-seogaemo
HOOK=$T/root$SG_DATA_ROOT/core/hook/mods/state
mkdir -p "$T/base/lib" "$T/bin" "$T/props" "$T/state" "$T/root/system/bin" "$T/root/system/app" "$T/root/system/framework" "$T/root/system/onebin/neev_kr" "$T/root/system/etc/permissions" "$T/root/proc/sys/kernel/random"
cat > "$T/base/lib/common.sh" <<'SH'
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_log() { sg_print "$*" >&2; }
sg_projection_runtime() {
    case "$1" in
        prepare) mkdir -p "$HMG_SEOGAEMO_STATE/runtime"; chmod 700 "$HMG_SEOGAEMO_STATE/runtime";;
        clear) rm -rf "$HMG_SEOGAEMO_STATE/runtime";;
        status|applying)
            if [ -f "$HMG_SEOGAEMO_STATE/runtime/ready" ]; then sg_status on none 'validated runtime ready'
            elif [ "$1" = applying ]; then sg_status pending-restart head_unit 'runtime evidence absent'
            else sg_print state=unknown restart=none 'detail=runtime evidence absent'; fi;;
        tbt-reset) sg_print state=on restart=none 'detail=records reset';;
        *) return 2;;
    esac
}
sg_payload_dirs() {
    case "$1" in /system/*) ;; *) return 0;; esac
    parent=$(sg_path "$1"); parent=${parent%/*}
    while [ "$parent" != "$SG_WIRELESS_TEST_ROOT" ]; do
        mkdir -p "$parent"; chmod 0755 "$parent"; parent=${parent%/*}
    done
    # Simulate interruption after traversal is repaired but before file puts.
    [ "${SG_FAIL_AFTER_DIR_REPAIR:-0}" != 1 ] || return 1
}
sg_restart_required() {
    [ "${SG_FAIL_RESTART_MARKER:-0}" != 1 ] || return 1
    cat "$SG_WIRELESS_TEST_ROOT/proc/sys/kernel/random/boot_id" > "$HMG_SEOGAEMO_STATE/assets-repaired-boot"
}
sg_restart_pending() {
    [ -f "$HMG_SEOGAEMO_STATE/assets-repaired-boot" ] &&
        [ "$(cat "$HMG_SEOGAEMO_STATE/assets-repaired-boot")" = "$(cat "$SG_WIRELESS_TEST_ROOT/proc/sys/kernel/random/boot_id")" ]
}
sg_public_readable() (
    SG_TARGET_ROOT=$SG_WIRELESS_TEST_ROOT
    target=$1
    [ -f "$target" ] || exit 1
    set -- $(sg_file_meta "$target")
    case "$1" in *[4567]) ;; *) exit 1;; esac
    parent=${target%/*}
    while [ "$parent" != "$SG_TARGET_ROOT" ]; do
        set -- $(sg_file_meta "$parent")
        case "$1" in *[1357]) ;; *) exit 1;; esac
        parent=${parent%/*}
    done
)
sg_path() { case "$1" in "$HMG_SEOGAEMO_STATE"/*) sg_print "$1";; *) sg_print "$SG_WIRELESS_TEST_ROOT$1";; esac; }
sg_key() { sg_print "$HMG_SEOGAEMO_STATE/$2$1"; }
sg_file_baseline() {
    key=$(sg_key "$1" baseline)
    [ ! -e "$key.present" ] || return 0
    mkdir -p "${key%/*}"
    if [ -f "$(sg_path "$1")" ]; then cp -p "$(sg_path "$1")" "$key"; fi
    touch "$key.present"
}
sg_file_mark_applied() {
    key=$(sg_key "$1" applied)
    mkdir -p "${key%/*}"
    if [ -f "$(sg_path "$1")" ]; then cp -p "$(sg_path "$1")" "$key"; else rm -f "$key"; fi
    touch "$key.present"
}
sg_applied() {
    key=$(sg_key "$1" applied); current=$(sg_path "$1")
    [ -f "$key.present" ] || return 1
    if [ -f "$key" ]; then [ -f "$current" ] && cmp -s "$key" "$current"; else [ ! -f "$current" ]; fi
}
sg_file_restore() {
    key=$(sg_key "$1" baseline); current=$(sg_path "$1")
    [ -f "$key.present" ] || return 1
    if [ -f "$key" ]; then mkdir -p "${current%/*}"; cp -p "$key" "$current"; else rm -f "$current"; fi
}
sg_file_put() {
    target=$1 source=$2
    sg_file_baseline "$target"
    dest=$(sg_path "$target"); mkdir -p "${dest%/*}"
    cp "$HMG_SEOGAEMO_MODULE_DIR/$source" "$dest"
    sg_payload_dirs "$target"; chmod "${3:-644}" "$dest"
    sg_file_mark_applied "$target"
    sg_print "file $target" >> "$HMG_SEOGAEMO_STATE/ops.list"
}
sg_file_replace_line() {
    target=$1 old=$2 new=$3
    sg_file_baseline "$target"
    dest=$(sg_path "$target")
    [ "$(grep -Fxc -e "$old" "$dest" || :)" = 1 ] || return 1
    awk -v o="$old" -v n="$new" '{if ($0 == o) print n; else print}' "$dest" > "$dest.next"
    mv "$dest.next" "$dest"
    sg_file_mark_applied "$target"
    sg_print "file $target" >> "$HMG_SEOGAEMO_STATE/ops.list"
}
sg_prop_set() {
    key=$1; val=$2
    if [ ! -f "$HMG_SEOGAEMO_STATE/prop-baseline/$key.present" ]; then
        mkdir -p "$HMG_SEOGAEMO_STATE/prop-baseline"
        getprop "$key" > "$HMG_SEOGAEMO_STATE/prop-baseline/$key"
        touch "$HMG_SEOGAEMO_STATE/prop-baseline/$key.present"
    fi
    setprop "$key" "$val"
    sg_write "$val" > "$HMG_SEOGAEMO_STATE/prop-applied-$key"
    sg_print "prop $key" >> "$HMG_SEOGAEMO_STATE/ops.list"
}
sg_restore_material() { [ -f "$HMG_SEOGAEMO_STATE/ops.list" ]; }
# The core hook host itself is exercised by tools/test-runtime.py; here only the wiring.
sg_hook_register() {
    jar=$1; dir=$SG_DATA_ROOT/core/hook/mods/${HMG_SEOGAEMO_STATE##*/}
    sg_print "$2" > "$HMG_SEOGAEMO_STATE/hook-entry"
    sg_file_put "$dir/hook.jar" "$jar" 600 0:0 && sg_file_put "$dir/entry" test/enable-marker 600 0:0
}
sg_core_hook_ensure() {
    [ -d "$HMG_SEOGAEMO_STATE/runtime" ] || return 1
    [ "${SG_FAIL_ZYGOTE:-0}" != 1 ] || return 1
    touch "$HMG_SEOGAEMO_STATE/core-hook"
}
sg_owned_dirs_prune() { for d in "$@"; do rmdir "$SG_WIRELESS_TEST_ROOT$d" 2>/dev/null || :; done; }
sg_core_hook_owned() { [ -f "$HMG_SEOGAEMO_STATE/core-hook" ]; }
sg_core_hook_release() {
    ! sg_applied "$SG_DATA_ROOT/core/hook/mods/${HMG_SEOGAEMO_STATE##*/}/entry" || return 0
    rm -f "$HMG_SEOGAEMO_STATE/core-hook"
}
# Before the core hook host the module installed its own wrapper (package update input).
sg_legacy_install() {
    sg_prop_set persist.ium.support carplay
    stock=/system/bin/app_process.hmg-seogaemo-stock
    sg_file_baseline "$stock"; cp "$(sg_path /system/bin/app_process)" "$(sg_path "$stock")"
    sg_file_mark_applied "$stock"; sg_print "file $stock" >> "$HMG_SEOGAEMO_STATE/ops.list"
    sg_file_put /system/bin/app_process test/enable-marker 755 0:0
    sg_file_put /system/lib/libhmg_seogaemo_wireless_hook.so test/enable-marker 644 0:0
    sg_file_put /system/framework/hmg-seogaemo-wireless-hook.jar test/enable-marker 644 0:0
}
sg_revert_all() {
    [ -f "$HMG_SEOGAEMO_STATE/ops.list" ] || return 0
    while read -r kind target; do
        if [ "$kind" = file ]; then sg_applied "$target" || return 1
        else [ "$(getprop "$target")" = "$(cat "$HMG_SEOGAEMO_STATE/prop-applied-$target")" ] || return 1; fi
    done < "$HMG_SEOGAEMO_STATE/ops.list"
    awk '{a[NR]=$0} END {for (i=NR;i>=1;i--) print a[i]}' "$HMG_SEOGAEMO_STATE/ops.list" | while read -r kind target; do
        if [ "$kind" = file ]; then sg_file_restore "$target" || exit 1
        else setprop "$target" "$(cat "$HMG_SEOGAEMO_STATE/prop-baseline/$target")" || exit 1; fi
    done || return 1
    rm -rf "$HMG_SEOGAEMO_STATE/baseline" "$HMG_SEOGAEMO_STATE/applied" "$HMG_SEOGAEMO_STATE/prop-baseline" "$HMG_SEOGAEMO_STATE"/prop-applied-* "$HMG_SEOGAEMO_STATE/ops.list" "$HMG_SEOGAEMO_STATE/dex-track"
}
sg_owner_present() { [ -f "$HMG_SEOGAEMO_STATE/owner-$1" ]; }
# The real guard is exercised by tools/test-runtime.py; here only the wiring.
sg_zygote_foreign() {
    [ ! -f "$HMG_SEOGAEMO_STATE/foreign" ] && return 0
    sg_print info.restore_conflict=foreign
    return 3
}
# Stale wrapper guard state handling is exercised by tools/test-runtime.py.
sg_zygote_guard_sweep() { [ ! -f "$HMG_SEOGAEMO_STATE/guard-sweep-fails" ]; }
# The real peer reader, on the fake root's data directory. A fresh shell avoids
# loading common.sh twice in one process (about a second each under mksh R59).
sg_peer_info() {
    SG_DATA_ROOT=$SG_WIRELESS_TEST_ROOT$SG_DATA_ROOT "$TEST_CAR_SHELL" -c '. "$1"; shift; sg_peer_info "$@"' \
        sh "$HMG_SEOGAEMO_TEST_COMMON" "$@"
}
sg_status() { sg_print "state=$1" "restart=$2" "detail=${3:-}"; case "$1" in conflict) return 3;; incompatible) return 4;; failed) return 1;; esac; }
SH
cat > "$T/bin/getprop" <<'SH'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
[ -f "$TEST_PROPS/$1" ] && cat "$TEST_PROPS/$1" || :
SH
cat > "$T/bin/setprop" <<'SH'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_write "$2" > "$TEST_PROPS/$1"
SH
mkdir -p "$T/base/bin"
cat > "$T/base/bin/hmg-seogaemo-root" <<'SH'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
[ "$1" = map ] && [ "$2" = status ] || exit 2
[ "$(cat "$TEST_PROPS/ro.build.product")" = NEEV.KOR.0000.V039.001.260902 ] &&
    [ ! -f "$TEST_STATE/map-off" ] || { sg_print "state=incompatible"; exit 4; }
sg_print "state=on"
SH
chmod 644 "$T/base/bin/hmg-seogaemo-root"
chmod +x "$T/bin"/*
export PATH=$T/bin:$PATH
sg_write "NEEV.KOR.0000.V039.001.260902" > "$T/props/ro.build.product"
sg_write "neev_kr" > "$T/props/ro.mobis.onebindir"
sg_write "4.4.2" > "$T/props/ro.build.version.release"
sg_write "stock" > "$T/props/persist.ium.support"
sg_write "old" > "$T/props/persist.sys.iap2.wifi"
sg_write "old" > "$T/props/persist.iap2.iden.wireless"
sg_write "0" > "$T/props/persist.service.adb.tcp.enable"
for name in framework.odex HKMC_DiPO.odex Iap2ServerApp.odex HKMC_GPM.odex; do
    case "$name" in framework.odex) dir=framework;; *) dir=app;; esac
    sg_print "stock-$name" > "$T/root/system/$dir/$name"
done
sg_print "stock-app-process" > "$T/root/system/bin/app_process"
sg_print "boot-one" > "$T/root/proc/sys/kernel/random/boot_id"
sg_print '-/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml' '-/system/etc/permissions/com.hkmc.software.connectivity.androidauto_wireless.xml' '-/system/etc/permissions/com.hkmc.software.wifihotspot.xml' > "$T/root/system/onebin/neev_kr/featurexml.cfg"
SCRIPT=$T/wireless-carplay-and-aa.sh
sed "s|/system/bin/sh|$car_shell|g" "$HERE/module.sh" > "$SCRIPT"
run() { "$car_shell" "$SCRIPT" "$@" > "$T/output"; }
fail() { echo "FAIL: $1" >&2; cat "$T/output" >&2; exit 1; }
# The zygote starts seconds after boot, before this boot's map verification can finish,
# so the hook gate must not depend on the boot ID (the car-map seal's third line).
if grep -q 'boot_id' "$HERE/../../core/hook/src/hmgapi/hook/HmgApi.java"; then fail 'zygote hook gate must not require the boot id'; fi
sg_write "OTHER.KOR.0000.V039.001.260902" > "$T/props/ro.build.product"
run precheck && fail wrong-firmware-accepted
grep -q '^state=incompatible$' "$T/output" || fail firmware-state
sg_write "NEEV.KOR.0000.V039.001.260902" > "$T/props/ro.build.product"
sg_write "wrong_onebin" > "$T/props/ro.mobis.onebindir"
run precheck && fail wrong-onebin-accepted
grep -q '^state=incompatible$' "$T/output" || fail onebin-state
sg_write "neev_kr" > "$T/props/ro.mobis.onebindir"
touch "$T/state/map-off"
run precheck && fail unverified-map-accepted
grep -q '^state=incompatible$' "$T/output" || fail unverified-map-state
rm -f "$T/state/map-off"
touch "$T/state/owner-hmgapi"
run precheck && fail owner-accepted
grep -q '^state=conflict$' "$T/output" || fail owner-state
rm -f "$T/state/owner-hmgapi"
# featurexml.cfg lives under the firmware's own onebin directory, not a fixed neev_kr path.
sg_write "ne1_kr" > "$T/props/ro.mobis.onebindir"
mkdir -p "$T/root/system/onebin/ne1_kr"
cp "$T/root/system/onebin/neev_kr/featurexml.cfg" "$T/root/system/onebin/ne1_kr/featurexml.cfg"
run precheck || fail other-onebin
grep -q '^state=off$' "$T/output" || fail other-onebin-state
rm -rf "$T/root/system/onebin/ne1_kr"
sg_write "ne1/kr" > "$T/props/ro.mobis.onebindir"
run precheck && fail unusable-onebin-accepted
grep -q '^detail=unsupported onebin$' "$T/output" || fail unusable-onebin-detail
sg_write "neev_kr" > "$T/props/ro.mobis.onebindir"
run precheck || fail precheck
grep -q '^state=off$' "$T/output" || fail precheck-state
# The CarPlay hotspot the wifi module publishes (peer info), read-only, and its built-in client conflict.
DATA=$T/root$SG_DATA_ROOT
publish() { mkdir -p "$DATA/peer"; sg_print "$@" > "$DATA/peer/wifi"; }
wifi_set() { mkdir -p "$DATA/settings/wifi"; sg_write "$2" > "$DATA/settings/wifi/$1"; }
radio() { run status || fail "hotspot-status-$2"; grep -q "^info.hotspot_radio=$1\$" "$T/output" || fail "hotspot-radio-$2"; }
radio none no-stock-radio
sg_write broadcom > "$T/props/tcc.wifi.vendor"
mkdir -p "$T/root/system/wifi"
sg_print ko > "$T/root/system/wifi/bcmdhd.ko"; sg_print fw > "$T/root/system/wifi/fw_bcmdhd.bin"
radio builtin stock-radio
publish radio=usb interface=rtwlan0 ip=192.168.50.1 ssid=HMG-Seogaemo-6f1d passphrase=secret-pass-1 channel=36 ready=1
radio usb usb-published
grep -q 'secret-pass-1' "$T/output" && fail passphrase-in-status
publish radio=none interface= ip= ssid= passphrase= channel= ready=0
radio none builtin-client
wifi_set builtin_role off
radio builtin builtin-unused
publish radio=builtin interface=wlan0 ip=192.168.0.1 ssid= passphrase= channel= ready=stock
radio builtin builtin-published
# wifi on, built-in client, no USB hotspot: precheck warns (the app plan turns wifi off first), apply refuses.
mkdir -p "$DATA/desired"; sg_write on > "$DATA/desired/wifi"
wifi_set builtin_role client
publish radio=none interface= ip= ssid= passphrase= channel= ready=0
run precheck || fail client-precheck
grep -q '^warn.wifi_client=1$' "$T/output" && grep -q '^state=off$' "$T/output" || fail client-precheck-warning
run apply && fail client-apply-accepted
grep -q '^state=conflict$' "$T/output" && grep -q 'needs a hotspot' "$T/output" || fail client-apply-state
[ ! -e "$T/state/ops.list" ] && [ "$(cat "$T/props/persist.ium.support")" = stock ] || fail client-apply-mutated
wifi_set usb_role carplay_ap
publish radio=usb interface=rtwlan0 ip=192.168.50.1 ssid=HMG-Seogaemo-6f1d passphrase=secret-pass-1 channel=36 ready=1
run precheck || fail usb-precheck
grep -q '^warn.wifi_client=' "$T/output" && fail usb-precheck-warning
sg_write off > "$DATA/desired/wifi"; wifi_set usb_role off
publish radio=none interface= ip= ssid= passphrase= channel= ready=0
run precheck || fail wifi-off-precheck
grep -q '^warn.wifi_client=' "$T/output" && fail wifi-off-precheck-warning
rm -rf "$DATA/peer" "$DATA/settings" "$DATA/desired"
# An app_process swap with no ownership record is refused everywhere, untouched.
touch "$T/state/foreign"
for verb in precheck apply status revert; do
    run "$verb" && fail "foreign-swap-$verb-accepted"
    grep -q '^state=conflict$' "$T/output" || fail "foreign-swap-$verb-state"
    grep -q 'outside the ledger' "$T/output" || fail "foreign-swap-$verb-detail"
done
[ ! -e "$T/state/ops.list" ] && [ ! -e "$T/state/runtime" ] || fail foreign-swap-mutated
rm -f "$T/state/foreign"
# Upstream treats a removal line that is absent on this firmware as a no-op.
grep -Fv 'androidauto_wireless.xml' "$T/root/system/onebin/neev_kr/featurexml.cfg" > "$T/without-aa-line"
cp "$T/without-aa-line" "$T/root/system/onebin/neev_kr/featurexml.cfg"
run precheck || fail absent-feature-line
sg_print "<permissions/>" > "$T/root/system/etc/permissions/com.hkmc.software.wifihotspot.xml"
run precheck && fail malformed-existing-feature-accepted
grep -q '^state=incompatible$' "$T/output" || fail malformed-feature-state
rm -f "$T/root/system/etc/permissions/com.hkmc.software.wifihotspot.xml"
sg_print '-/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml' >> "$T/root/system/onebin/neev_kr/featurexml.cfg"
run precheck && fail duplicate-feature-line-accepted
grep -q '^state=incompatible$' "$T/output" || fail duplicate-feature-line-state
sed -n '1,2p' "$T/root/system/onebin/neev_kr/featurexml.cfg" > "$T/unique-feature-lines"
cp "$T/unique-feature-lines" "$T/root/system/onebin/neev_kr/featurexml.cfg"
cp "$T/root/system/onebin/neev_kr/featurexml.cfg" "$T/original.cfg"
export SG_FAIL_ZYGOTE=1
run apply && fail injected-zygote-failure-accepted
cmp -s "$T/original.cfg" "$T/root/system/onebin/neev_kr/featurexml.cfg" || fail failed-apply-restoration
[ "$(cat "$T/props/persist.ium.support")" = stock ] || fail failed-apply-property
[ ! -e "$T/state/core-hook" ] && [ ! -e "$HOOK/entry" ] || fail failed-apply-hook
[ ! -e "$T/root/system/framework/hmg-seogaemo-wireless-parts.jar" ] || fail failed-apply-parts
unset SG_FAIL_ZYGOTE
run apply || fail apply
grep -q '^state=pending-restart$' "$T/output" || fail apply-state
[ "$(cat "$T/props/persist.ium.support")" = carplay ] || fail property
[ -f "$T/state/core-hook" ] || fail hook-host
[ "$(cat "$T/state/hook-entry")" = hmgapi.mods.wireless.Wireless ] || fail hook-entry
cmp -s "$HERE/files/wireless-mod.jar" "$HOOK/hook.jar" || fail hook-jar
cmp -s "$HERE/files/wireless-mod.jar" "$T/root/system/framework/hmg-seogaemo-wireless-parts.jar" || fail parts-jar
[ "$(cat "$T/root/system/bin/app_process")" = stock-app-process ] || fail app-process-touched
[ -f "$T/root/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml" ] || fail feature-file
# Same boot as the apply: the running zygote is the stock one, so even a ready runtime
# directory cannot count; the head unit must restart first.
run status || fail pre-restart-status
grep -q '^state=pending-restart$' "$T/output" && grep -q '^restart=head_unit$' "$T/output" || fail pre-restart-pending
grep -q 'restart unit to start wireless CarPlay' "$T/output" || fail pre-restart-detail
mkdir -p "$T/state/runtime"; touch "$T/state/runtime/ready"
run status || fail pre-restart-ready-status
grep -q '^state=pending-restart$' "$T/output" || fail pre-restart-ready-claimed-on
rm -f "$T/state/runtime/ready"
# After the restart without any runtime record the evidence is genuinely missing.
sg_print "boot-two" > "$T/root/proc/sys/kernel/random/boot_id"
run status || fail status
grep -q '^state=unknown$' "$T/output" || fail missing-evidence-state
cat > "$T/bin/ps" <<'SH'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_print 'USER PID PPID VSIZE RSS WCHAN PC NAME' 'root 123 1 10000 2000 ffffffff 00000000 zygote'
SH
chmod +x "$T/bin/ps"
mkdir -p "$T/root/proc/123"
sg_print '/system/lib/libhmg_seogaemo_wireless_hook.so' > "$T/root/proc/123/maps"
run status || fail maps-only-status
grep -q '^state=unknown$' "$T/output" || fail maps-only-claimed-ready
touch "$T/state/runtime/ready"
run status || fail loaded-status
grep -q '^state=on$' "$T/output" || fail loaded-state
grep -q '^info.restore_material=present$' "$T/output" || fail rollback-restore-guard
for key in persist.ium.support persist.sys.iap2.wifi persist.iap2.iden.wireless; do
    sg_print stock-reset > "$T/props/$key"
    run status && fail property-drift-accepted
    grep -q 'property drift' "$T/output" || fail property-drift-detail
    run apply || fail property-reassert
done
[ "$(cat "$T/props/persist.ium.support")" = carplay ] || fail reassert-ium
# A changed hook jar on reapply (package update) needs a restart to load.
cp "$HOOK/hook.jar" "$T/hook.jar.saved"; printf old > "$HOOK/hook.jar"; cp "$HOOK/hook.jar" "$T/state/applied$SG_DATA_ROOT/core/hook/mods/state/hook.jar"
run apply || fail jar-update-apply
grep -q '^state=pending-restart$' "$T/output" || fail jar-update-restart
cmp -s "$HERE/files/wireless-mod.jar" "$HOOK/hook.jar" || fail jar-update-content
# Reapplies keep identical jars in place (running apps hold them open).
[ "$(grep -c 'hmg-seogaemo-wireless-parts.jar' "$T/state/ops.list")" = 1 ] || fail parts-jar-rewritten
# Install plus the one simulated package update above; identical reapplies add none.
[ "$(grep -c 'core/hook/mods/state/hook.jar' "$T/state/ops.list")" = 2 ] || fail hook-jar-rewritten
[ "$(cat "$T/props/persist.sys.iap2.wifi")" = t ] || fail reassert-wifi
[ "$(cat "$T/props/persist.iap2.iden.wireless")" = t ] || fail reassert-wireless
# Existing applied wrapper must not skip repair of old private ancestors.
chmod 700 "$T/root/system/etc/hmg-seogaemo" "$T/root/system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes"
run status && fail unreadable-assets-accepted
grep -q 'assets unreadable' "$T/output" || fail unreadable-detail
# A marker write failure must stop before any permission repair.
export SG_FAIL_RESTART_MARKER=1
run apply && fail failed-restart-marker-accepted
case "$(ls -ldn "$T/root/system/etc/hmg-seogaemo")" in drwx------*) ;; *) fail marker-failure-mutated-dirs;; esac
unset SG_FAIL_RESTART_MARKER
# Interruption after directories become searchable must retain restart intent.
export SG_FAIL_AFTER_DIR_REPAIR=1
run apply && fail interrupted-repair-accepted
unset SG_FAIL_AFTER_DIR_REPAIR
[ "$(cat "$T/state/assets-repaired-boot")" = boot-two ] || fail interrupted-restart-marker
run status || fail interrupted-repair-status
grep -q '^state=pending-restart$' "$T/output" || fail interrupted-repair-restart
run apply || fail already-applied-repair
grep -q '^state=pending-restart$' "$T/output" || fail repaired-restart
case "$(ls -ldn "$T/root/system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes")" in drwxr-xr-x*) ;; *) fail repair-mode;; esac
sg_print "boot-three" > "$T/root/proc/sys/kernel/random/boot_id"
run status || fail after-repair-status
grep -q '^state=on$' "$T/output" || fail after-repair-state
chmod 600 "$T/root/system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes/carplay-audio-formats.recipe"
run status && fail private-recipe-accepted
grep -q 'assets unreadable' "$T/output" || fail private-recipe-detail
chmod 644 "$T/root/system/etc/hmg-seogaemo/wireless-carplay-and-aa/recipes/carplay-audio-formats.recipe"
rm -f "$T/bin/ps" "$T/root/proc/123/maps"
sg_print "external-change" >> "$T/root/system/onebin/neev_kr/featurexml.cfg"
run revert && fail drift-accepted
[ -f "$HOOK/entry" ] && [ -f "$T/state/core-hook" ] || fail state-lost-after-drift
# Restore our exact applied file, then revert.
cp "$T/state/applied/system/onebin/neev_kr/featurexml.cfg" "$T/root/system/onebin/neev_kr/featurexml.cfg"
run revert || fail revert
grep -q '^info.desired=off$' "$T/output" || fail revert-intent
grep -q '^state=pending-restart$' "$T/output" || fail revert-restart
cmp -s "$T/original.cfg" "$T/root/system/onebin/neev_kr/featurexml.cfg" || fail exact-feature-restore
[ "$(cat "$T/root/system/bin/app_process")" = stock-app-process ] || fail exact-wrapper-restore
[ ! -e "$T/root/system/bin/app_process.hmg-seogaemo-stock" ] || fail stock-copy-present
[ ! -e "$T/root/system/lib/libhmg_seogaemo_wireless_hook.so" ] || fail hook-lib-present
[ ! -e "$T/root/system/framework/hmg-seogaemo-wireless-hook.jar" ] || fail hook-jar-present
[ ! -e "$T/root/system/lib/libleafiaaac.so" ] || fail audio-lib-present
[ ! -e "$T/root/system/etc/permissions/com.hkmc.software.connectivity.carplay_wireless.xml" ] || fail feature-file-present
[ "$(cat "$T/props/persist.ium.support")" = stock ] || fail exact-prop-restore
[ ! -e "$HOOK/entry" ] && [ ! -e "$HOOK/hook.jar" ] || fail hook-registration-present
[ ! -e "$T/root/system/framework/hmg-seogaemo-wireless-parts.jar" ] || fail parts-jar-present
[ ! -e "$T/state/core-hook" ] || fail hook-host-not-released
[ ! -e "$T/state/runtime" ] || fail runtime-diagnostics-residue
run status || fail reverted-status
grep -q '^info.restore_material=absent$' "$T/output" || fail rollback-after-restore
# The wrapper zygote of the reverted swap runs until the restart: pending, then off.
cp "$T/root/proc/sys/kernel/random/boot_id" "$T/state/assets-repaired-boot"
run status || fail restored-pending-status
grep -q '^state=pending-restart$' "$T/output" && grep -q '^restart=head_unit$' "$T/output" || fail restored-pending-restart
run revert || fail repeated-revert
grep -q '^state=pending-restart$' "$T/output" || fail repeated-revert-pending
sg_print "boot-four" > "$T/root/proc/sys/kernel/random/boot_id"
run status || fail new-boot-status
grep -q '^state=off$' "$T/output" || fail new-boot-off
run revert || fail new-boot-revert
grep -q '^state=off$' "$T/output" || fail new-boot-revert-off
# Package update with the module on: the old self-installed wrapper is restored exactly and
# the hooks move to the core hook host in the same apply.
( . "$T/base/lib/common.sh"; sg_legacy_install )
run status || fail legacy-status
grep -q '^state=pending-restart$' "$T/output" || fail legacy-status-pending
run apply || fail legacy-apply
grep -q '^state=pending-restart$' "$T/output" || fail legacy-apply-pending
[ "$(cat "$T/root/system/bin/app_process")" = stock-app-process ] || fail legacy-wrapper-restore
[ ! -e "$T/root/system/bin/app_process.hmg-seogaemo-stock" ] || fail legacy-stock-copy
[ ! -e "$T/root/system/lib/libhmg_seogaemo_wireless_hook.so" ] || fail legacy-hook-lib
[ ! -e "$T/root/system/framework/hmg-seogaemo-wireless-hook.jar" ] || fail legacy-hook-jar
[ -f "$T/state/core-hook" ] && [ -f "$HOOK/entry" ] || fail legacy-moved
[ "$(cat "$T/props/persist.ium.support")" = carplay ] || fail legacy-property
run revert || fail legacy-revert
cmp -s "$T/original.cfg" "$T/root/system/onebin/neev_kr/featurexml.cfg" || fail legacy-exact-feature-restore
[ "$(cat "$T/props/persist.ium.support")" = stock ] || fail legacy-exact-prop-restore
[ ! -e "$T/state/core-hook" ] || fail legacy-hook-host-not-released
[ ! -e "$T/root/system/etc/hmg-seogaemo" ] || fail empty-asset-dirs-left
sg_print "boot-five" > "$T/root/proc/sys/kernel/random/boot_id"
# The app's ui.txt button and older apps' fixed verb both reach the record reset; nothing else is accepted.
run action tbt_reset && grep -q 'records reset' "$T/output" || fail action-tbt-reset
run tbt-reset && grep -q 'records reset' "$T/output" || fail verb-tbt-reset
run action other && fail unknown-action-accepted
# A guard sweep that cannot finish blocks a fresh apply before anything is written.
touch "$T/state/guard-sweep-fails"
run apply && fail sweep-failure-accepted
grep -q '^state=conflict$' "$T/output" || fail sweep-failure-state
[ ! -e "$T/state/ops.list" ] || fail sweep-failure-mutated
rm -f "$T/state/guard-sweep-fails"
sh "$HERE/test/runtime/run.sh" > "$T/runtime.out" 2>&1 || { cat "$T/runtime.out"; fail runtime; }
sh "$HERE/test/consumer/run.sh" > "$T/consumer.out" 2>&1 || { cat "$T/consumer.out"; fail consumer; }
sh "$HERE/test/cpturns/run.sh" > "$T/cpturns.out" 2>&1 || { cat "$T/cpturns.out"; fail cpturns; }
sh "$HERE/test/usbhotspot/run.sh"
sh "$HERE/test/stockhotspot/run.sh"
sh "$HERE/test/projectionswitch/run.sh"
sh "$HERE/test/projectionowner/run.sh"
sh "$HERE/test/projectiondelete/run.sh"
sh "$HERE/test/bridgepeers/run.sh"
sh "$HERE/test/projectionmenu/run.sh"
python3 "$HERE/test/trapoverlay/test.py"
python3 "$HERE/test/aautf8/test.py"
python3 "$HERE/test/aalanes/test.py"
sg_print "ok wireless-carplay-and-aa toolbox parse, guards, rollback, drift refusal, exact revert"
