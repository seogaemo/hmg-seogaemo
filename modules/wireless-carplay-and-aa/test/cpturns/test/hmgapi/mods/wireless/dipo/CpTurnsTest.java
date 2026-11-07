package hmgapi.mods.wireless.dipo;

import com.tcc.iap2.Iap2NotiMsg;

import java.util.Calendar;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import hmgapi.hook.Car;
import hmgapi.hook.Cluster;

/**
 * Host test of CpTurns: a drive through iAP2 route guidance messages, checking every
 * cluster call against what the turn-by-turn build's DiPO manager (e/u, e/c, e/v)
 * sends for the same input (worked out from its smali).
 */
public final class CpTurnsTest {
    static int fail;
    static Cluster c;

    static void expect(String what, String... want) {
        List<String> got = c.calls;
        // The once-per-session junction clear is asserted on its own (CpJunctionLifecycleTest).
        String start = "junction 65535 65535 65535";
        List<String> seen = new java.util.ArrayList<String>(got);
        if (!seen.isEmpty() && seen.get(0).equals(start) && (want.length == 0 || !want[0].equals(start))) seen.remove(0);
        String w = String.join("\n", want), g = String.join("\n", seen);
        if (w.equals(g)) {
            System.out.println("ok    " + what);
        } else {
            System.out.println("FAIL  " + what + "\n  wanted:\n    " + w.replace("\n", "\n    ") + "\n  got:\n    " + g.replace("\n", "\n    "));
            fail = 1;
        }
        got.clear();
    }

    static void check(String what, boolean ok) {
        System.out.println((ok ? "ok    " : "FAIL  ") + what);
        if (!ok) fail = 1;
    }

    static String utf16(String s) {
        StringBuilder b = new StringBuilder();
        for (char ch : s.toCharArray()) b.append(String.format("%02x%02x", ch & 0xff, ch >> 8));
        String r = b.toString();
        while (r.endsWith("00")) r = r.substring(0, r.length() - 2);
        return r;
    }

    /** iAP2 types: 1/5 small ints, 6 uint32, 7 uint64, 8 enum, 10 string, 13 groups */
    static final int U8 = 1, U16 = 5, U32 = 6, U64 = 7, ENUM = 8, STR = 10, GROUPS = 13;

    static Iap2NotiMsg msg(Object... items) {
        Iap2NotiMsg m = new Iap2NotiMsg();
        for (int i = 0; i < items.length; i += 3) m.getItemGroup().add((Integer) items[i], (Integer) items[i + 1], items[i + 2]);
        return m;
    }

    static int[] i(int... v) {
        return v;
    }

    static long[] l(long... v) {
        return v;
    }

    static String[] s(String v) {
        return new String[] { v };
    }

    /** a RouteGuidanceManeuverUpdate for component 1 */
    static Iap2NotiMsg maneuver(int index, int type, int side, int junction, int exit, String after, int distance) {
        return msg(0, U16, i(1), 1, U16, i(index), 3, ENUM, i(type), 4, STR, s(after), 5, U32, i(distance),
                8, ENUM, i(side), 9, ENUM, i(junction), 11, U8, i(exit));
    }

    public static void main(String[] a) throws Exception {
        java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("UTC"));
        Car.unit = Car.DISTANCE_MILES;
        c = new Cluster();
        final CountDownLatch restarted = new CountDownLatch(1);
        CpTurns t = new CpTurns(new android.content.Context(), c, new Runnable() {
            @Override
            public void run() {
                restarted.countDown();
            }
        });
        final int RIGHT = 2, LEFT = 1, STRAIGHT = 3, UTURN = 4, ARRIVE = 12, MILES = 1, KM = 0, FEET = 4;

        t.maneuver(maneuver(0, RIGHT, 0, 0, 90, "Main St", 300));
        t.maneuver(maneuver(1, LEFT, 0, 0, -90, "Oak Ave", 800));
        t.maneuver(maneuver(2, STRAIGHT, 0, 0, 0, "Elm St", 0));
        t.maneuver(maneuver(3, UTURN, 0, 0, 0, "Pine St", 2000));
        expect("maneuvers alone: nothing sent");

