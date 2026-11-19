if file_missing /system/app/HKMC_NModeApp.apk; then
    block @missing_app
fi
if file_missing /system/onebin/@onebin@/pkg.cfg; then
    block @missing_list
fi
if not module_on cn7-n-mode; then
    if not file_has_line /system/onebin/@onebin@/pkg.cfg "-/system/app/HKMC_NModeApp.apk"; then
        block @no_hide_entry
    fi
fi
