package hmgapi.mods.wireless.dipo;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.PriorityQueue;
import java.util.Set;

/**
 * ProjectionOwner (item 9, publish only) over a fake environment: a manual clock, owner-thread work
 * run explicitly, Phone Projection rows as a list. Deterministic: no sleeps, no threads.
 */
public final class ProjectionOwnerTest {
    static final String A = "80:96:98:05:D7:3D", B = "AA:BB:CC:DD:EE:FF";
    static final String DA = "DEV-A", DB = "DEV-B", MAC = "11:22:33:44:55:66";

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

    static final class FakeEnv implements ProjectionOwner.Env {
        boolean usable = true, activated, usb, throwOnActivated, postThrows;
        int user;
        int activatedCalls;
        final Set<String> bonded = new HashSet<String>();
        final List<ProjectionOwner.Record> rows = new ArrayList<ProjectionOwner.Record>();
        final List<String> log = new ArrayList<String>();
        /** "add A", "ready 1 A", "connect 3 A", "connect 4 A" in submission order */
        final List<String> sent = new ArrayList<String>();
        /** run right after a ready submission (profile changes between steps) */
        Runnable afterReady;
        private long clock, seq;
        private final ArrayDeque<Runnable> queue = new ArrayDeque<Runnable>();
        private final PriorityQueue<Timer> timers = new PriorityQueue<Timer>();

        @Override
        public boolean usable() {
            return usable;
        }

        @Override
        public long now() {
            return clock;
        }

        @Override
        public void post(Runnable r) {
            if (postThrows) throw new IllegalStateException("handler gone");
            queue.add(r);
        }

        @Override
        public void postDelayed(Runnable r, long delayMs) {
            timers.add(new Timer(clock + delayMs, seq++, r));
        }

        @Override
        public void log(String message) {
            log.add(message);
        }

        @Override
        public boolean isActivated() {
            activatedCalls++;
            if (throwOnActivated) throw new IllegalStateException("DiPO manager gone");
            return activated;
        }

        @Override
        public boolean isBonded(String addr) {
            return bonded.contains(addr);
        }

        @Override
        public boolean usbAttached() {
            return usb;
        }

        @Override
        public int userType() {
            return user;
        }

        @Override
        public ProjectionOwner.Record getRecord(String addr, String serial, int u) {
            for (ProjectionOwner.Record r : rows) {
                if (r.addr.equalsIgnoreCase(addr) && same(r.serial, serial) && r.user == u) return r;
            }
            return null;
        }

        @Override
        public void addRecord(ProjectionOwner.Record r) {
            sent.add("add " + r.addr);
            rows.add(r);
        }

        @Override
        public void reportReady(ProjectionOwner.Record r, int status) {
            sent.add("ready " + status + " " + r.addr);
            if (afterReady != null) afterReady.run();
        }

        @Override
        public void reportConnect(ProjectionOwner.Record r, int status) {
            sent.add("connect " + status + " " + r.addr);
        }

        /** runs the owner-thread work that is due now */
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

        int timers() {
            return timers.size();
        }

        int count(String prefix) {
            int n = 0;
            for (String s : log) if (s.startsWith(prefix)) n++;
            return n;
        }

        int countContains(String text) {
            int n = 0;
            for (String s : log) if (s.contains(text)) n++;
            return n;
        }

        boolean logHas(String text) {
            for (String s : log) if (s.contains(text)) return true;
            return false;
        }
    }

    static boolean same(String a, String b) {
        return a == null ? b == null : a.equals(b);
    }

    static ProjectionOwner.Record row(String addr, String serial, int user, int ppType, int transfer) {
        return new ProjectionOwner.Record(addr, "Phone", MAC, serial, user, ppType, transfer, false, true, true);
    }

    static FakeEnv env() {
        FakeEnv e = new FakeEnv();
        e.bonded.add(A);
        e.bonded.add(B);
        return e;
    }

    static void check(boolean ok, String message) {
        if (!ok) throw new AssertionError(message);
    }

