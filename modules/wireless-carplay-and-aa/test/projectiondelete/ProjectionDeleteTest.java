package hmgapi.mods.wireless;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.PriorityQueue;

/**
 * ProjectionDelete (item 10) over a fake environment: a manual clock, worker work run explicitly, ordered calls
 * recorded. Deterministic: no sleeps, no threads.
 */
public final class ProjectionDeleteTest {
    static final String A = "80:96:98:05:D7:3D", B = "AA:BB:CC:DD:EE:FF";
    static final String DA = "DEV-A", MAC = "11:22:33:44:55:66";
    static final int END = 4, CONNECTED = 3, CONNECTING = 2;

    static final class Timer implements Comparable<Timer> {
        final long due, seq;
        final Runnable run;

        Timer(long due, long seq, Runnable run) {
            this.due = due;
            this.seq = seq;
            this.run = run;
        }

        @Override
        public int compareTo(Timer o) {
            if (due != o.due) return due < o.due ? -1 : 1;
            return seq < o.seq ? -1 : (seq == o.seq ? 0 : 1);
        }
    }

    static final class FakeEnv implements ProjectionDelete.Env {
        boolean enabled = true, dipo = true, listenFails, disconnectFails, postFails, barrierThrows, deleteThrows, dipoThrows;
        String connected = A;
        int transfer = 1, user = 0;
        ProjectionDelete.Row row = ProjectionDeleteTest.row(A, DA, 0, 1, 1);
        ProjectionDelete.Sink sink;
        /** runs once, inside the next row read (a reconnect that lands mid-deletion) */
        Runnable beforeRow;
        int listens, disconnects, barriers, deletes;
        /** the ordered calls: "disconnect", "barrier", "delete" */
        final List<String> calls = new ArrayList<String>();
        final List<String> log = new ArrayList<String>();
        private long clock, seq;
        private final ArrayDeque<Runnable> queue = new ArrayDeque<Runnable>();
        private final PriorityQueue<Timer> timers = new PriorityQueue<Timer>();

        @Override
        public boolean enabled() {
            return enabled;
        }

        @Override
        public void post(Runnable r) {
            queue.add(r);
        }

        @Override
        public void postDelayed(Runnable r, long delayMs) {
            if (postFails) throw new IllegalStateException("handler gone");
            timers.add(new Timer(clock + delayMs, seq++, r));
        }

        @Override
        public void log(String message) {
            log.add(message);
        }

        @Override
        public boolean dipoActivated() {
            if (dipoThrows) throw new IllegalStateException("DiPOManager gone");
            return dipo;
        }

        @Override
        public String connectedCp() {
            return connected;
        }

        @Override
        public int transferType(String addr) {
            return transfer;
        }

        @Override
        public int userType() {
            return user;
        }

        @Override
        public ProjectionDelete.Row row(String addr, String serial, int u) {
            if (beforeRow != null) {
                Runnable once = beforeRow;
                beforeRow = null;
                once.run();
            }
            return row;
        }

        @Override
        public boolean disconnectCp() {
            calls.add("disconnect");
            disconnects++;
            return !disconnectFails;
        }

        @Override
        public void barrier() {
            calls.add("barrier");
            barriers++;
            if (barrierThrows) throw new IllegalStateException("binder dead");
        }

        @Override
        public boolean deleteRow(String addr, String serial, int u) {
            calls.add("delete");
            deletes++;
            if (deleteThrows) throw new IllegalStateException("binder dead");
            return true;
        }

        @Override
        public void listen(ProjectionDelete.Sink s) {
            listens++;
            if (listenFails) throw new IllegalStateException("addWLDeviceInfoListener refused");
            sink = s;
        }

        /** runs the worker work that is due now */
        void settle() {
            while (!queue.isEmpty()) queue.poll().run();
        }

        /** moves the clock forward, running every delayed step due on the way, in order */
        void advance(long ms) {
            long target = clock + ms;
            settle();
            while (!timers.isEmpty() && timers.peek().due <= target) {
                Timer t = timers.poll();
                clock = t.due;
                t.run.run();
                settle();
            }
            clock = target;
            settle();
        }

