package hmgapi.mods.wireless.dipo;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** BridgePeers: arbitration of the served address, eligibility, the next phone after a session, the queue token. */
public final class BridgePeersTest {
    static final String A = "80:96:98:05:D7:3D", B = "AA:BB:CC:DD:EE:FF", C = "11:22:33:44:55:66";

    static void check(boolean b, String message) {
        if (!b) throw new AssertionError(message);
    }

    /** eligible: the listed phones (any case) */
    static BridgePeers.Eligible eligibleOf(final String... addrs) {
        final List<String> ok = Arrays.asList(addrs);
        return new BridgePeers.Eligible() {
            @Override
            public boolean ok(String addr) {
                for (String s : ok) if (s.equalsIgnoreCase(addr)) return true;
                return false;
            }
        };
    }

    static void arbitration() {
        // the first phone takes the address when nothing is live
        check(A.equals(BridgePeers.arbitrate(null, A, false)), "first phone takes the address");
        check(B.equals(BridgePeers.arbitrate(A, B, false)), "no live session: the newer phone takes it, as before");
        // the same phone, or no candidate: unchanged
        check(A.equals(BridgePeers.arbitrate(A, A, true)), "same phone while live");
        check(A.equals(BridgePeers.arbitrate(A, null, true)), "no candidate keeps the address");
        // a live session of another phone keeps the address (item 11a)
        check(A.equals(BridgePeers.arbitrate(A, B, true)), "live session of A keeps the address against B");
        check(B.equals(BridgePeers.arbitrate(null, B, true)), "live with no address: the candidate takes it");
    }

    static void eligibility() {
        check(BridgePeers.mask(A).equals("**:**:**:**:D7:3D"), "mask keeps the last two octets");
        check(BridgePeers.mask(null).equals("**"), "mask of nothing");
        BridgePeers p = new BridgePeers();
        check(p.denyReason(A, true, false, null) == null, "a bonded, free phone may start");
        check("held by Phone Projection".equals(p.denyReason(A, true, true, null)), "held refuses");
        check(p.denyReason(null, true, false, null) != null, "no address refuses");
        check("not bonded".equals(p.denyReason(A, false, false, null)), "unbonded refuses");
        check("another phone owns the live session".equals(p.denyReason(B, true, false, A)), "another phone's live session refuses");
        check(p.denyReason(A, true, false, A) == null, "the phone that owns it may continue");
        p.markDeleted(A);
        check("bond removed".equals(p.denyReason(A.toLowerCase(), true, false, null)), "deleted refuses (any case)");
        p.clearDeleted(A);
        check(p.denyReason(A, true, false, null) == null, "re-paired: allowed again");
    }


    static void nextPhone() {
        // A eligible: A again, B kept in the set
        BridgePeers p = new BridgePeers();
        p.sppUp(A);
        p.sppUp(B);
        check(A.equals(BridgePeers.choose(A, p.sppUpList(), eligibleOf(A, B))), "previous eligible is chosen");
        // A not eligible: the first other eligible phone that is up
        check(B.equals(BridgePeers.choose(A, p.sppUpList(), eligibleOf(B))), "B when A is not eligible");
        check(C.equals(BridgePeers.choose(A, Arrays.asList(A, B, C), eligibleOf(C))), "first eligible of the others");
        // nothing eligible
        check(BridgePeers.choose(A, p.sppUpList(), eligibleOf()) == null, "nothing eligible: nothing");
        // no previous phone: the first eligible of the set, in order
        check(A.equals(BridgePeers.choose(null, p.sppUpList(), eligibleOf(A, B))), "no previous: first in order");
        check(BridgePeers.choose(null, Collections.<String>emptyList(), eligibleOf(A)) == null, "empty set");
    }

    static void sppSet() {
        BridgePeers p = new BridgePeers();
        p.sppUp(A);
        p.sppUp(B);
        p.sppUp(B.toLowerCase());
        check(p.sppUpList().size() == 2 && p.sppUpList().get(0).equals(A) && p.sppUpList().get(1).equals(B), "order, no duplicates");
        check(p.isSppUp(A.toLowerCase()), "case-insensitive");
        // a phone that is not the bridged one leaves the set too
        p.sppDown(B);
        check(!p.isSppUp(B) && p.isSppUp(A), "any address leaves the set");
        p.sppDown(C);
        check(p.sppUpList().size() == 1, "unknown address: nothing changes");
    }

    static void tokens() {
        BridgePeers p = new BridgePeers();
        int t0 = p.token();
        check(p.current(t0), "the token is current");
        int t1 = p.bump();
        check(t1 == t0 + 1 && !p.current(t0) && p.current(t1), "a bump stales the older token");
    }

    static void deletedMarks() {
        BridgePeers p = new BridgePeers();
        check(!p.isDeleted(A), "not deleted at first");
        p.markDeleted(A.toLowerCase());
        check(p.isDeleted(A), "marked (case-insensitive)");
        p.clearDeleted(A);
        check(!p.isDeleted(A), "cleared");
    }

    public static void main(String[] args) {
        arbitration();
        eligibility();
        nextPhone();
        sppSet();
        tokens();
        deletedMarks();
        System.out.println("ok bridgepeers: arbitration, eligibility, next phone, sets, token");
    }
}
