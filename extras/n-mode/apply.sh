if not module_on cn7-n-mode; then
    replace_line /system/onebin/@onebin@/pkg.cfg "-/system/app/HKMC_NModeApp.apk" "# HMG-Seogaemo N Mode"
    if prop_is ro.product.name wp_daudioplus_cn7_kr; then
        if file_md5_is /system/app/HKMC_NModeApp.odex 80f6f4c705a0655032a24d88384d61e0; then
            patch_file /system/app/HKMC_NModeApp.odex files/display.delta.gz
        fi
    fi
fi
