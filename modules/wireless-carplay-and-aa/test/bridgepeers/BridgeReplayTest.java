package hmgapi.mods.wireless.dipo;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * The bridge's sequences over the pure decisions (item 11a). Model: it follows the call order of Bridge's methods
 * (scheduleSppConnect, onSppUp, onUsbGone, startCpClient, onCpSessionFinalized, onSppDown, the Phone Projection
 * requests, cancelConnectionPP, the bond receiver), with the queued jobs run explicitly and stale ones dropped by
 * token. Bridge itself is not run on the host (it needs Android); the single-phone scenarios are the sequences that
 * the car verified, and their expected actions are what the previous Bridge did.
 */
public final class BridgeReplayTest {
    static final String A = "80:96:98:05:D7:3D", B = "AA:BB:CC:DD:EE:FF";
    static final int CP = ProjectionSwitch.TYPE_CARPLAY, AA = ProjectionSwitch.TYPE_ANDROID_AUTO;
    static final int WIRELESS = ProjectionSwitch.TRANSFER_WIRELESS;

    static void check(boolean b, String message) {
        if (!b) throw new AssertionError(message);
    }

    static final class Job {
        final String kind, addr;
        final int token;

        Job(String kind, String addr, int token) {
            this.kind = kind;
            this.addr = addr;
            this.token = token;
        }
    }

    static final class Model {
        final BridgePeers peers = new BridgePeers();
        final ProjectionSwitch sw = new ProjectionSwitch();
        final Set<String> unbonded = new HashSet<String>();
        final List<String> out = new ArrayList<String>();
        final List<Job> jobs = new ArrayList<Job>();
        String sAddr;
        boolean sSession, sCpClient, sCpWireless, sUsb, androidAuto;

        boolean live() {
            return sSession || sCpClient || sCpWireless;
        }

        String liveOwner() {
            return live() ? sAddr : null;
        }

        String deny(String addr) {
            return peers.denyReason(addr, !unbonded.contains(addr), sw.isHeld(addr), liveOwner());
        }

        /** scheduleSppConnect, from a Bluetooth connection of an iPhone */
        void btConnected(String addr) {
            if (sw.connected(addr)) out.add("released " + addr);
            if (sSession || sCpWireless || sUsb || sw.isHeld(addr)) return;
            jobs.add(new Job("connect", addr, peers.token()));
        }

        /** onSppUp: the iPhone's SPP is up */
        void sppUp(String addr) {
            peers.sppUp(addr);
            if (sSession) return;
            sAddr = BridgePeers.arbitrate(sAddr, addr, live());
            if (!BridgePeers.sameAddr(sAddr, addr)) out.add("kept " + sAddr);
            if (sCpClient || sCpWireless || sUsb) return;
            if (sw.isHeld(addr)) {
                out.add("held " + addr);
                return;
            }
            if (androidAuto) {
                out.add("aa " + addr);
                return;
            }
            if (deny(addr) != null) {
                out.add("deny " + addr);
                return;
            }
            sSession = true;
            sw.sessionEnded();
            jobs.add(new Job("attach", addr, peers.token()));
        }

        /** the iAP2 Bluetooth component ends as the CarPlay channel takes over */
        void handoverDone() {
            sSession = false;
        }

        void sessionStarted(int transport) {
            sCpWireless = transport == 1 && !sUsb;
            sw.sessionEnded();
        }

        /** startCpClient: the CarPlay-channel handover, to the bridged phone */
        void startCpClient() {
            if (sCpClient) return;
            sCpClient = true;
            jobs.add(new Job("handover", sAddr, peers.token()));
        }

        /** onCpSessionFinalized */
        void finalized() {
            peers.bump();
            boolean client = sCpClient, wireless = sCpWireless;
            sCpWireless = false;
            sCpClient = false;
            if (client) out.add("detach");
            if (client || wireless) usbGone();
            sw.sessionEnded();
        }

        /** onUsbGone */
        void usbGone() {
            if (sAddr == null || sSession) return;
            jobs.add(new Job("reattach", sAddr, peers.token()));
        }

