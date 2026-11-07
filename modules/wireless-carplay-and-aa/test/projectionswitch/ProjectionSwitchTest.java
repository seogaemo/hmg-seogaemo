package hmgapi.mods.wireless.dipo;

/** Phone Projection's switch: which requests stop the bridged CarPlay, hold the iPhone off and release it. */
public final class ProjectionSwitchTest {
    static final String IPHONE = "80:96:98:05:D7:3D", OTHER = "AA:BB:CC:DD:EE:FF";
    static final int CP = ProjectionSwitch.TYPE_CARPLAY, AA = ProjectionSwitch.TYPE_ANDROID_AUTO;
    static final int WIRELESS = ProjectionSwitch.TRANSFER_WIRELESS, WIRED = 0;

    static void check(boolean b, String message) { if (!b) throw new AssertionError(message); }

    static void twoPhones() {
        ProjectionSwitch s = new ProjectionSwitch();
        // A disconnect for another phone while A is bridged: A untouched, nothing held.
        check(s.request(false, CP, WIRELESS, OTHER, IPHONE, true) == ProjectionSwitch.IGNORE, "disconnect of another phone");
        check(!s.isHeld(IPHONE) && !s.isHeld(OTHER) && !s.stopping(), "another phone's disconnect holds nothing");
        // A disconnect that names the bridged phone stops and holds it.
        check(s.request(false, CP, WIRELESS, IPHONE, IPHONE, true) == ProjectionSwitch.STOP, "disconnect of the bridged phone");
        check(s.isHeld(IPHONE) && s.held().equals(IPHONE), "bridged phone held");
        // Two holds at once: a cancelled connecting phone is held without a session.
        s.hold(OTHER, false);
        check(s.isHeld(IPHONE) && s.isHeld(OTHER) && s.heldAll().size() == 2, "two holds");
        check(s.held() == null, "held() is the single phone only");
        ProjectionSwitch cancel = new ProjectionSwitch();
        cancel.hold(OTHER, false);
        check(!cancel.stopping() && cancel.isHeld(OTHER), "a cancel without a session holds and does not stop");
        // Connect for B releases B and keeps A held.
        check(s.request(true, CP, WIRELESS, OTHER, IPHONE, false) == ProjectionSwitch.RESUME, "connect B");
        check(s.released().equals(OTHER) && !s.isHeld(OTHER) && s.isHeld(IPHONE), "B released, A kept");
        // Connect for an unknown phone with two held releases nothing.
        s.hold(OTHER, false);
        check(s.request(true, CP, WIRELESS, "11:22:33:44:55:66", IPHONE, false) == ProjectionSwitch.IGNORE, "unknown with two held");
        check(s.isHeld(IPHONE) && s.isHeld(OTHER), "both kept");
        // An empty name with two held: nothing to choose.
        check(s.request(true, CP, WIRELESS, "", IPHONE, false) == ProjectionSwitch.IGNORE, "no name, two held");
        // Android Auto ignores the name and stops the bridged phone.
        check(s.request(true, AA, WIRELESS, OTHER, IPHONE, true) == ProjectionSwitch.STOP, "Android Auto stops the bridged phone");
        check(s.isHeld(IPHONE), "and holds it");

        // One held phone, connect naming another phone: as before, the hold is released and that phone resumes.
        ProjectionSwitch one = new ProjectionSwitch();
        one.request(true, AA, WIRELESS, null, IPHONE, true);
        check(one.request(true, CP, WIRELESS, OTHER, null, false) == ProjectionSwitch.RESUME, "single held released for a named phone");
        check(one.released().equals(IPHONE) && !one.isHeld(IPHONE), "released phone is the held one");

        // A link-down of one held phone is per phone.
        ProjectionSwitch links = new ProjectionSwitch();
        links.request(true, AA, WIRELESS, null, IPHONE, true);
        links.hold(OTHER, false);
        links.linkDown(OTHER);
        check(!links.connected(IPHONE), "A's connect is not B's link");
        check(links.connected(OTHER) && links.isHeld(IPHONE), "B released on its reconnect, A still held");
    }

    public static void main(String[] args) {
        ProjectionSwitch s = new ProjectionSwitch();
        // Nothing bridged, or wired requests: nothing to do, nothing held.
        check(s.request(true, AA, WIRELESS, null, null, false) == ProjectionSwitch.IGNORE, "no iPhone");
        check(s.request(true, AA, WIRELESS, null, IPHONE, false) == ProjectionSwitch.IGNORE, "no session");
        check(s.request(true, AA, WIRED, null, IPHONE, true) == ProjectionSwitch.IGNORE, "wired Android Auto");
        check(s.request(false, CP, WIRED, null, IPHONE, true) == ProjectionSwitch.IGNORE, "wired CarPlay disconnect");
        check(s.request(false, AA, WIRELESS, null, IPHONE, true) == ProjectionSwitch.IGNORE, "Android Auto disconnect");
        check(s.request(true, CP, WIRELESS, null, IPHONE, true) == ProjectionSwitch.IGNORE, "CarPlay connect without a hold");
        check(s.held() == null && !s.stopping(), "nothing held");

        // Android Auto chosen while the bridged CarPlay runs: stop and hold that iPhone.
        check(s.request(true, AA, WIRELESS, null, IPHONE, true) == ProjectionSwitch.STOP, "Android Auto chosen");
        check(s.isHeld(IPHONE) && s.isHeld(IPHONE.toLowerCase()) && !s.isHeld(OTHER) && !s.isHeld(null), "held iPhone");
        check(s.stopping(), "DiPO must see the session end");
        s.sessionEnded();
        check(!s.stopping() && s.isHeld(IPHONE), "the hold outlives the session");

        // A Bluetooth connection while the iPhone never went away keeps the hold.
        check(!s.connected(IPHONE), "still around");
        s.linkDown(OTHER);
        check(!s.connected(IPHONE), "another phone's link");
        // The next drive: its link went down, then it connects again.
        s.linkDown(IPHONE);
        check(s.connected(IPHONE) && s.held() == null, "released on reconnect");
        check(!s.connected(IPHONE), "released once");

        // CarPlay disconnected in Phone Projection, then chosen again.
        check(s.request(false, CP, WIRELESS, null, IPHONE, true) == ProjectionSwitch.STOP, "CarPlay disconnected");
        check(s.request(true, CP, WIRELESS, null, IPHONE, false) == ProjectionSwitch.RESUME && s.held() == null, "CarPlay chosen again");
        check(s.request(true, CP, WIRELESS, null, IPHONE, false) == ProjectionSwitch.IGNORE, "resumed once");

        // A new hold forgets an old link-down.
        check(s.request(true, AA, WIRELESS, null, IPHONE, true) == ProjectionSwitch.STOP, "held again");
        s.linkDown(IPHONE);
        check(s.request(true, AA, WIRELESS, null, IPHONE, true) == ProjectionSwitch.STOP, "chosen again while held");
        check(!s.connected(IPHONE) && s.isHeld(IPHONE), "link-down before the new hold doesn't count");
        twoPhones();
        System.out.println("ok projection switch: stop, hold and release, per phone");
    }
}
