package hmgapi.mods.wireless;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;

public final class ReadyResendTest {
    static int checks;
    static volatile boolean up;
    static final List<String> logs = new ArrayList<String>();
    static Method METHOD;

    static void check(boolean ok, String why) {
        checks++;
        if (!ok) throw new AssertionError(why);
    }

    static void await(String why, Callable<Boolean> c) throws Exception {
        long end = System.currentTimeMillis() + 3000;
        while (!c.call()) {
            if (System.currentTimeMillis() > end) throw new AssertionError("timed out: " + why);
            Thread.sleep(5);
        }
        checks++;
    }

    /** shaped like android.phoneprojection.WLDeviceInfo (the getters ReadyResend reads) */
    public static final class Info {
        final String addr;
        final int transfer;

        Info(String addr, int transfer) {
            this.addr = addr;
            this.transfer = transfer;
        }

        public String getWLDevBtAddr() { return addr; }

        public int getWLTransferType() { return transfer; }
    }

    static final ReadyResend.Log LOG = new ReadyResend.Log() {
        @Override
        public void log(String message) {
            synchronized (logs) { logs.add(message); }
        }
    };

    /** PhoneProjection's listener: records every report and goes through ReadyResend as the hook does (after the stock code) */
    public static final class Listener {
        final List<Integer> got = new ArrayList<Integer>();

        public void requestWLDeviceReadyStatusUpdate(Info info, int ready) {
            synchronized (got) { got.add(ready); }
            ReadyResend.seen(LOG, this, METHOD, info, ready);
        }

        List<Integer> got() { synchronized (got) { return new ArrayList<Integer>(got); } }
    }

    public static void main(String[] args) throws Exception {
        METHOD = Listener.class.getMethod("requestWLDeviceReadyStatusUpdate", Info.class, int.class);
        ReadyResend.pollMs = 10;
        ReadyResend.settleMs = 10;
        ReadyResend.probe = new ReadyResend.Probe() {
            @Override
            public boolean apUp() { return up; }
        };

        // first start: ready before the hotspot; once it serves, 0 then 1 again, once
        final Listener a = new Listener();
        up = false;
        a.requestWLDeviceReadyStatusUpdate(new Info("AA:BB", 1), 1);
        check(ReadyResend.pending(), "ready with no hotspot kept");
        Thread.sleep(50);
        check(a.got().size() == 1, "nothing resent while the hotspot is down");
        up = true;
        await("resend after the hotspot serves", new Callable<Boolean>() {
            public Boolean call() { return a.got().size() == 3; }
        });
        check(a.got().get(1) == 0 && a.got().get(2) == 1, "resent as 0 then 1: " + a.got());
        Thread.sleep(50);
        check(a.got().size() == 3 && !ReadyResend.pending(), "resent once, nothing kept");

        // the hotspot already serves: stock handles it
        final Listener b = new Listener();
        b.requestWLDeviceReadyStatusUpdate(new Info("AA:BB", 1), 1);
        check(!ReadyResend.pending(), "ready with the hotspot up not kept");

        // wired (USB) transfer: not ours
        up = false;
        b.requestWLDeviceReadyStatusUpdate(new Info("AA:BB", 0), 1);
        check(!ReadyResend.pending(), "wired ready not kept");

        // the phone goes away (ready 0) before the hotspot serves: dropped, nothing resent
        final Listener c = new Listener();
        c.requestWLDeviceReadyStatusUpdate(new Info("AA:BB", 1), 1);
        c.requestWLDeviceReadyStatusUpdate(new Info("aa:bb", 1), 0);
        check(!ReadyResend.pending(), "ready 0 drops the kept ready");
        up = true;
        Thread.sleep(80);
        check(c.got().size() == 2, "nothing resent after ready 0: " + c.got());

        // another phone's report leaves the kept one; a hotspot that never serves: given up after the wait
        up = false;
        ReadyResend.waitMs = 100;
        final Listener d = new Listener();
        d.requestWLDeviceReadyStatusUpdate(new Info("AA:BB", 1), 1);
        d.requestWLDeviceReadyStatusUpdate(new Info("CC:DD", 1), 0);
        check(ReadyResend.pending(), "another device's report keeps it");
        await("given up", new Callable<Boolean>() {
            public Boolean call() { return !ReadyResend.pending(); }
        });
        check(d.got().size() == 2, "nothing resent when the hotspot never served");
        synchronized (logs) {
            check(logs.get(logs.size() - 1).contains("did not serve"), "give-up logged: " + logs);
        }
        System.out.println("ok readyresend: " + checks + " checks");
    }
}
