package android.util;
public final class Log {
    public static final java.util.List<String> lines = new java.util.ArrayList<String>();
    public static int d(String t, String m) { lines.add(t + " " + m); return 0; }
}