        long now() {
            return clock;
        }

        int countContains(String text) {
            int n = 0;
            for (String s : log) if (s.contains(text)) n++;
            return n;
        }

        boolean logHas(String text) {
            return countContains(text) > 0;
        }
    }

    static ProjectionDelete.Row row(String addr, String serial, int user, int ppType, int transfer) {
        return new ProjectionDelete.Row(addr, serial, MAC, "Phone", user, ppType, transfer);
    }

    static void check(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
    }

    static void callsAre(FakeEnv e, String... want) {
        List<String> w = Arrays.asList(want);
        check(e.calls.equals(w), "calls " + e.calls + " want " + w + "\nlog " + e.log);
    }

    /** a stock decision: nothing held, nothing called, the reason logged */
    static void stock(FakeEnv e, ProjectionDelete d, String addr, String reason) {
        check(!d.maybeDelete(addr), "stock expected (" + reason + ")");
        check(e.calls.isEmpty() && e.disconnects == 0 && e.listens == 0, "stock touches nothing (" + reason + ") " + e.calls);
        check(e.logHas("stock delete: " + reason), "reason logged: " + reason + " in " + e.log);
    }

    /** the end (4) or another status for the held phone, as Phone Projection reports it */
    static void status(FakeEnv e, ProjectionDelete.Row info, int status) {
        check(e.sink != null, "listener registered");
        e.sink.connectStatus(info, status);
    }

    static ProjectionDelete.Row infoOf(FakeEnv e, String addr, String serial, int user, int ppType, int transfer) {
        return row(addr, serial, user, ppType, transfer);
    }

    // Stock fallbacks: each reason, nothing held.

    static void everyStockReason() {
        FakeEnv e = new FakeEnv();
        e.enabled = false;
        stock(e, new ProjectionDelete(e), A, "kill switch");

        e = new FakeEnv();
        e.dipo = false;
        stock(e, new ProjectionDelete(e), A, "CarPlay not active (Android Auto or none)");

        e = new FakeEnv();
        e.connected = B;
        stock(e, new ProjectionDelete(e), A, "not the connected CarPlay phone");

        e = new FakeEnv();
        e.connected = null;
        stock(e, new ProjectionDelete(e), A, "not the connected CarPlay phone");

        e = new FakeEnv();
        e.transfer = 0;
        stock(e, new ProjectionDelete(e), A, "not a wireless connection");

        e = new FakeEnv();
        e.user = -1;
        stock(e, new ProjectionDelete(e), A, "profile unknown");

        e = new FakeEnv();
        e.row = null;
        stock(e, new ProjectionDelete(e), A, "no Phone Projection row");

        e = new FakeEnv();
        e.row = row(A, DA, 0, 2, 1);
        stock(e, new ProjectionDelete(e), A, "row is not wireless CarPlay");

        e = new FakeEnv();
        e.row = row(A, DA, 0, 1, 0);
        stock(e, new ProjectionDelete(e), A, "row is not wireless CarPlay");

        e = new FakeEnv();
        e.row = row(A, DA, 1, 1, 1);
        stock(e, new ProjectionDelete(e), A, "row belongs to another phone or profile");

        e = new FakeEnv();
        e.row = row(B, DA, 0, 1, 1);
        stock(e, new ProjectionDelete(e), A, "row belongs to another phone or profile");

        e = new FakeEnv();
        stock(e, new ProjectionDelete(e), null, "no address");

        e = new FakeEnv();
        e.dipoThrows = true;
        stock(e, new ProjectionDelete(e), A, "decision failed: java.lang.IllegalStateException: DiPOManager gone");
    }

    static void listenerFailureIsStock() {
        FakeEnv e = new FakeEnv();
        e.listenFails = true;
        ProjectionDelete d = new ProjectionDelete(e);
        check(!d.maybeDelete(A), "stock when the listener cannot be registered");
        check(e.disconnects == 0 && e.deletes == 0, "nothing sent");
        check(!d.maybeDelete(A) && e.logHas("listener not registered"), "second attempt also stock");
    }

