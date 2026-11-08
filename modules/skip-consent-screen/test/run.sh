#!/bin/sh
set -eu
module_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$module_dir/../.." && pwd)
car_shell=${HMG_SEOGAEMO_TEST_SHELL:-$(command -v mksh || command -v sh)}
export HMG_SEOGAEMO_TEST_COMMON="$repo/nemesis/package/lib/common.sh"
. "$HMG_SEOGAEMO_TEST_COMMON"
tmp=$(mktemp -d "$module_dir/test/.tmp.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/base/lib" "$tmp/bin" "$tmp/restricted" "$tmp/state" "$tmp/data/desired" "$tmp/props"
cat > "$tmp/base/lib/common.sh" <<'EOF'
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_status() {
    sg_print "state=$1" "restart=$2" "detail=$3"
    case "$1" in conflict) return 3;; incompatible) return 4;; failed) return 1;; esac
}
sg_owner_present() { [ -f "$FAKE_ROOT/owner" ]; }
sg_service_call_this_boot() {
    [ -f "$FAKE_ROOT/last-call-boot" ] &&
        [ "$(cat "$FAKE_ROOT/last-call-boot")" = "$(cat "$FAKE_ROOT/boot-id")" ]
}
sg_service_call_ok_this_boot() { sg_service_call_this_boot && [ "$(cat "$FAKE_ROOT/last-call-result" 2>/dev/null)" = ok ]; }
sg_service_call() {
    [ "$1:$2" = com.hkmc.factory:82 ] || return 2
    sg_print "$1:$2" >> "$FAKE_ROOT/calls"
    cat "$FAKE_ROOT/boot-id" > "$FAKE_ROOT/last-call-boot"
    case "$(cat "$FAKE_ROOT/response" 2>/dev/null)" in
        exception) SG_SERVICE_CALL_RESPONSE='Cannot broadcast before boot completed'; echo failed > "$FAKE_ROOT/last-call-result"; return 1 ;;
        failed) SG_SERVICE_CALL_RESPONSE='Binder failed'; echo failed > "$FAKE_ROOT/last-call-result"; return 1 ;;
        *) SG_SERVICE_CALL_RESPONSE='Parcel(00000000)'; echo ok > "$FAKE_ROOT/last-call-result" ;;
    esac
    return 0
}
EOF
cat > "$tmp/bin/getprop" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
cat "$FAKE_ROOT/props/$1" 2>/dev/null || :
EOF
cat > "$tmp/bin/md5" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
if [ -f "$FAKE_ROOT/wrong-hash" ]; then
    echo '00000000000000000000000000000000  file'
else
    echo 'ffe86fa1540c8dea3b5499b1191bb727  file'
fi
EOF
cat > "$tmp/bin/service" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
echo 'Service com.hkmc.factory: found'
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
:
EOF
cat > "$tmp/bin/forbidden" <<'EOF'
#!/bin/sh
. "$HMG_SEOGAEMO_TEST_COMMON"
sg_print "${0##*/}" >> "$FAKE_ROOT/forbidden"
exit 99
EOF
chmod +x "$tmp/bin/"*
for name in getprop md5 service sleep; do ln -s "$tmp/bin/$name" "$tmp/restricted/$name"; done
for name in cat grep dd; do ln -s "$(command -v "$name")" "$tmp/restricted/$name"; done
for name in awk sed tail head cut tr wc sort find stat sha256sum tar unzip busybox; do
    ln -s "$tmp/bin/forbidden" "$tmp/restricted/$name"
done
export FAKE_ROOT="$tmp" HMG_SEOGAEMO_BASE="$tmp/base" HMG_SEOGAEMO_STATE="$tmp/state"
export SG_DATA_ROOT="$tmp/data" SG_SKIP_CONSENT_FRAMEWORK="$tmp/framework.odex"
export HMG_SEOGAEMO_SERVICE_BIN="$tmp/bin/service"
script="$tmp/skip-consent-screen.sh"
# Intercept mksh's sleep builtin in the private fixture too.
{ echo "sleep() { :; }"; cat "$module_dir/module.sh"; } > "$script"
sg_write "stock" > "$tmp/framework.odex"
# The stock framework MD5 comes from this firmware's car map, not from the module.
sg_write "TEST.KOR.0000.V001.001.270101" > "$tmp/props/ro.build.product"
mkdir -p "$tmp/base/maps/test/car/kor/270101"
cat > "$tmp/base/maps/test/car/kor/270101/car.json" <<'EOF'
{
  "files": {
    "/system/framework/framework.odex": "ffe86fa1540c8dea3b5499b1191bb727"
  },
  "product": "TEST.KOR.0000.V001.001.270101"
}
EOF
sg_write "19" > "$tmp/props/ro.build.version.sdk"
sg_write "1" > "$tmp/props/sys.boot_completed"
sg_write "boot-a" > "$tmp/boot-id"
run() { PATH="$tmp/restricted" "$car_shell" "$script" "$@" > "$tmp/output"; }
has() { grep -q -F "$1" "$tmp/output" || { cat "$tmp/output"; exit 1; }; }
run status; has 'state=off'
run precheck; has 'state=off'
: > "$tmp/owner"
if run precheck; then exit 1; fi
has 'state=conflict'; has 'Uninstall local.hkmc.factory82 first'
rm "$tmp/owner"
: > "$tmp/wrong-hash"
if run apply; then exit 1; fi
has 'state=incompatible'
rm "$tmp/wrong-hash"
sg_write "WRONG.KOR.0000.V001.001.270101" > "$tmp/props/ro.build.product"
if run precheck; then exit 1; fi
has 'state=incompatible'
sg_write "TEST.KOR.0000.V001.001.270101" > "$tmp/props/ro.build.product"
run apply; has 'state=pending-restart'
sg_write "on" > "$tmp/data/desired/skip-consent-screen"
run watch boot; has 'state=on'
run watch boot; [ "$(grep -c '^com.hkmc.factory:82$' "$tmp/calls")" = 1 ]
run watch screen_on; [ "$(grep -c '^com.hkmc.factory:82$' "$tmp/calls")" = 2 ]
run revert; has 'state=pending-restart'; has 'info.desired=off'
sg_write "off" > "$tmp/data/desired/skip-consent-screen"
run status; has 'state=pending-restart'; has 'info.desired=off'
sg_write "boot-b" > "$tmp/boot-id"
run status; has 'state=off'
sg_write "on" > "$tmp/data/desired/skip-consent-screen"
sg_write "failed" > "$tmp/response"
if run watch boot; then exit 1; fi
has 'state=failed'
[ "$(cat "$tmp/last-call-result")" = failed ]
sg_write "ok" > "$tmp/response"
run watch boot; has 'state=on'
[ "$(grep -c '^com.hkmc.factory:82$' "$tmp/calls")" = 4 ]
run watch boot
[ "$(grep -c '^com.hkmc.factory:82$' "$tmp/calls")" = 4 ]
sg_write "boot-c" > "$tmp/boot-id"
sg_write "exception" > "$tmp/response"
if run watch boot; then exit 1; fi
has 'state=failed'
[ "$(grep -c '^com.hkmc.factory:82$' "$tmp/calls")" = 6 ]
sg_write "ok" > "$tmp/response"
run watch boot; has 'state=on'
[ "$(grep -c '^com.hkmc.factory:82$' "$tmp/calls")" = 7 ]
[ ! -f "$tmp/forbidden" ]
echo 'skip-consent-screen module tests passed'
