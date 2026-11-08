package hmgapi.mods.wireless.dipo;

import static hmgapi.mods.wireless.dipo.CpGuidanceTest.require;

public final class NowPlayingTest {
    static final class Fake implements NowPlaying.Server {
        int calls;
        int failFor;
        boolean throwing;
        public boolean start() throws Exception {
            calls++;
            if (throwing && calls <= failFor) throw new Exception("boom");
            return calls > failFor;
        }
    }

    public static void main(String[] args) {
        NowPlaying n = new NowPlaying();
        // not before the channel session exists, not for other notis, not when off
        n.reset();
        require(!n.due(true, false, 0), "no channel client");
        require(!n.due(true, true, 24), "other noti");
        require(!n.due(false, true, 0), "setting off");
        require(n.due(true, true, 0), "first identification");
        require(!n.due(true, true, 0), "once per session");

        // starts on the first try
        Fake f = new Fake();
        int s = n.session();
        String r = n.attempt(s, 1, true, f);
        require(r != null && r.startsWith("NowPlaying started") && f.calls == 1, "start " + r);

        // refused twice, accepted on the third try
        n.reset();
        require(n.due(true, true, 0), "due after reset");
        f = new Fake(); f.failFor = 2; s = n.session();
        require(n.attempt(s, 1, true, f) == null, "retry 1");
        require(n.attempt(s, 2, true, f) == null, "retry 2");
        r = n.attempt(s, 3, true, f);
        require(r.startsWith("NowPlaying started") && r.contains("try 3"), "third try " + r);

        // exceptions count as failures; after the last try the next identification may start again
        n.reset();
        require(n.due(true, true, 0), "due again");
        f = new Fake(); f.failFor = 99; f.throwing = true; s = n.session();
        require(n.attempt(s, 1, true, f) == null && n.attempt(s, 2, true, f) == null, "retries");
        r = n.attempt(s, 3, true, f);
        require(r.startsWith("NowPlaying not started") && r.contains("failed"), "gave up " + r);
        require(n.due(true, true, 0), "may start again after giving up");

        // a stale try (session ended or channel down) does nothing
        n.reset();
        require(n.due(true, true, 0), "due");
        f = new Fake(); s = n.session();
        n.reset();
        require(n.attempt(s, 1, true, f).isEmpty() && f.calls == 0, "stale session");
        require(n.due(true, true, 0), "new session due");
        s = n.session();
        require(n.attempt(s, 1, false, f).isEmpty() && f.calls == 0, "channel down");
        System.out.println("NowPlayingTest ok");
    }
}