    static void timerFailureIsStock() {
        FakeEnv e = new FakeEnv();
        e.postFails = true;
        ProjectionDelete d = new ProjectionDelete(e);
        check(!d.maybeDelete(A), "stock when the fallback timer cannot be scheduled");
        check(e.disconnects == 0, "no disconnect sent before the timer");
    }

    static void disconnectFailureIsStockAndForgotten() {
        FakeEnv e = new FakeEnv();
        e.disconnectFails = true;
        ProjectionDelete d = new ProjectionDelete(e);
        check(!d.maybeDelete(A), "stock when the disconnect cannot be sent");
        check(e.disconnects == 1, "the disconnect was attempted once");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.advance(60000);
        callsAre(e, "disconnect");
    }

    // Hold order and the matching end.

    static void holdDisconnectsFirstAndDoesNotDelete() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        callsAre(e, "disconnect");
        check(e.deletes == 0, "no delete while held");
        e.advance(14999);
        callsAre(e, "disconnect");
        check(e.logHas("held"), "hold logged");
    }

    static void matchingEndBarrierThenDeleteOnce() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        callsAre(e, "disconnect", "barrier", "delete");
        check(e.deletes == 1, "deleted once");
        e.advance(60000);
        check(e.deletes == 1, "the fallback does not delete again");
        callsAre(e, "disconnect", "barrier", "delete");
    }

    static void endOfAnotherPeerIgnored() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(B, DA, 0, 1, 1), END);
        e.settle();
        callsAre(e, "disconnect");
        e.advance(14999);
        check(e.deletes == 0, "still held for A");
        e.advance(1);
        check(e.deletes == 1, "A's fallback deletes it");
    }

    static void otherPpTypeOrWiredStatusIgnored() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(A, DA, 0, 2, 1), END);
        status(e, row(A, DA, 0, 1, 0), END);
        e.settle();
        callsAre(e, "disconnect");
        check(e.deletes == 0, "AA and wired statuses are not the matching end");
    }

    static void reconnectAfterEndCancels() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        callsAre(e, "disconnect", "barrier");
        status(e, row(A, DA, 0, 1, 1), CONNECTED);
        e.dipo = false;
        e.advance(20000);
        check(e.deletes == 0, "a reconnect after the end keeps the row");
        check(e.logHas("connected again after its end"), "cancel logged");
    }

    static void connectBeforeEndIsNotAReconnect() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        status(e, row(A, DA, 0, 1, 1), CONNECTED);
        status(e, row(A, DA, 0, 1, 1), CONNECTING);
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        check(e.deletes == 1, "a 3 before the end does not cancel");
    }

    static void dipoStillActiveWaitsThenDeletes() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        callsAre(e, "disconnect", "barrier");
        e.advance(1000);
        check(e.deletes == 0, "DiPO still active: no delete");
        e.dipo = false;
        e.advance(250);
        check(e.deletes == 1, "deleted once DiPO is inactive");
        check(e.now() < ProjectionDelete.TIMEOUT_MS, "deleted before the fallback, at " + e.now());
        callsAre(e, "disconnect", "barrier", "delete");
    }

    static void fifteenSecondFallbackDeletes() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.advance(14999);
        check(e.deletes == 0, "not before 15 s");
        e.advance(1);
        check(e.deletes == 1, "deleted at 15 s without a matching end");
        check(e.logHas("no matching end within 15 s"), "fallback logged");
        callsAre(e, "disconnect", "delete");
    }

    static void doubleRequestReusesPending() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        check(d.maybeDelete(A), "second request held too");
        check(e.disconnects == 1 && e.listens == 1, "one disconnect, one listener (" + e.disconnects + "," + e.listens + ")");
        check(e.logHas("request reused"), "reuse logged");
        e.advance(15000);
        check(e.deletes == 1, "one deletion for both requests");
    }

    static void profileChangeAbortsDeletion() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.user = 2;
        e.settle();
        check(e.deletes == 0, "no delete after a profile change");
        check(e.logHas("profile changed, deletion"), "abort logged");
        e.advance(60000);
        check(e.deletes == 0, "and the fallback does not delete either");
    }

    static void barrierFailureLeavesFallback() {
        FakeEnv e = new FakeEnv();
        e.barrierThrows = true;
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        check(e.deletes == 0 && e.logHas("barrier failed"), "no delete when the barrier fails");
        e.advance(15000);
        check(e.deletes == 1, "the 15 s fallback deletes it");
    }

    static void deleteFailureIsNotRetried() {
        FakeEnv e = new FakeEnv();
        e.deleteThrows = true;
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        check(e.deletes == 1 && e.logHas("failed, not retried"), "the failed call is logged");
        e.advance(15000);
        check(e.deletes == 1, "not retried by the fallback");
    }

    static void deletionCalledExactlyOnce() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        e.advance(60000);
        check(e.deletes == 1, "one delete for a repeated end and the fallback (" + e.deletes + ")");
    }

    static void listenerRegisteredOnce() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "first hold");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        e.dipo = true;
        check(d.maybeDelete(A), "second hold, CarPlay active again");
        check(e.listens == 1, "listener registered once (" + e.listens + ")");
        check(e.disconnects == 2, "each hold disconnects");
    }

    static void rowChangedOrGoneIsNotDeleted() {
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.row = row(A, "OTHER", 0, 1, 1);
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.settle();
        check(e.deletes == 0 && e.logHas("row changed"), "a changed row is not deleted");

        FakeEnv gone = new FakeEnv();
        ProjectionDelete g = new ProjectionDelete(gone);
        check(g.maybeDelete(A), "held");
        gone.row = null;
        gone.dipo = false;
        status(gone, row(A, DA, 0, 1, 1), END);
        gone.settle();
        check(gone.deletes == 0 && gone.logHas("already gone"), "a row already removed is not deleted again");
    }

    static void reconnectDuringDeletionCancelsIt() {
        // the reconnect lands after the deletion's live check and before its claim: the claim refuses, nothing is deleted
        final FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        e.dipo = false;
        status(e, row(A, DA, 0, 1, 1), END);
        e.beforeRow = new Runnable() {
            @Override
            public void run() {
                status(e, row(A, DA, 0, 1, 1), CONNECTED);
            }
        };
        e.settle();
        check(e.deletes == 0, "no delete for a phone that connected again");
        check(e.logHas("connected again after its end"), "cancelled during the deletion");
        e.advance(60000);
        check(e.deletes == 0, "and the fallback does not delete it");
    }

    static void disconnectRunsBeforeAnyWait() {
        // the stock disconnect is the first effect of a hold, before the fallback and before any end
        FakeEnv e = new FakeEnv();
        ProjectionDelete d = new ProjectionDelete(e);
        check(d.maybeDelete(A), "held");
        check(e.calls.size() == 1 && e.calls.get(0).equals("disconnect"), "disconnect is the only call at return");
    }

    static void envFailureDuringHoldIsStock() {
        // a failure while the decision reads the device (before anything is sent) falls back to the stock delete
        FakeEnv e = new FakeEnv();
        e.dipoThrows = true;
        ProjectionDelete d = new ProjectionDelete(e);
        check(!d.maybeDelete(A), "stock on a read failure");
        check(e.disconnects == 0 && e.listens == 0, "nothing sent on a read failure");
    }

    public static void main(String[] args) {
        everyStockReason();
        listenerFailureIsStock();
        timerFailureIsStock();
        disconnectFailureIsStockAndForgotten();
        holdDisconnectsFirstAndDoesNotDelete();
        matchingEndBarrierThenDeleteOnce();
        endOfAnotherPeerIgnored();
        otherPpTypeOrWiredStatusIgnored();
        reconnectAfterEndCancels();
        connectBeforeEndIsNotAReconnect();
        dipoStillActiveWaitsThenDeletes();
        fifteenSecondFallbackDeletes();
        doubleRequestReusesPending();
        profileChangeAbortsDeletion();
        barrierFailureLeavesFallback();
        deleteFailureIsNotRetried();
        deletionCalledExactlyOnce();
        listenerRegisteredOnce();
        rowChangedOrGoneIsNotDeleted();
        disconnectRunsBeforeAnyWait();
        envFailureDuringHoldIsStock();
        reconnectDuringDeletionCancelsIt();
        System.out.println("ok projectiondelete 22 cases");
    }
}