    static void sentIs(FakeEnv e, String... want) {
        List<String> w = Arrays.asList(want);
        check(e.sent.equals(w), "sent " + e.sent + " want " + w + "\nlog " + e.log);
    }

    /** a normal session of the bridge's phone A: created, details, started */
    static void session(FakeEnv e, ProjectionOwner o, String addr, String deviceId, int transport) {
        o.created(addr);
        o.details(deviceId, MAC, "Phone");
        o.started(transport);
        e.settle();
    }

    static void normalPublishOnce() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        check(e.timers() == 0, "nothing polls once connected");
        e.advance(60000);
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
    }

    static void noPublishUntilActivatedPolls() {
        FakeEnv e = env();
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        sentIs(e);
        e.advance(1000);
        sentIs(e);
        check(e.activatedCalls > 1, "DiPO is polled while connect waits");
        e.activated = true;
        e.advance(249);
        sentIs(e);
        e.advance(1);
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        check(e.timers() == 0, "poll stops after publishing");
    }

    static void finalizedWhileActiveWaitsForInactive() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.finalized(1);
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        e.advance(5000);
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        e.activated = false;
        e.advance(250);
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
        e.advance(10000);
        check(e.count("owner: status 4") == 1, "exactly one end");
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
    }

    static void endCapPublishesAfter30s() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.finalized(1);
        e.settle();
        e.advance(29000);
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        e.advance(999);
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        e.advance(1);
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
        check(e.logHas("(cap)"), "cap logged");
        e.advance(60000);
        check(e.count("owner: status 4") == 1, "cap sends one end");
    }

    static void quickReconnectCarriesEnd() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.finalized(1);
        e.settle();
        o.created(A);
        o.details(DA, MAC, "Phone");
        o.started(1);
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        e.activated = false;
        e.advance(250);
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
        e.activated = true;
        e.advance(250);
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A, "ready 1 " + A, "connect 3 " + A);
        check(e.logHas("owner: status 4 gen=1 ") && e.logHas("owner: status 3 gen=2 "), "generations logged");
    }

    static void wiredAndUsbNeverPublished() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 0);
        o.finalized(0);
        e.settle();
        sentIs(e);
        session(e, o, A, DA, 2);
        sentIs(e);

        FakeEnv usb = env();
        usb.activated = true;
        usb.usb = true;
        usb.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner u = new ProjectionOwner(usb);
        session(usb, u, A, DA, 1);
        usb.advance(1000);
        sentIs(usb);
    }

    static void unbondedBlockedDeleted() {
        FakeEnv e = env();
        e.bonded.clear();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        e.advance(5000);
        sentIs(e);
        check(e.timers() == 0, "unbonded waits without polling");

        FakeEnv blocked = env();
        blocked.activated = true;
        blocked.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner b = new ProjectionOwner(blocked);
        b.userDisconnected(A);
        session(blocked, b, A, DA, 1);
        sentIs(blocked);
        b.bondRestored(A);
        blocked.settle();
        sentIs(blocked, "ready 1 " + A, "connect 3 " + A);

        FakeEnv deleted = env();
        deleted.activated = true;
        deleted.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner d = new ProjectionOwner(deleted);
        d.bondLost(A);
        session(deleted, d, A, DA, 1);
        sentIs(deleted);
        d.bondRestored(A);
        deleted.settle();
        sentIs(deleted, "ready 1 " + A, "connect 3 " + A);
    }

    static void userDisconnectWhileConnectedStillEnds() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.userDisconnected(A);
        e.settle();
        o.runningPP();
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        e.activated = false;
        o.finalized(1);
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
    }

    static void missingRowAdded() {
        FakeEnv e = env();
        e.activated = true;
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        sentIs(e, "add " + A, "ready 1 " + A, "connect 3 " + A);
        check(e.rows.size() == 1 && e.rows.get(0).ppType == 1 && e.rows.get(0).transfer == 1, "added row is wireless CarPlay");
        check(DA.equals(e.rows.get(0).serial) && e.rows.get(0).user == 0, "added row has the device id and profile");
    }

    static void rowRemovedDuringSessionStops() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        e.rows.clear();
        o.runningPP();
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        check(e.logHas("row removed during the session"), "removal logged");
        o.runningPP();
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        check(e.countContains("row removed during the session") == 1, "removal logged once");
        e.activated = false;
        o.finalized(1);
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
        check(!e.sent.contains("add " + A), "not registered again during the session");
    }

    static void nonWirelessRowNotReportedNotRewritten() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 0));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        e.advance(1000);
        sentIs(e);
        check(e.rows.size() == 1 && e.rows.get(0).transfer == 0, "row untouched");
        check(e.logHas("not reported and not rewritten"), "logged");

        FakeEnv aa = env();
        aa.activated = true;
        aa.rows.add(row(A, DA, 0, 2, 1));
        ProjectionOwner p = new ProjectionOwner(aa);
        session(aa, p, A, DA, 1);
        sentIs(aa);
        check(aa.rows.get(0).ppType == 2, "other ppType row untouched");
    }

    static void profileChangesBetweenSteps() {
        FakeEnv waiting = env();
        waiting.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner w = new ProjectionOwner(waiting);
        session(waiting, w, A, DA, 1);
        waiting.advance(500);
        waiting.user = 2;
        waiting.activated = true;
        waiting.advance(250);
        sentIs(waiting);
        check(waiting.logHas("profile changed"), "profile change logged while waiting");

        final FakeEnv between = env();
        between.activated = true;
        between.rows.add(row(A, DA, 0, 1, 1));
        between.afterReady = new Runnable() {
            @Override
            public void run() {
                between.user = 2;
            }
        };
        ProjectionOwner b = new ProjectionOwner(between);
        session(between, b, A, DA, 1);
        sentIs(between, "ready 1 " + A);
        check(between.logHas("profile changed before connected"), "profile change before 3");

        FakeEnv owed = env();
        owed.activated = true;
        owed.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(owed);
        session(owed, o, A, DA, 1);
        o.finalized(1);
        owed.settle();
        owed.user = 2;
        owed.activated = false;
        owed.advance(250);
        sentIs(owed, "ready 1 " + A, "connect 3 " + A);
        check(owed.logHas("end not sent, profile changed"), "owed end dropped on profile change");
    }

    static void duplicateStartedIsIdempotent() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        o.created(A);
        o.started(1);
        o.started(1);
        o.details(DA, MAC, "Phone");
        o.started(1);
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
        check(e.logHas("duplicate started"), "duplicate logged");
    }

    static void runningPPRepublishes() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.runningPP();
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "ready 1 " + A, "connect 3 " + A);
        check(e.logHas("republish status 3 gen=1 "), "republish logged with generation");
    }

    static void staleGenerationWorkDropped() {
        FakeEnv e = env();
        e.rows.add(row(A, DA, 0, 1, 1));
        e.rows.add(row(B, DB, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        session(e, o, B, DB, 1);
        // DiPO stays inactive: each live poll costs exactly one activation check, so a stale poll that ran would show
        int before = e.activatedCalls;
        e.advance(250);
        check(e.activatedCalls - before == 1, "only the current generation polls (stale poll dropped), calls " + (e.activatedCalls - before));
        sentIs(e);
        e.activated = true;
        e.advance(250);
        sentIs(e, "ready 1 " + B, "connect 3 " + B);
    }

    static void nullEnvironmentIsInert() {
        FakeEnv e = env();
        e.usable = false;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.finalized(1);
        o.runningPP();
        o.serviceDestroyed();
        o.userDisconnected(A);
        o.bondLost(B);
        e.settle();
        e.advance(60000);
        sentIs(e);
    }

    static void environmentFailureTurnsOwnerOff() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        e.throwOnActivated = true;
        session(e, o, A, DA, 1);
        check(e.count("owner: inactive") == 1, "one inactive line");
        e.throwOnActivated = false;
        o.runningPP();
        o.finalized(1);
        e.settle();
        e.advance(5000);
        sentIs(e);
    }

    static void entryPointsNeverThrow() {
        FakeEnv e = env();
        e.postThrows = true;
        ProjectionOwner o = new ProjectionOwner(e);
        o.serviceCreated();
        o.created(A);
        o.details(DA, MAC, "x");
        o.started(1);
        o.finalized(1);
        o.runningPP();
        o.serviceDestroyed();
        o.userDisconnected(A);
        o.bondLost(A);
        o.bondRestored(A);
        o.details(null, null, null);
        o.created(null);
        o.started(1);
        o.finalized(1);
        e.settle();
        sentIs(e);
    }

    static void detailsBeforeCreatedAttributes() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        o.details(DA, MAC, "Phone");
        o.created(A);
        o.started(1);
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);
    }

    static void unattributedSessionsAreNotReported() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        o.created(A);
        o.details("", MAC, "x");
        o.started(1);
        e.settle();
        sentIs(e);
        o.details(DA, MAC, "x");
        e.settle();
        sentIs(e, "ready 1 " + A, "connect 3 " + A);

        FakeEnv none = env();
        none.activated = true;
        none.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner n = new ProjectionOwner(none);
        n.created(null);
        n.details(DA, MAC, "x");
        n.started(1);
        none.settle();
        sentIs(none);
        check(none.logHas("no bridge address"), "no-address session logged");
    }

    static void otherLearnedPhoneNotAttributed() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        e.rows.add(row(B, DB, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        e.activated = false;
        o.finalized(1);
        e.settle();
        e.activated = true;
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
        session(e, o, B, DA, 1);
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
        check(e.logHas("belongs to another learned phone"), "other learned phone logged");
    }

    static void sameAddressOtherIdentityNotAttributed() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        e.activated = false;
        o.finalized(1);
        e.settle();
        e.activated = true;
        session(e, o, A, "DEV-OTHER", 1);
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
        check(e.logHas("differs from the learned peer"), "identity change logged");
    }

    static void serviceStopKeepsOwedEnd() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.finalized(1);
        e.settle();
        o.serviceDestroyed();
        e.settle();
        e.activated = false;
        e.advance(250);
        sentIs(e, "ready 1 " + A, "connect 3 " + A, "connect 4 " + A);
    }

    static void everyStatusLoggedWithGeneration() {
        FakeEnv e = env();
        e.activated = true;
        e.rows.add(row(A, DA, 0, 1, 1));
        ProjectionOwner o = new ProjectionOwner(e);
        session(e, o, A, DA, 1);
        o.runningPP();
        e.settle();
        e.activated = false;
        o.finalized(1);
        e.settle();
        int statuses = 0;
        for (String s : e.sent) if (s.startsWith("ready ") || s.startsWith("connect ")) statuses++;
        int logged = 0;
        for (String line : e.log) {
            if (line.startsWith("owner: status ") || line.startsWith("owner: republish status ")) {
                logged++;
                check(line.contains(" gen="), "status line has its generation: " + line);
            }
        }
        check(statuses == 5 && logged == statuses, "statuses " + statuses + " logged " + logged + " in " + e.log);
    }

    public static void main(String[] args) {
        normalPublishOnce();
        noPublishUntilActivatedPolls();
        finalizedWhileActiveWaitsForInactive();
        endCapPublishesAfter30s();
        quickReconnectCarriesEnd();
        wiredAndUsbNeverPublished();
        unbondedBlockedDeleted();
        userDisconnectWhileConnectedStillEnds();
        missingRowAdded();
        rowRemovedDuringSessionStops();
        nonWirelessRowNotReportedNotRewritten();
        profileChangesBetweenSteps();
        duplicateStartedIsIdempotent();
        runningPPRepublishes();
        staleGenerationWorkDropped();
        nullEnvironmentIsInert();
        environmentFailureTurnsOwnerOff();
        entryPointsNeverThrow();
        detailsBeforeCreatedAttributes();
        unattributedSessionsAreNotReported();
        otherLearnedPhoneNotAttributed();
        sameAddressOtherIdentityNotAttributed();
        serviceStopKeepsOwedEnd();
        everyStatusLoggedWithGeneration();
        System.out.println("ok projectionowner 25 cases");
    }
}