        /** onSppDown */
        void sppDown(String addr) {
            sw.linkDown(addr);
            peers.sppDown(addr);
            if (addr == null || !addr.equals(sAddr)) return;
            if (live()) peers.bump();
            if (sCpWireless) {
                sSession = false;
                startCpClient();
                return;
            }
            sAddr = null;
            if (sSession) {
                sSession = false;
                out.add("detach");
            }
        }

        /** onProjection, disconnectPP of CarPlay */
        void disconnectCarPlay(String addr) {
            int action = sw.request(false, CP, WIRELESS, addr, sAddr, live());
            if (action == ProjectionSwitch.STOP) {
                peers.bump();
                out.add("stop " + sAddr);
                out.add("detach");
            }
        }

        /** onProjection, connectPP of CarPlay */
        void connectCarPlay(String addr) {
            int action = sw.request(true, CP, WIRELESS, addr, sAddr, live());
            if (action != ProjectionSwitch.RESUME) return;
            String target = addr != null && addr.length() > 0 ? addr : sw.released();
            out.add("release " + target);
            if (peers.isSppUp(target)) sppUp(target);
            else jobs.add(new Job("connect", target, peers.token()));
        }

        /** onProjection, connectPP of Android Auto (GPM has started) */
        void connectAndroidAuto() {
            androidAuto = true;
            int action = sw.request(true, AA, WIRELESS, null, sAddr, live());
            if (action == ProjectionSwitch.STOP) {
                peers.bump();
                out.add("stop " + sAddr);
                out.add("detach");
            }
        }

        /** onCancelConnection */
        void cancel(String addr) {
            String target = addr != null && addr.length() > 0 ? addr : sAddr;
            if (target == null) return;
            if (!BridgePeers.sameAddr(target, sAddr) && !peers.isSppUp(target)) {
                out.add("cancel ignored " + target);
                return;
            }
            boolean stop = live() && BridgePeers.sameAddr(target, sAddr);
            sw.hold(target, stop);
            peers.bump();
            if (stop) out.add("detach");
            out.add("held " + target);
        }

        /** onBondChanged, bond removed */
        void bondLost(String addr) {
            peers.markDeleted(addr);
            if (BridgePeers.sameAddr(addr, sAddr) && live()) {
                sw.hold(addr, true);
                peers.bump();
                out.add("detach");
                out.add("bond stop " + addr);
            }
        }

        void bondRestored(String addr) {
            peers.clearDeleted(addr);
        }

        /** runs the queued work in order; stale work is dropped (a rolled-back sSession or sCpClient on the bridge's own) */
        void run() {
            for (int i = 0; i < jobs.size(); i++) runJob(jobs.get(i));
            jobs.clear();
        }

        void runJob(Job j) {
            boolean current = peers.current(j.token);
            if (j.kind.equals("connect")) {
                if (!current) out.add("dropped connect " + j.addr);
                else if (deny(j.addr) != null) out.add("deny " + j.addr);
                else out.add("connect " + j.addr);
            } else if (j.kind.equals("attach")) {
                if (!current) {
                    sSession = false;
                    out.add("dropped attach " + j.addr);
                } else out.add("attach " + j.addr);
            } else if (j.kind.equals("handover")) {
                if (!current) {
                    sCpClient = false;
                    out.add("dropped handover");
                } else out.add("handover " + j.addr);
            } else if (j.kind.equals("reattach")) {
                if (!current) {
                    out.add("dropped reattach");
                    return;
                }
                if (sUsb || sSession || live()) return;
                String next = BridgePeers.choose(j.addr, peers.sppUpList(), new BridgePeers.Eligible() {
                    @Override
                    public boolean ok(String addr) {
                        return peers.isSppUp(addr) && deny(addr) == null;
                    }
                });
                if (next == null) return;
                if (!BridgePeers.sameAddr(next, j.addr)) out.add("previous not eligible, " + next);
                sppUp(next);
            }
        }

        String out() {
            return out.toString();
        }
    }

