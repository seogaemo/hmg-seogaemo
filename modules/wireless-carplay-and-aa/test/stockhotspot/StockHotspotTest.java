package hmgapi.mods.wireless;

import android.net.wifi.WifiConfiguration;

import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Which hotspot the phone is pointed at, the mode Android Auto sees, and the normal hotspot started when none came up. */
public final class StockHotspotTest {
    static void check(boolean b, String message) { if (!b) throw new AssertionError(message); }

    /** WifiManager as reflection sees it: the state, the mode and the normal hotspot switch */
    public static final class FakeWifi {
        volatile int state, mode, started;
        volatile boolean modeReadPastHook;

        FakeWifi(int state, int mode) { this.state = state; this.mode = mode; }

        public int getWifiApState() { return state; }

        public int getWifiApMode() { modeReadPastHook = StockHotspot.reading(); return mode; }

        public boolean setWifiApEnabled(WifiConfiguration c, boolean on) {
            check(c == null && on, "normal hotspot with its saved configuration");
            started++;
            state = StockHotspot.ENABLED;
            return true;
        }
    }

    static WifiConfiguration config() {
        WifiConfiguration c = new WifiConfiguration();
        c.SSID = "Kia_hotspot_1a2b";
        c.preSharedKey = "normal-pass";
        c.ConnectivitySSID = "CarPlay-9f8e";
        c.ConnectivityPSK = "connectivity-pass";
        return c;
    }

    static String startAndWait(FakeWifi wifi) throws Exception {
        final LinkedBlockingQueue<String> lines = new LinkedBlockingQueue<String>();
        final AtomicReference<Thread> worker = new AtomicReference<Thread>();
        StockHotspot.startLater(wifi, new StockHotspot.Log() {
            @Override
            public void log(String message) {
                worker.set(Thread.currentThread());
                lines.add(message);
            }
        });
        String line = lines.poll(5, TimeUnit.SECONDS);
        check(line != null, "the scheduled check reports");
        // The callback precedes the worker's finally block, which clears pending.
        // Wait for that cleanup before scheduling the next independent scenario.
        worker.get().join(5000);
        check(!worker.get().isAlive(), "the scheduled check finishes");
        return line;
    }

    public static void main(String[] args) throws Exception {
        // The connectivity hotspot came up: stock in every respect.
        check(!StockHotspot.shareNormal(13, 2) && StockHotspot.apMode(13, 2) == 2, "connectivity hotspot");
        // The normal hotspot came up instead: the phone gets its credentials, Android Auto sees mode 2.
        check(StockHotspot.shareNormal(13, 1) && StockHotspot.apMode(13, 1) == 2, "normal hotspot");
        check(StockHotspot.shareNormal(13, -1) && StockHotspot.apMode(13, -1) == 2, "normal hotspot, mode unreadable");
        // Nothing serves: the phone gets the normal credentials (the normal hotspot is about to start); mode unchanged.
        check(StockHotspot.shareNormal(11, 0) && StockHotspot.shareNormal(14, 0) && StockHotspot.apMode(11, 0) == 0, "nothing");
        // Starting, stopping or unreadable: left alone.
        check(!StockHotspot.shareNormal(12, 0) && !StockHotspot.shareNormal(10, 0) && !StockHotspot.shareNormal(-1, -1), "in between");
        check(StockHotspot.apMode(12, 0) == 0 && StockHotspot.apMode(-1, 1) == 1, "mode in between");

        WifiConfiguration c = config();
        check(StockHotspot.useNormal(c), "copied");
        check("Kia_hotspot_1a2b".equals(c.ConnectivitySSID) && "normal-pass".equals(c.ConnectivityPSK), "connectivity fields");
        check("Kia_hotspot_1a2b".equals(c.SSID) && "normal-pass".equals(c.preSharedKey), "normal fields unchanged");
        check(!StockHotspot.useNormal(c), "already equal");
        WifiConfiguration open = config();
        open.preSharedKey = null;
        check(!StockHotspot.useNormal(open) && "CarPlay-9f8e".equals(open.ConnectivitySSID), "no normal passphrase");
        check(!StockHotspot.useNormal(null), "no configuration");

        FakeWifi wifi = new FakeWifi(13, 1);
        check(StockHotspot.state(wifi) == 13 && StockHotspot.mode(wifi) == 1, "read by reflection");
        check(wifi.modeReadPastHook && !StockHotspot.reading(), "the mode hook is bypassed only during the read");
        check(StockHotspot.state(new Object()) == -1 && StockHotspot.mode(new Object()) == -1, "unreadable");

        StockHotspot.startWaitMs = 0L;
        FakeWifi none = new FakeWifi(StockHotspot.DISABLED, 0);
        String line = startAndWait(none);
        check(none.started == 1 && line.contains("normal hotspot started"), "nothing came up: " + line);
        FakeWifi up = new FakeWifi(StockHotspot.ENABLED, 2);
        line = startAndWait(up);
        check(up.started == 0 && line.contains("state 13 mode 2"), "it came up: " + line);
        FakeWifi starting = new FakeWifi(12, 0);
        line = startAndWait(starting);
        check(starting.started == 0, "still starting: " + line);
        System.out.println("stock hotspot tests passed");
    }
}
