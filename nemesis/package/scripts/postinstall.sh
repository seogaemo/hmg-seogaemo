#!/system/bin/sh
umask 077
base=${0%/*}
base=${base%/scripts}
# Any Gen5W firmware on Android 4.4 (API 19); modules check for this car's map themselves.
[ "$(getprop ro.build.version.sdk)" = 19 ] || { echo 'Unsupported Android version' >&2; exit 1; }
# An explicit USB install selects this newly installed tree. Clear the OTA
# selection before anything that can fail (APK step, paused stock restore), so
# a retained older OTA payload never keeps serving root verbs. Version dirs and
# baselines are retained; stock/paused is deliberately left untouched.
update=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}/update
rm -f "$update/current" "$update/current-path" "$update/previous-path" \
    "$update/previous-version" "$update/journal" || exit 1
# NEMESIS ignores ZIP modes. Shell callers use /system/bin/sh; also permit
# Manager Launch implementations that execute kind=sh directly.
chmod 755 "$base/bin/hmg-seogaemo-root" "$base/bin/open.sh" "$base/bin/install-apk.sh" || exit 1
# The packaged APK must use the daemon path. A SUID invocation can inherit
# the app process's limited capability bounding set and fail remount/restore.
cp /system/xbin/nemesis "$base/bin/nemesis-client.tmp.$$" || exit 1
chmod 755 "$base/bin/nemesis-client.tmp.$$" || exit 1
mv "$base/bin/nemesis-client.tmp.$$" "$base/bin/nemesis-client" || exit 1
state=${SG_DATA_ROOT:-/data/nemesis/backup/hmg-seogaemo}
job=$state/app-install
mkdir -p "$job/payload/app" "$job/payload/bin" || exit 1
cp "$base/app/hmg-seogaemo.apk" "$job/payload/app/hmg-seogaemo.apk.tmp.$$" &&
    mv "$job/payload/app/hmg-seogaemo.apk.tmp.$$" "$job/payload/app/hmg-seogaemo.apk" &&
    cp "$base/bin/install-apk.sh" "$job/payload/bin/install-apk.sh.tmp.$$" &&
    mv "$job/payload/bin/install-apk.sh.tmp.$$" "$job/payload/bin/install-apk.sh" || exit 1
# Record an existing app even during a down-Android update if PM can report it.
case "$(pm path com.seogaemo.hmg 2>/dev/null)" in package:*) echo installed > "$job/seen" || exit 1;; esac
rm -f "$job/attempts" || exit 1
echo "$(date +%s)-$$" > "$job/pending.tmp.$$" &&
    mv "$job/pending.tmp.$$" "$job/pending" || exit 1
android_ready=0
if [ "$(getprop sys.boot_completed)" = 1 ]; then
    case "$(pm path android 2>/dev/null)" in package:*) android_ready=1;; esac
fi
if [ "$android_ready" -eq 1 ]; then
    /system/bin/sh "$base/svc/install-pending.sh" install || exit 1
    [ ! -f "$job/pending" ] || exit 1
    # Bundled modules appear in the app right away; boot reconcile retries (installable-modules.md).
    if [ -d "$base/bundled" ]; then
        SG_DATA_ROOT=$state /system/bin/sh "$base/core/module.sh" install-bundled >> "$state/reconcile.log" 2>&1 < /dev/null || :
    fi
    # CarPlay on from an older package moves to the core hook host now, so one restart finishes
    # the update (boot reconcile runs after zygote start and would need a second one).
    if [ "$(cat "$state/desired/wireless-carplay-and-aa" 2>/dev/null)" = on ]; then
        /system/bin/sh "$base/bin/hmg-seogaemo-root" wireless-carplay-and-aa apply >> "$state/reconcile.log" 2>&1 < /dev/null || :
    fi
fi
[ "$android_ready" -eq 1 ] || echo 'Android is not ready; APK retained for automatic installation when ready'
