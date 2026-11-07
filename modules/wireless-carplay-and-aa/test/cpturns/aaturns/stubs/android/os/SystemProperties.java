package android.os;
/** host stand-in (hidden API, read by reflection): the developer toggle */
public final class SystemProperties {
    public static String dev = "0";
    public static String get(String key, String def) { return "persist.hmg_seogaemo.dev".equals(key) ? dev : def; }
}