    /** the expected line with the words A and B mapped to the two phones */
    static String line(String text) {
        StringBuilder sb = new StringBuilder();
        for (String word : text.split(" ")) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(word.equals("A") ? A : word.equals("B") ? B : word);
        }
        return sb.toString();
    }

    static int count(Model m, String text) {
        int n = 0;
        for (String o : m.out) if (o.equals(line(text))) n++;
        return n;
    }

    static boolean has(Model m, String text) {
        return m.out.contains(line(text));
    }

    /** expected actions: the words A and B stand for the two phones */
    static void check(Model m, String... want) {
        List<String> w = new ArrayList<String>();
        for (String line : want) {
            StringBuilder sb = new StringBuilder();
            for (String word : line.split(" ")) {
                if (sb.length() > 0) sb.append(' ');
                sb.append(word.equals("A") ? A : word.equals("B") ? B : word);
            }
            w.add(sb.toString());
        }
        check(m.out.equals(w), "out " + m.out + " want " + w);
    }

    /** the single-phone sequence the car verified: connect, SPP up, handover, end, re-attach of the same phone */
    static Model singlePhoneUpToHandover() {
        Model m = new Model();
        m.btConnected(A);
        m.run();
        m.sppUp(A);
        m.run();
        m.sessionStarted(1);
        m.handoverDone();
        m.startCpClient();
        m.run();
        return m;
    }

    static void singlePhoneReplay() {
        Model m = singlePhoneUpToHandover();
        check(m, "connect A", "attach A", "handover A");
        check(A.equals(m.sAddr) && m.sCpWireless && !m.sSession, "bridged over the CarPlay channel");
        m.finalized();
        m.run();
        check(m, "connect A", "attach A", "handover A", "detach", "attach A");
        check(m.sAddr.equals(A) && m.sSession && m.peers.isSppUp(A), "the same phone is re-attached");
    }

    static void twoPhonesKeepsA() {
        Model m = singlePhoneUpToHandover();
        m.btConnected(B);
        m.run();
        check(!has(m, "connect " + B), "no connect for B while A's CarPlay session runs");
        m.sppUp(B);
        m.run();
        check(m, "connect A", "attach A", "handover A", "kept A");
        check(A.equals(m.sAddr) && m.peers.isSppUp(B), "A keeps the address, B is only remembered as up");
    }

    static void aEndsAndIsEligible() {
        Model m = singlePhoneUpToHandover();
        m.sppUp(B);
        m.run();
        m.finalized();
        m.run();
        check(has(m, "attach A") && !has(m, "attach B"), "A is re-attached, B is not");
        check(A.equals(m.sAddr) && m.peers.isSppUp(B), "B is kept as up");
    }

    static void aEndsSppDownBChosen() {
        Model m = singlePhoneUpToHandover();
        m.sppUp(B);
        m.run();
        m.sppDown(A);
        m.run();
        m.finalized();
        m.run();
        check(has(m, "previous not eligible, " + B) && has(m, "attach B"), "B when A's SPP went down: " + m.out);
        check(B.equals(m.sAddr) && m.sSession, "B is the bridged phone now");
    }

    static void aHeldByAndroidAutoNoneStarts() {
        Model m = singlePhoneUpToHandover();
        m.sppUp(B);
        m.run();
        m.connectAndroidAuto();
        m.run();
        check(m.sw.isHeld(A), "A held by the Android Auto choice");
        m.handoverDone();
        m.finalized();
        m.run();
        check(has(m, "aa " + B) && !has(m, "attach B") && !m.sSession, "B does not start while Android Auto runs: " + m.out);
    }

    static void bondRemovedForBridgedA() {
        Model m = singlePhoneUpToHandover();
        m.sppUp(B);
        m.run();
        m.bondLost(A);
        m.run();
        check(has(m, "bond stop " + A) && m.sw.isHeld(A), "the bridged phone's session stops when its bond goes");
        m.finalized();
        m.run();
        check(has(m, "attach B") && count(m, "attach A") == 1, "then B, and A is not attached again: " + m.out);
        m.bondRestored(A);
        check(!m.peers.isDeleted(A) && m.sw.isHeld(A), "re-paired: the mark is cleared, the hold waits for the phone");
    }

    static void unbondedBridgedAGivesWayToB() {
        Model m = singlePhoneUpToHandover();
        m.sppUp(B);
        m.run();
        m.unbonded.add(A);
        m.finalized();
        m.run();
        check(has(m, "previous not eligible, " + B) && has(m, "attach B"), "unbonded A: B starts: " + m.out);
    }

    static void disconnectOfAnotherPhoneIgnored() {
        Model m = singlePhoneUpToHandover();
        m.disconnectCarPlay(B);
        check(m, "connect A", "attach A", "handover A");
        check(A.equals(m.sAddr) && !m.sw.isHeld(A) && !m.sw.isHeld(B) && !m.sw.stopping(), "A untouched");
    }

    static void disconnectOfBridgedAStopsAndHolds() {
        Model m = singlePhoneUpToHandover();
        m.disconnectCarPlay(A);
        check(m, "connect A", "attach A", "handover A", "stop " + A, "detach");
        check(m.sw.isHeld(A) && m.sw.stopping(), "A stopped and held");
        m.finalized();
        m.run();
        check(count(m, "attach A") == 1 && !m.sSession, "a held phone is not re-attached");
    }

    static void twoHoldsAndReleaseByName() {
        Model m = singlePhoneUpToHandover();
        m.sppUp(B);
        m.run();
        m.disconnectCarPlay(A);
        m.cancel(B);
        check(m.sw.isHeld(A) && m.sw.isHeld(B) && m.sw.heldAll().size() == 2, "two holds at once");
        m.finalized();
        m.run();
        m.connectCarPlay(B);
        m.run();
        check(has(m, "release " + B) && has(m, "attach " + B), "B released and attached: " + m.out);
        check(m.sw.isHeld(A) && !m.sw.isHeld(B), "A keeps its hold");
        check(B.equals(m.sAddr), "B serves now");
    }

    static void staleAttachDroppedAndRolledBack() {
        Model m = new Model();
        m.btConnected(A);
        m.run();
        m.sppUp(A);
        check(m.sSession && m.jobs.size() == 1, "attach queued");
        m.cancel(A);
        m.run();
        check(has(m, "dropped attach " + A), "stale attach dropped: " + m.out);
        check(!m.sSession && m.sw.isHeld(A), "sSession rolled back, A held");
    }

    static void staleHandoverDroppedAndRolledBack() {
        Model m = new Model();
        m.btConnected(A);
        m.run();
        m.sppUp(A);
        m.run();
        m.handoverDone();
        m.sessionStarted(1);
        m.startCpClient();
        check(m.sCpClient && m.jobs.size() == 1, "handover queued");
        m.cancel(A);
        m.run();
        check(has(m, "dropped handover") && !m.sCpClient, "stale handover dropped and sCpClient cleared: " + m.out);
    }

    static void cancelOfConnectingPhone() {
        Model m = new Model();
        m.btConnected(A);
        m.run();
        m.sppUp(A);
        m.cancel(A);
        m.run();
        check(m.sw.isHeld(A) && !m.sSession, "the connecting phone is held and its attach never runs");
        // a phone that is up but not bridged and not connecting: nothing
        Model n = singlePhoneUpToHandover();
        n.cancel(B);
        check(has(n, "cancel ignored " + B) && !n.sw.isHeld(B), "a phone that is not the bridged or connecting one is left alone");
    }

    static void cancelOfBridgedWithSession() {
        Model m = singlePhoneUpToHandover();
        m.cancel(A);
        check(has(m, "detach") && m.sw.isHeld(A) && m.sw.stopping(), "the bridged phone's session stops");
    }

    static void connectHoldReleasedForSingleHeld() {
        // one held phone and a connect that names another phone: the single hold is released and the named phone resumes
        Model m = singlePhoneUpToHandover();
        m.disconnectCarPlay(A);
        m.finalized();
        m.run();
        m.connectCarPlay(B);
        check(has(m, "release " + B) && !m.sw.isHeld(A), "single hold released for the named phone");
    }

    public static void main(String[] args) {
        singlePhoneReplay();
        twoPhonesKeepsA();
        aEndsAndIsEligible();
        aEndsSppDownBChosen();
        aHeldByAndroidAutoNoneStarts();
        bondRemovedForBridgedA();
        unbondedBridgedAGivesWayToB();
        disconnectOfAnotherPhoneIgnored();
        disconnectOfBridgedAStopsAndHolds();
        twoHoldsAndReleaseByName();
        staleAttachDroppedAndRolledBack();
        staleHandoverDroppedAndRolledBack();
        cancelOfConnectingPhone();
        cancelOfBridgedWithSession();
        connectHoldReleasedForSingleHeld();
        System.out.println("ok bridge replay: single phone as before, two phones, holds, stale work");
    }
}
