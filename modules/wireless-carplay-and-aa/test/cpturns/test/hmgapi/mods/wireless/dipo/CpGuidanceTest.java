package hmgapi.mods.wireless.dipo;

import hmgapi.hook.Cluster;
import static hmgapi.mods.wireless.dipo.CpTurnsTest.*;

public final class CpGuidanceTest {
    static void require(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
    static CpTurns.Maneuver m(int type, Integer angle) {
        CpTurns.Maneuver m = new CpTurns.Maneuver(0, 1, null);
        m.type = type;
        m.hasExit = angle != null;
        m.exit = angle == null ? 0 : angle;
        return m;
    }
    static void mapping(int type, Integer angle, int display, int direction) {
        int[] r = CpGuidance.stock(m(type, angle));
        require(r != null && r[0] == display && r[1] == direction, "mapping " + type + "/" + angle);
    }
    public static void main(String[] args) {
        mapping(1, -90, 13, 270); mapping(2, 90, 13, 90);
        mapping(47, null, 13, 225); mapping(50, null, 13, 45); mapping(49, null, 13, 315);
        mapping(2, 62, 13, 45); mapping(1, -40, 13, 315); mapping(48, null, 13, 135); mapping(4, null, 31, 270);
        CpTurns.Maneuver leftTraffic = m(4, null); leftTraffic.side = 1;
        require(CpGuidance.stock(leftTraffic)[1] == 90, "LHT U loop");
        mapping(22, null, 18, 270); mapping(23, null, 17, 90);
        CpLaneDecoder.Info keepLeft = new CpLaneDecoder.Info(1, 0, new CpLaneDecoder.Lane[] {
            new CpLaneDecoder.Lane(0, 2, new int[] {0}, 0), new CpLaneDecoder.Lane(1, 0, new int[] {0, 45}, 1000)}, 0);
        int[] change = CpGuidance.stock(m(23, null), keepLeft);
        require(change[0] == 19 && change[1] == 90, "right exit after a lane change");
        change = CpGuidance.stock(m(22, null), new CpLaneDecoder.Info(1, 0, new CpLaneDecoder.Lane[] {
            new CpLaneDecoder.Lane(0, 0, new int[] {-45, 0}, 1000), new CpLaneDecoder.Lane(1, 2, new int[] {0}, 0)}, 0));
        require(change[0] == 20 && change[1] == 270, "left exit after a lane change");
        CpLaneDecoder.Info onExitSide = new CpLaneDecoder.Info(1, 0, new CpLaneDecoder.Lane[] {
            new CpLaneDecoder.Lane(0, 0, new int[] {0}, 1000), new CpLaneDecoder.Lane(1, 2, new int[] {45}, 45)}, 0);
        require(CpGuidance.stock(m(23, null), onExitSide)[0] == 17, "already in the exit lane");
        require(CpGuidance.stock(m(23, null), new CpLaneDecoder.Info(1, 0, new CpLaneDecoder.Lane[] {
            new CpLaneDecoder.Lane(0, 0, new int[] {0}, 1000), new CpLaneDecoder.Lane(1, 0, new int[] {45}, 1000)}, 0))[0] == 17,
            "no recommendation, plain exit");
        mapping(8, -35, 18, 270); mapping(9, 40, 17, 90);
        CpTurns.Maneuver combined = m(23, 45); combined.angles = new int[] {90};
        require(CpGuidance.stock(combined)[0] == 17 && CpGuidance.stock(combined)[1] == 90, "right exit with another road");
        combined.type = 22; combined.exit = -45; combined.angles = new int[] {-90};
        require(CpGuidance.stock(combined)[0] == 18 && CpGuidance.stock(combined)[1] == 270, "left exit with another road");
        // Keeps and highway changes keep the projection icon whatever the lanes say.
        CpLaneDecoder.Info five = new CpLaneDecoder.Info(1, 0, new CpLaneDecoder.Lane[] {
            new CpLaneDecoder.Lane(0, 0, new int[] {0}, 1000), new CpLaneDecoder.Lane(1, 0, new int[] {0}, 1000),
            new CpLaneDecoder.Lane(2, 0, new int[] {0}, 1000), new CpLaneDecoder.Lane(3, 2, new int[] {20}, 20),
            new CpLaneDecoder.Lane(4, 0, new int[] {90}, 1000)}, 0);
        require(CpGuidance.laneSide(five) == 0, "middle lanes");
        for (int type : new int[] {13, 14, 51, 52, 53}) for (Integer angle : new Integer[] {null, -30, 30}) {
            require(CpGuidance.stock(m(type, angle)) == null, "keep has no stock shape " + type);
            require(CpGuidance.stock(m(type, angle), five) == null, "keep with lanes has no stock shape " + type);
        }
        mapping(12, null, 3, 0); mapping(10, null, 3, 0); mapping(24, null, 2, 270); mapping(25, null, 2, 90);
        mapping(3, 0, 13, 0); mapping(7, 180, 32, 180); mapping(28, -90, 32, 270);
        require(CpGuidance.stock(m(28, null)) == null, "roundabout ordinal is not an angle");
        require(CpGuidance.stock(m(2, -90)) == null, "contradictory direction fallback");
        // a U-turn whose explicit exit angle is not a U-turn keeps the projection icon; no angle (NAVER) or a real one draws it
        mapping(4, 180, 31, 270); mapping(4, -160, 31, 270); mapping(4, 158, 31, 270); mapping(4, 0, 31, 270); mapping(26, -170, 31, 270);
        require(CpGuidance.stock(m(4, 157)) == null && CpGuidance.stock(m(4, -90)) == null && CpGuidance.stock(m(18, 30)) == null, "U-turn with a turn angle");
        // a plain turn inside a roundabout (junction 1) is the exit at its explicit angle; 0 is the entry marker, no angle is no position
        CpTurns.Maneuver inRound = m(2, 90); inRound.junction = 1;
        require(CpGuidance.stock(inRound)[0] == 32 && CpGuidance.stock(inRound)[1] == 90, "right turn in a roundabout, right-hand traffic");
        inRound = m(1, -120); inRound.junction = 1; inRound.side = 1;
        require(CpGuidance.stock(inRound)[0] == 33 && CpGuidance.stock(inRound)[1] == 225, "left turn in a roundabout, left-hand traffic, rounded to 45");
        inRound = m(2, 0); inRound.junction = 1;
        require(CpGuidance.stock(inRound) == null, "roundabout entry marker 0 is no exit position");
        inRound = m(2, null); inRound.junction = 1;
        require(CpGuidance.stock(inRound) == null, "turn in a roundabout without an angle keeps the projection icon");
        inRound = m(3, 90); inRound.junction = 1;
        require(CpGuidance.stock(inRound) == null, "straight in a roundabout keeps the projection icon");
        inRound = m(0, 180); inRound.junction = 1;
        require(CpGuidance.stock(inRound) == null, "NAVER roundabout (type 0, junction 1, exit 180) keeps the projection icon 102");
        require(CpGuidance.stock(m(8, null)) == null, "unknown ramp side fallback");
        CpTurns.Maneuver straight = m(3, 0); straight.angles = new int[] {45};
        require(CpGuidance.stock(straight)[0] == 13 && CpGuidance.stock(straight)[1] == 0, "urban straight past side road");
        straight.afterRoad = "경부고속도로";
        require(CpGuidance.stock(straight)[0] == 23 && CpGuidance.stock(straight)[1] == 270, "highway straight past right exit");
        straight.angles = new int[] {-45};
        require(CpGuidance.stock(straight)[0] == 24 && CpGuidance.stock(straight)[1] == 90, "highway straight past left exit");
        for (int type = 0; type <= 53; type++) for (int angle = -180; angle <= 180; angle += 15) {
            int[] r = CpGuidance.stock(m(type, angle));
            require(r == null || r[0] != 26 && r[0] != 19 && r[0] != 20 && !(r[0] == 13 && r[1] == 180)
                    && r[0] != 25, "never unverified shapes " + type + "/" + angle);
        }
        for (int n = 0; n <= 300; n++) {
            int level = CpGuidance.bar(n, 300);
            require(level >= 0 && level <= 100 && level <= CpGuidance.bar(n + 1, 300), "monotone bar");
        }
        require(CpGuidance.bar(0, 300) == 0 && CpGuidance.bar(150, 300) == 50 && CpGuidance.bar(600, 600) == 100, "bar endpoints");
        CpTurns.Update u = new CpTurns.Update(1, null); u.state = 1; u.distNext = 0;
        require(!CpGuidance.approach(u, m(2, null)), "missing distance is not zero");
        u.hasDistance = true; u.distNext = 300;
        require(CpGuidance.approach(u, m(2, null)), "300m inclusive");
        u.distNext = 301;
        require(!CpGuidance.approach(u, m(2, null)), "301m outside turn");
        u.distNext = 600;
        require(CpGuidance.approach(u, m(23, null)), "600m highway inclusive");
        u.distNext = 601;
        require(!CpGuidance.approach(u, m(23, null)), "601m outside highway");

        Cluster c = new Cluster();
        CpTurns t = new CpTurns(new android.content.Context(), c, null);
        t.maneuver(maneuver(0, 2, 0, 0, 90, "Road", 1000));
        t.maneuver(maneuver(1, 1, 0, 0, -90, "Other", 200));
        t.routeGuidance(msg(0,U16,i(1),1,ENUM,i(1),10,U32,i(300),11,STR,s("0.3"),12,ENUM,i(0),13,U16,i(0)));
        require(c.calls.contains("tbt 13 0 90.0 0.3 0 0 1 0 0"), "main stock turn");
        require(c.calls.toString().contains("hud f20143"), "HUD retains projection icon");
        require(Dipo.approaches.get(Dipo.approaches.size()-1).equals("true 100"), "approach lease started");
        t.routeGuidance(msg(0,U16,i(1),10,U32,i(0)));
        require(Dipo.approaches.get(Dipo.approaches.size()-1).equals("true 0"), "zero at maneuver");
        t.routeGuidance(msg(0,U16,i(1),13,U16,i(1)));
        require(!t.updates.get(1).hasDistance, "replacement invalidates old distance");
        require(Dipo.approaches.get(Dipo.approaches.size()-1).equals("false 0"), "replacement clears lease");
        t.routeGuidance(msg(0,U16,i(1),10,U32,i(100)));
        require(Dipo.approaches.get(Dipo.approaches.size()-1).equals("true 33"), "replacement with fresh distance");
        c.calls.clear();
        t.routeGuidance(msg(0,U16,i(1),10,U32,i(90),13,U16,i(7)));
        require(Dipo.approaches.get(Dipo.approaches.size()-1).equals("false 0"), "unknown next maneuver clears lease");
        require(!c.calls.contains("tbt 8 0 0.0 0.0 -1 0 0 0 -1"), "no idle compass mid-route");
        require(c.calls.toString().contains("tbt 70 0 0.0"), "projection icon resent mid-route");
        c.calls.clear();
        t.routeGuidance(msg(0,U16,i(1),1,ENUM,i(5)));
        require(c.calls.contains("tbt 10 0 0.0 0.0 0 0 0 0 0"), "rerouting");
        require(!t.updates.get(1).hasDistance, "reroute invalidates old distance");
        c.calls.clear();
        t.routeGuidance(msg(0,U16,i(1),1,ENUM,i(3),13,U16,i()));
        require(c.calls.contains("tbt 9 0 0.0 0.0 0 0 0 0 0"), "loading without maneuver");
        t.routeGuidance(msg(0,U16,i(1),1,ENUM,i(1),13,U16,i()));
        for (int action = 0; action < 4; action++) {
            t.maneuver(maneuver(0,2,0,0,90,"Road",100));
            t.routeGuidance(msg(0,U16,i(1),1,ENUM,i(1),10,U32,i(100),13,U16,i(0)));
            c.calls.clear();
            if (action == 0) t.stop();
            else if (action == 1) t.disconnected();
            else if (action == 2) t.reset();
            else t.routeGuidance(msg(0,U16,i(1),1,ENUM,i(0)));
            require(Dipo.approaches.get(Dipo.approaches.size()-1).equals("false 0"), "clear path " + action);
            if (action != 2) {
                String idle = "tbt 8 0 0.0 0.0 -1 0 0 0 -1";
                require(java.util.Collections.frequency(c.calls, idle) == 1, "one final idle " + action);
                require(!c.calls.contains("tbt 8 0 0.0 0.0 0 0 0 0 0"), "no competing approach idle");
                c.calls.clear(); t.stop();
                require(!c.calls.contains(idle), "repeated stop keeps idle compass");
            }
        }
        CpTurns split = new CpTurns(new android.content.Context(), c, null);
        split.maneuver(maneuver(0, 12, 0, 0, 0, "", 100));
        split.routeGuidance(msg(0,U16,i(1),1,ENUM,i(1),10,U32,i(100),13,U16,i(0)));
        c.calls.clear();
        split.routeGuidance(msg(0,U16,i(1),1,ENUM,i(2)));
        require(c.calls.toString().contains("tbt 3 0 0.0"), "arrived flag");
        for (int state : new int[] {3, 5}) {
            t.routeGuidance(msg(0,U16,i(1),1,ENUM,i(state)));
            c.calls.clear(); t.disconnected();
            require(c.calls.contains("tbt 8 0 0.0 0.0 -1 0 0 0 -1"), "search state returns idle " + state);
        }
        System.out.println("CpGuidanceTest passed");
    }
}