        t.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(1), 7, U32, i(5000), 9, ENUM, i(MILES), 11, STR, s("0.2"),
                12, ENUM, i(MILES), 13, U16, i(0, 1, 2, 3), 5, U64, l(1700000000L), 19, STR, s("Maps")));
        expect("right turn in 0.2 mi: crossroad, turn, HUD list with the next turn, HUD distance, trip, turns ahead",
                "road [Main St]", "tbt 67 0 0.0 0.2 0 0 2 0 0", "hud f202434600" + utf16("Main St"), "2c 2 2 0 0 0 0 0 0 0",
                "sub 3.1 0 2 22 13 1 1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] " + (800 / 1609f) + " 2} {2 72 0 [Pine St] [] " + (2000 / 1609f) + " 2}");

        t.routeGuidance(msg(0, U16, i(1), 11, STR, s("0.1")));
        expect("partial update (distance only): same HUD list not resent",
                "road [Main St]", "tbt 67 0 0.0 0.1 0 0 2 0 0", "2c 2 1 0 0 0 0 0 0 0", "sub 3.1 0 2 22 13 1 1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] " + (800 / 1609f) + " 2} {2 72 0 [Pine St] [] " + (2000 / 1609f) + " 2}");

        Iap2NotiMsg lanes = new Iap2NotiMsg();
        Iap2NotiMsg.Iap2ObjGroup l1 = lanes.new Iap2ObjGroup(), l2 = lanes.new Iap2ObjGroup();
        l1.add(1, U16, i(1)).add(2, U16, i(0));
        l2.add(2, U16, i(90, 45)).add(3, U16, i(90));
        lanes.getItemGroup().add(0, U16, i(1)).add(2, GROUPS, new Iap2NotiMsg.Iap2ObjGroup[] { l1, l2 });
        new CpTurns(new android.content.Context(), c, null).lanes(lanes);
        StringBuilder z = new StringBuilder();
        for (int k = 0; k < 14; k++) z.append("00");
        expect("lanes: straight; right + slight right as the 18 + 21 pair, route right white, slight right grey (status 0d)", "lanes f10200010d" + z + "0100001215");

        Car.unit = Car.DISTANCE_KM;
        t.routeGuidance(msg(0, U16, i(1), 7, U32, i(800), 11, STR, s("1.5"), 12, ENUM, i(KM)));
        expect("km: turn in the phone's km, trip in m (owner's km, under 1 km), turns ahead in m/km",
                "road [Main St]", "tbt 67 0 0.0 1.5 0 0 1 0 0", "2c 1 5 1 0 0 0 0 0 0", "sub 800.0 0 0 22 13 1 1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] 800.0 0} {2 72 0 [Pine St] [] 2.0 1}");
        Car.unit = Car.DISTANCE_MILES;

        t.maneuver(msg(0, U16, i(1), 1, U16, i(0), 5, U32, i(250)));
        t.routeGuidance(msg(0, U16, i(1), 11, STR, s("0.1"), 12, ENUM, i(MILES)));
        expect("maneuver update without its exit angle (Apple Maps in Korea sends none): the right-turn type alone gives the right arrow, HUD list not resent",
                "road [Main St]", "tbt 67 0 0.0 0.1 0 0 2 0 0", "2c 2 1 0 0 0 0 0 0 0", "sub 0.4 0 2 22 13 1 1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] 0.49720323 2} {2 72 0 [Pine St] [] 1.2430081 2}");
        t.routeGuidance(msg(0, U16, i(1), 11, STR, s("0.1"), 12, ENUM, i(MILES)));
        expect("(the update above, still without its exit angle: same arrow, HUD list not resent)",
                "road [Main St]", "tbt 67 0 0.0 0.1 0 0 2 0 0", "2c 2 1 0 0 0 0 0 0 0", "sub 0.4 0 2 22 13 1 1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] 0.49720323 2} {2 72 0 [Pine St] [] 1.2430081 2}");
        t.maneuver(maneuver(0, RIGHT, 0, 0, 90, "Main St", 250));

        t.routeGuidance(msg(0, U16, i(1), 7, U32, i(100), 6, U64, l(0), 5, U64, l(0)));
        expect("trip under 161 m with miles: feet; no arrival time (same right arrow, HUD list not resent)",
                "road [Main St]", "tbt 67 0 0.0 0.1 0 0 2 0 0", "2c 2 1 0 0 0 0 0 0 0", "sub 328.0 0 3 -1 -1 -1 -1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] " + (800 / 1609f) + " 2} {2 72 0 [Pine St] [] " + (2000 / 1609f) + " 2}");

        t.routeGuidance(msg(0, U16, i(1), 7, U32, i(0), 6, U64, l(600)));
        Calendar in10 = Calendar.getInstance();
        in10.add(Calendar.SECOND, 600);
        expect("arrival from the time remaining (no distance)",
                "road [Main St]", "tbt 67 0 0.0 0.1 0 0 2 0 0", "2c 2 1 0 0 0 0 0 0 0",
                "sub 0.0 -1 0 " + in10.get(Calendar.HOUR_OF_DAY) + " " + in10.get(Calendar.MINUTE) + " 1 1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] " + (800 / 1609f) + " 2} {2 72 0 [Pine St] [] " + (2000 / 1609f) + " 2}");

        t.routeGuidance(msg(0, U16, i(1), 6, U64, l(0), 5, U64, l(600000000L)));
        expect("arrival as seconds since 2001 (Apple's epoch): 2020-01-06 10:40",
                "road [Main St]", "tbt 67 0 0.0 0.1 0 0 2 0 0", "2c 2 1 0 0 0 0 0 0 0", "sub 0.0 -1 0 10 40 1 1 0.0 -1 0",
                "list {1 70 0 [Oak Ave] [] " + (800 / 1609f) + " 2} {2 72 0 [Pine St] [] " + (2000 / 1609f) + " 2}");

        t.routeGuidance(msg(0, U16, i(1), 19, STR, s("Waze"), 5, U64, l(0)));
        check("source change: route guidance restarted", restarted.await(2, TimeUnit.SECONDS));
        expect("source change (Maps to Waze): HUD cleared; the reset state is 0 until the phone resends it, so cleared again and the cluster goes idle",
                "2c 0 0 0 0 0 0 0 0 0", "lanes f1", "hud f2", "hud f2", "2c 0 0 0 0 0 0 0 0 0", "lanes f1", "hud f2", "hud f2",
                "tbt 8 0 0.0 0.0 -1 0 0 0 -1", "sub 0.0 -1 0 0 0 0 0 0.0 -1 0");

        t.maneuver(maneuver(5, ARRIVE, 0, 0, 0, "Home Rd", 100));
        t.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(6), 4, STR, s("Home"), 11, STR, s("300"), 12, ENUM, i(FEET), 13, U16, i(5)));
        expect("state 6 with destination, arrival maneuver in 300 ft",
                "dest 0 [Home]", "road [Home Rd]", "tbt 112 0 0.0 300.0 0 0 3 0 0", "hud f201700000" + utf16("Home Rd"),
                "2c 3 0 300 0 0 0 0 0 0");

        t.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(2)));
        expect("arrived (state 2): icon 3, no HUD list for it", "road [Home Rd]", "tbt 3 0 0.0 300.0 0 0 3 0 0", "2c 3 0 300 0 0 0 0 0 0");

        t.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(0)));
        expect("state 0: HUD cleared, cluster back to the idle compass", "2c 0 0 0 0 0 0 0 0 0", "lanes f1", "hud f2", "hud f2",
                "tbt 8 0 0.0 0.0 -1 0 0 0 -1", "sub 0.0 -1 0 0 0 0 0 0.0 -1 0");

        t.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(1)));
        t.stop();
        c.calls.clear();
        t.stop();
        expect("route guidance stopped (car took turn-by-turn back): HUD cleared; the cluster is already idle", "2c 0 0 0 0 0 0 0 0 0", "lanes f1", "hud f2", "hud f2");

        t.disconnected();
        expect("iAP2 session ended: HUD cleared; the cluster is already idle", "2c 0 0 0 0 0 0 0 0 0", "lanes f1", "hud f2", "hud f2");
        t.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(1), 11, STR, s("0.5"), 12, ENUM, i(MILES), 13, U16, i(5), 19, STR, s("Maps")));
        expect("after the session ended: maneuvers gone (HUD distance only), a new source isn't a change; a new guidance session clears a stock junction view once",
                "junction 65535 65535 65535", "2c 2 5 0 0 0 0 0 0 0");
        c.calls.clear();

        t.maneuver(msg(0, U16, i(7), 1, U16, i(0), 3, ENUM, i(LEFT), 4, STR, s("Comp 7 Rd"), 8, ENUM, i(0), 9, ENUM, i(0), 11, U8, i(-60)));
        t.routeGuidance(msg(0, U16, i(7), 1, ENUM, i(1), 11, STR, s("0.3"), 12, ENUM, i(MILES), 13, U16, i(0)));
        expect("a second component keeps its own state", "road [Comp 7 Rd]", "tbt 71 0 0.0 0.3 0 0 2 0 0",
                "hud f201470000" + utf16("Comp 7 Rd"), "2c 2 3 0 0 0 0 0 0 0");

        t.maneuver(msg(1, U16, i(0), 3, ENUM, i(STRAIGHT), 4, STR, s("Any Rd"), 8, ENUM, i(0), 9, ENUM, i(0)));
        t.routeGuidance(msg(1, ENUM, i(1), 11, STR, s("0.4"), 13, U16, i(0)));
        expect("no component ids: every known component gets it",
                "road [Any Rd]", "tbt 65 0 0.0 0.4 0 0 2 0 0", "hud f201410000" + utf16("Any Rd"), "2c 2 4 0 0 0 0 0 0 0",
                "road [Any Rd]", "tbt 65 0 0.0 0.4 0 0 2 0 0", "2c 2 4 0 0 0 0 0 0 0");

        t.routeGuidance(msg(0, U16, i(0), 1, ENUM, i(1), 11, STR, s("0.4"), 13, U16, i(0)));
        expect("component 0's first update: DiPO starts it empty (state 0), so the HUD is cleared and the cluster goes idle",
                "2c 0 0 0 0 0 0 0 0 0", "lanes f1", "hud f2", "hud f2",
                "tbt 8 0 0.0 0.0 -1 0 0 0 -1", "sub 0.0 -1 0 0 0 0 0 0.0 -1 0");

        check("icons: sharp left 69, slight right 66, roundabout exit 96/97, U-turn left-hand traffic 73",
                CpTurns.icon(1, 0, 0, -120, 1) == 69 && CpTurns.icon(2, 0, 0, 60, 1) == 66 && CpTurns.icon(2, 0, 1, 0, 1) == 96
                        && CpTurns.icon(31, 1, 1, 0, 1) == 96 && CpTurns.icon(4, 1, 0, 0, 1) == 73 && CpTurns.icon(47, 0, 0, -140, 1) == 69
                        && CpTurns.icon(99, 0, 0, 0, 1) == 0);
        Iap2NotiMsg lm = new Iap2NotiMsg();
        Iap2NotiMsg.Iap2ObjGroup pref = lm.new Iap2ObjGroup(), along = lm.new Iap2ObjGroup(), off = lm.new Iap2ObjGroup();
        pref.add(1, U16, i(2)).add(2, U16, i(0)).add(3, U16, i(0));
        along.add(1, U16, i(1)).add(2, U16, i(0, 90)).add(3, U16, i(0));
        off.add(1, U16, i(0)).add(2, U16, i(90));
        // pref / off have one arrow; along has two (straight + right), route straight
        check("lane colours: preferred lane blue, a good lane white on its route arrow and grey on the other, a not-good lane grey",
                CpTurns.laneOne(pref)[0] == 2 && CpTurns.laneOne(along)[0] == 0x0d && CpTurns.laneOne(off)[0] == 3);
        Iap2NotiMsg.Iap2ObjGroup[] withPref = { along, pref, off }, noPref = { along, off };
        Iap2NotiMsg am = new Iap2NotiMsg();
        am.getItemGroup().add(0, U16, i(1)).add(2, GROUPS, withPref);
        t.lanes(am);
        Iap2NotiMsg am2 = new Iap2NotiMsg();
        am2.getItemGroup().add(0, U16, i(1)).add(2, GROUPS, noPref);
        t.lanes(am2);
        StringBuilder z13 = new StringBuilder();
        for (int k = 0; k < 13; k++) z13.append("00");
        expect("lanes: colours follow each lane's own status, whether or not another lane is preferred",
                "lanes f10300" + "0d0203" + z13 + "101200" + "010000" + "03", "lanes f10200" + "0d03" + z + "101200" + "03");
        t.sendHudDist(0.96f, Cluster.UNIT_MI);
        t.sendHudDist(1.97f, Cluster.UNIT_KM);
        t.sendHudDist(0.1f, Cluster.UNIT_MI);
        t.sendHudDist(250f, Cluster.UNIT_M);
        t.sendHudDist(5000f, Cluster.UNIT_M);
        expect("HUD distance to the nearest tenth, carried: 0.96 mi is 1.0, 1.97 km is 2.0, 0.1 mi stays, metres whole, capped at 4095",
                "2c 2 0 1 0 0 0 0 0 0", "2c 1 0 2 0 0 0 0 0 0", "2c 2 1 0 0 0 0 0 0 0", "2c 0 0 250 0 0 0 0 0 0", "2c 0 0 4095 0 0 0 0 0 0");
        check("angles the exact table skips get the nearest arrow: 75 right 67, -75 left 70, 30 right 66, -30 left 71, 150 right 68, -150 left 69",
                CpTurns.icon(2, 0, 0, 75, 1) == 67 && CpTurns.icon(1, 0, 0, -75, 1) == 70 && CpTurns.icon(2, 0, 0, 30, 1) == 66
                        && CpTurns.icon(1, 0, 0, -30, 1) == 71 && CpTurns.icon(2, 0, 0, 150, 1) == 68 && CpTurns.icon(1, 0, 0, -150, 1) == 69);
        check("left-hand traffic: -90 left 70, 90 right 67 (the exact table needed right-hand traffic)",
                CpTurns.icon(1, 1, 0, -90, 1) == 70 && CpTurns.icon(2, 1, 0, 90, 1) == 67);
        check("a type that says sharp or slight keeps it at any angle: 48 sharp right 68, 47 sharp left 69, 49 slight left 71, 50 slight right 66",
                CpTurns.icon(48, 0, 0, 100, 1) == 68 && CpTurns.icon(47, 0, 0, -100, 1) == 69 && CpTurns.icon(49, 0, 0, -10, 1) == 71
                        && CpTurns.icon(50, 0, 0, 100, 1) == 66);
        check("still nothing: no angle (0), a roundabout at an unlisted angle, an unknown type",
                CpTurns.icon(1, 0, 0, 0, 1) == 0 && CpTurns.icon(2, 0, 0, 0, 1) == 0 && CpTurns.icon(1, 0, 1, -75, 1) == 0
                        && CpTurns.icon(99, 0, 0, 75, 1) == 0);
        {
            CpTurns r = new CpTurns(new android.content.Context(), c, null);
            c.calls.clear();
            r.maneuver(maneuver(0, RIGHT, 0, 0, 90, "Main St", 300));
            r.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(1), 7, U32, i(5000), 9, ENUM, i(MILES), 11, STR, s("0.2"), 12, ENUM, i(MILES), 13, U16, i(0)));
            c.calls.clear();
            r.refresh();
            check("refresh right after a phone update sends nothing", c.calls.isEmpty());
            r.hudAt -= CpTurns.HUD_RESEND_MS + 1000L;
            r.refresh();
            check("HUD list resent unchanged after 2 s even while phone updates keep coming (" + c.calls + ")",
                    c.calls.size() == 1 && c.calls.get(0).startsWith("hud f2"));
            c.calls.clear();
            r.refresh();
            check("not again right away", c.calls.isEmpty());
            r.lastSendAt -= 5000L;
            r.refresh();
            boolean again = false;
            for (String k : c.calls) if (k.startsWith("tbt 67 0 0.0 0.2")) again = true;
            check("refresh without fresh phone data resends the turn (" + c.calls + ")", again);
            c.calls.clear();
            r.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(0)));
            c.calls.clear();
            r.lastSendAt -= 5000L;
            r.hudAt -= 5000L;
            r.refresh();
            check("no refresh (and no HUD resend) once guidance state is 0", c.calls.isEmpty() && r.lastHud == null);
        }
        check("match kinds: exact, band, angle, semantic, blank",
                "exact".equals(CpTurns.matchKind(2, 0, 0, 90, 1)) && "semantic".equals(CpTurns.matchKind(2, 0, 0, 0, 1)) && "band".equals(CpTurns.matchKind(2, 0, 0, 75, 1))
                        && "angle".equals(CpTurns.matchKind(8, 0, 0, -75, 1)) && "semantic".equals(CpTurns.matchKind(13, 0, 0, 0, 1))
                        && "blank".equals(CpTurns.matchKind(8, 0, 0, 0, 1)));
        boolean sawBlank = false, sawLane = false;
        for (String o : Dipo.observed) {
            if (o.startsWith("icon type=2 junction=0 side=0 exit~0 => icon=67 kind=semantic exit=0")) sawBlank = true;
            if (o.startsWith("lane n=2")) sawLane = true;
        }
        check("observations: the blank mapping and the lane sighting were recorded (" + Dipo.observed.size() + ")", sawBlank && sawLane && Dipo.flushes > 0);
        check("observations: exit angles keyed by 15-degree buckets", CpTurns.exitBucket(37) == 30 && CpTurns.exitBucket(38) == 45 && CpTurns.exitBucket(-97) == -90 && CpTurns.exitBucket(0) == 0);
        Dipo.dev = false;
        Dipo.logs.clear();
        CpTurns quiet = new CpTurns(new android.content.Context(), new Cluster(), null);
        quiet.routeGuidance(msg(0, U16, i(1), 1, ENUM, i(1), 13, U16, i(0)));
        boolean verbose = false;
        for (String l : Dipo.logs) if (l.startsWith("TBT rg update") || l.startsWith("TBT turn")) verbose = true;
        check("developer toggle off: only the essential first-update line is logged (" + Dipo.logs + ")", !verbose && Dipo.logs.size() == 1);
        Dipo.dev = true;
        check("fallback with an angle, any type: off-ramp (8) -75 slight/normal left 70, 8 at +130 sharp right 68, 8 at +10 straight 65, U-turn by angle 72/73",
                CpTurns.fallbackIcon(8, 0, 0, -75) == 70 && CpTurns.fallbackIcon(8, 0, 0, 130) == 68 && CpTurns.fallbackIcon(8, 0, 0, 10) == 65
                        && CpTurns.fallbackIcon(8, 0, 0, 170) == 72 && CpTurns.fallbackIcon(8, 1, 0, -170) == 73 && CpTurns.fallbackIcon(8, 0, 0, -40) == 71);
        check("fallback roundabout exits by angle: -75 -> 105, 100 -> 99, 130 -> 100, 175 -> 102, -30 -> 107",
                CpTurns.fallbackIcon(7, 0, 1, -75) == 105 && CpTurns.fallbackIcon(7, 0, 1, 100) == 99 && CpTurns.fallbackIcon(7, 0, 1, 130) == 100
                        && CpTurns.fallbackIcon(7, 0, 1, 175) == 102 && CpTurns.fallbackIcon(1, 0, 1, -30) == 107);
        check("fallback by meaning, no angle: keep left 71, keep right 66, enter roundabout 96/97, arrive 112, ferry 176, U-turn 72/73",
                CpTurns.fallbackIcon(13, 0, 0, 0) == 71 && CpTurns.fallbackIcon(14, 0, 0, 0) == 66 && CpTurns.fallbackIcon(6, 0, 1, 0) == 96
                        && CpTurns.fallbackIcon(6, 1, 1, 0) == 97 && CpTurns.fallbackIcon(12, 1, 0, 0) == 112 && CpTurns.fallbackIcon(15, 0, 1, 0) == 176
                        && CpTurns.fallbackIcon(4, 0, 0, 0) == 72 && CpTurns.fallbackIcon(4, 1, 0, 0) == 73);
        check("left/right turn without an angle: the type's arrow (70/67); off-ramp, unknown type, start route -> 8 (no icon)",
                CpTurns.fallbackIcon(1, 0, 0, 0) == 70 && CpTurns.fallbackIcon(2, 0, 0, 0) == 67 && CpTurns.fallbackIcon(8, 0, 0, 0) == CpTurns.NO_ICON
                        && CpTurns.fallbackIcon(99, 0, 0, 0) == CpTurns.NO_ICON && CpTurns.fallbackIcon(11, 0, 0, 0) == CpTurns.NO_ICON);
        check("turns ahead for sharp/slight types: 47 -> 69, 48 -> 68, 49 -> 71, 50 -> 66",
                CpTurns.aheadIcon(47, 0, 0, 0) == 69 && CpTurns.aheadIcon(48, 0, 0, 0) == 68 && CpTurns.aheadIcon(49, 0, 0, 0) == 71
                        && CpTurns.aheadIcon(50, 0, 0, 0) == 66 && CpTurns.aheadIcon(99, 0, 0, 0) == 64);
        check("lane angles: 0 straight, 90 right, -45 slight left, 180 back",
                CpTurns.laneIcon(0) == 1 && CpTurns.laneIcon(90) == 3 && CpTurns.laneIcon(-45) == 8 && CpTurns.laneIcon(180) == 5
                        && CpTurns.laneIcon(270) == 7);

        // lane glyph pairs and per-arrow status (.agents/cluster-lane-arrows.md)
        // status per slot: 00 blank, 01 white, 10 blue, 11 grey; arrows off the route are grey
        laneIs("U-turn + left, good lane, route left: U-turn grey, left white", CpTurns.laneValues(1, i(180, -90), i(-90)), 0x07, 10, 14);
        laneIs("U-turn + left listed left first: same slots", CpTurns.laneValues(1, i(-90, 180), i(-90)), 0x07, 10, 14);
        laneIs("U-turn + left, preferred lane, route left: left blue", CpTurns.laneValues(2, i(180, -90), i(-90)), 0x0b, 10, 14);
        laneIs("U-turn + left, not-good lane: both grey", CpTurns.laneValues(0, i(180, -90), i(-90)), 0x0f, 10, 14);
        laneIs("U-turn + left, good lane, route U-turn", CpTurns.laneValues(1, i(180, -90), i(180)), 0x0d, 10, 14);
        laneIs("U-turn + left, preferred lane, route U-turn", CpTurns.laneValues(2, i(180, -90), i(180)), 0x0e, 10, 14);
        laneIs("straight + left, good lane, route straight: 9 + 12, white + grey", CpTurns.laneValues(1, i(0, -90), i(0)), 0x0d, 9, 12);
        laneIs("straight + left, good lane, route left: grey + white", CpTurns.laneValues(1, i(0, -90), i(-90)), 0x07, 9, 12);
        laneIs("left + straight + right, preferred, route right: 28 22 24, blue on the right only", CpTurns.laneValues(2, i(-90, 0, 90), i(90)), 0x2f, 28, 22, 24);
        laneIs("left + straight + right listed in another order, good, route straight", CpTurns.laneValues(1, i(90, -90, 0), i(0)), 0x37, 28, 22, 24);
        laneIs("sharp left + straight + slight right is not listed: snapped to left + straight + right", CpTurns.laneValues(2, i(-135, 0, 45), i(45)), 0x2f, 28, 22, 24);
        laneIs("slight left + slight right is listed as is: 30 + 33", CpTurns.laneValues(1, i(-45, 45), i(-45)), 0x0d, 30, 33);
        laneIs("sharp + slight left snap to one left glyph", CpTurns.laneValues(1, i(-135, -45), i(-45)), 0x01, 7);
        laneIs("... preferred: blue", CpTurns.laneValues(2, i(-135, -45), i(-45)), 0x02, 7);
        laneIs("four directions, preferred: only the highlighted arrow, right (3), blue", CpTurns.laneValues(2, i(-90, 0, 90, 180), i(90)), 0x02, 3);
        laneIs("four directions, good lane with no highlight: the first arrow, white", CpTurns.laneValues(1, i(-90, 0, 90, 180), i(1000)), 0x01, 7);
        laneIs("four directions, preferred with no highlight: the first arrow, blue", CpTurns.laneValues(2, i(-90, 0, 90, 180), i(1000)), 0x02, 7);
        laneIs("four directions, not-good lane: the first arrow, grey", CpTurns.laneValues(0, i(-90, 0, 90, 180), i(1000)), 0x03, 7);
        laneIs("preferred without a highlight: every arrow blue", CpTurns.laneValues(2, i(0, -90), i(1000)), 0x0a, 9, 12);
        laneIs("good lane without a highlight: every arrow white", CpTurns.laneValues(1, i(0, -90), i(1000)), 0x05, 9, 12);
        // Android Auto lanes are the equivalent CarPlay lanes: a highlighted direction is a status 1 lane with that highlight,
        // a lane without one is status 0 (highlight 1000) while another lane is highlighted, status 1 when none is; never blue
        int[] angleOf = { 0, 0, 45, 90, 135, 180, -135, -90, -45 };
        boolean same = true, noBlue = true;
        for (int c1 = 1; c1 <= 8; c1++) for (int c2 = 0; c2 <= 8; c2++) for (int mask = 0; mask < 4; mask++) {
            if (c1 == c2) continue;
            int[] arrows = c2 == 0 ? new int[] { c1 } : new int[] { c1, c2 };
            if (mask >= 1 << arrows.length) continue;
            int[] angles = arrows.length == 1 ? i(angleOf[c1]) : i(angleOf[c1], angleOf[c2]);
            for (int other = 0; other < 2; other++) {   // another lane of the frame is highlighted, or none
                int[] aa = CpLaneFrame.lane(arrows, mask, mask != 0 || other == 0 ? 1 : 0);
                int[] high = mask == 0 ? i(1000) : mask == 3 ? i(angleOf[c1], angleOf[c2]) : mask == 1 ? i(angleOf[c1]) : i(angleOf[c2]);
                int[] cpv = CpTurns.laneValues(mask != 0 || other == 0 ? 1 : 0, angles, high);
                same &= java.util.Arrays.equals(aa, cpv);
                for (int j = 0; j < 3; j++) noBlue &= (aa[0] >> 2 * j & 3) != 2;
            }
        }
        check("Android Auto lanes equal the equivalent CarPlay lanes (status 1 highlighted, status 0 other lanes)", same);
        check("Android Auto lanes are never blue (no must-use signal)", noBlue);
        laneIs("a highlight that matches no arrow counts as none", CpTurns.laneValues(1, i(0, -90), i(45)), 0x05, 9, 12);
        laneIs("single direction keeps the plain glyph; two angles of one direction are one arrow", CpTurns.laneValues(2, i(85, 95), i(95)), 0x02, 3);
        laneIs("a not-good single arrow is grey", CpTurns.laneValues(0, i(90), i(1000)), 0x03, 3);
        laneIs("angle outside -180..180 is skipped", CpTurns.laneValues(1, i(1000, 90), i(1000)), 0x01, 3);
        laneIs("a status that is not 0..2 counts as good", CpTurns.laneValues(-1, i(90), i(1000)), 0x01, 3);
        check("no usable angle: the lane's value on slot 0 only (preferred blue, good white, not good grey)",
                CpTurns.laneValues(2, null, i(1000))[0] == 2 && CpTurns.laneValues(1, null, i(1000))[0] == 1
                        && CpTurns.laneValues(0, null, i(1000))[0] == 3 && CpTurns.laneValues(2, null, i(1000))[1] == 0);

        // lane distance beside the lane strip: updateRemainDis(distance, unit, tenths, 0)
        Cluster rc = new Cluster();
        CpTurns rt = new CpTurns(new android.content.Context(), rc, null);
        CpLaneDecoder.Info rinfo = new CpLaneDecoder.Info(1, 7, new CpLaneDecoder.Lane[] {
                new CpLaneDecoder.Lane(0, 2, i(0, -90), 0) }, 0);
        rt.rawLanes(rinfo);
        rt.routeGuidance(laneUpdate(7, true, "1.2", KM));
        check("lane distance 1.2 km: 1 km 2 tenths, toll gate 0", remains(rc).equals("[remain 1 1 2 0]"));
        rt.routeGuidance(laneUpdate(7, true, "1.2", KM));
        check("the same distance is not sent again at once", remains(rc).equals("[]"));
        rt.routeGuidance(laneUpdate(7, true, "150", 2));
        check("150 m: whole metres, no tenths", remains(rc).equals("[remain 150 0 0 0]"));
        rt.routeGuidance(laneUpdate(7, true, "0.4", MILES));
        check("0.4 mi: unit 2, 4 tenths", remains(rc).equals("[remain 0 2 4 0]"));
        rt.routeGuidance(laneUpdate(7, true, "100", 3));
        check("100 yd goes out as 91 m", remains(rc).equals("[remain 91 0 0 0]"));
        rt.lastSendAt = 0;
        rt.laneDistAt = 0L;
        rt.refresh();
        check("refresh resends the lane distance once the resend interval has passed", remains(rc).equals("[remain 91 0 0 0]"));
        rt.routeGuidance(laneUpdate(7, false, "100", 3));
        check("lanes hidden: the distance box is cleared with 65535 15 15 0", remains(rc).equals("[remain 65535 15 15 0]"));
        rt.routeGuidance(laneUpdate(7, false, "90", 3));
        check("no more lane distance while no lanes show", remains(rc).equals("[]"));
        rt.routeGuidance(laneUpdate(7, true, "2.0", KM));
        check("lanes back: the distance is sent again", remains(rc).equals("[remain 2 1 0 0]"));
        java.lang.reflect.Field lastLaneField = CpTurns.class.getDeclaredField("lastLane");
        lastLaneField.setAccessible(true);
        byte[] lastFrame = (byte[]) lastLaneField.get(rt);
        check("lane frame keeps the trailer bytes 0x43..0x50 zero", lastFrame != null && lastFrame[1] == 1 && allZero(lastFrame, 0x43, 0x50));
        rt.stop();
        check("route guidance stopped: the distance box is cleared", remains(rc).equals("[remain 65535 15 15 0]"));

        // an unmapped turn (icon 8) blanks the HUD instead of leaving the last arrow up
        Cluster hc = new Cluster();
        CpTurns ht = new CpTurns(new android.content.Context(), hc, null);
        ht.sendHud(67, 1, null);
        ht.sendHud(CpTurns.NO_ICON, 1, null);
        ht.sendHud(CpTurns.NO_ICON, 1, null);
        check("HUD: a turn, then icon 8 sends the empty list once", hc.calls.toString().equals("[hud f20143, hud f2]"));
        check("HUD: the blank frame is kept as the one refresh() resends", ht.lastHud != null && ht.lastHud.length == 1 && (ht.lastHud[0] & 0xff) == 0xf2);
        hc.calls.clear();
        ht.sendHud(67, 1, null);
        check("HUD: the next mapped turn is sent again", hc.calls.toString().equals("[hud f20143]"));
        System.exit(fail);
    }

    static void laneIs(String what, int[] r, int status, int... ids) {
        boolean ok = r[0] == status;
        for (int k = 0; k < 3; k++) ok &= r[1 + k] == (k < ids.length ? ids[k] : 0);
        check(what + " (status " + Integer.toHexString(r[0]) + ", ids " + r[1] + "," + r[2] + "," + r[3] + ")", ok);
    }

    /** a RouteGuidanceUpdate for component 1: guidance on, lane window `index`, shown or hidden, with the distance to the next maneuver */
    static Iap2NotiMsg laneUpdate(int index, boolean showing, String dist, int units) {
        return msg(0, U16, i(1), 1, ENUM, i(1), 11, STR, s(dist), 12, ENUM, i(units), 14, U16, i(2),
                16, U16, i(index), 17, U16, i(4), 18, 9, i(showing ? 1 : 0));
    }

    /** the lane distance calls since the last look, as a list */
    static String remains(Cluster cl) {
        List<String> r = new java.util.ArrayList<String>();
        for (String x : cl.calls) if (x.startsWith("remain ")) r.add(x);
        cl.calls.clear();
        return r.toString();
    }

    static boolean allZero(byte[] b, int from, int to) {
        for (int k = from; k <= to; k++) if (b[k] != 0) return false;
        return true;
    }
}
