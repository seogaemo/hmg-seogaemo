#!/usr/bin/env python3
"""Transient mutation API: kernel modules, daemons, network rules and interface addresses."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from testlib import car_env, SHELL, run_tests

ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "nemesis/package/lib/common.sh"
RELEASE = "3.4.39-tcc"
MODULE = "usbwifi"
MANIFEST = """id=usbwifi
kmods=r8188eu,wrongmagic
kmod.r8188eu.tcc803x=drivers/tcc803x/r8188eu.ko
kmod.r8188eu=drivers/generic/r8188eu.ko
kmod_params.r8188eu=rtw_ips_mode=0 rtw_power_mgnt=0
kmod.wrongmagic=drivers/wrong.ko
daemons=fakesupp
daemon.fakesupp=@payload@/bin/fake-daemon -i rtwlan0 -c @state@/supp.conf
net_rules.1=iptables -t nat POSTROUTING -o rtwlan0 -j MASQUERADE
net_rules.2=ip rule from 192.168.50.0/24 lookup 60
owns_ifaces=rtwlan*
"""

# Fake kernel-facing tools keep their state in files, so every assertion is on state.
FAKE_TOOLS = {
    "insmod": r'''
import os, re, sys
kernel, proc = os.environ["FAKE_KERNEL"], os.environ["SG_PROC_ROOT"]
open(kernel + "/calls", "a").write("insmod " + " ".join(sys.argv[1:]) + "\n")
name = re.search(rb"\x00name=([a-z0-9_]+)\x00", open(sys.argv[1], "rb").read()).group(1).decode()
path = proc + "/modules"
lines = open(path).read().splitlines() if os.path.exists(path) else []
if any(line.split()[0] == name for line in lines):
    sys.exit(1)
lines.append(name + " 16384 0 - Live 0xbf000000")
open(path, "w").write("".join(line + "\n" for line in lines))
open(kernel + "/params." + name, "w").write(" ".join(sys.argv[2:]))
''',
    "rmmod": r'''
import os, sys
kernel, proc = os.environ["FAKE_KERNEL"], os.environ["SG_PROC_ROOT"]
open(kernel + "/calls", "a").write("rmmod " + " ".join(sys.argv[1:]) + "\n")
path = proc + "/modules"
lines = open(path).read().splitlines()
kept = [line for line in lines if line.split()[0] != sys.argv[1]]
if len(kept) == len(lines):
    sys.exit(1)
open(path, "w").write("".join(line + "\n" for line in kept))
''',
    "iptables": r'''
import os, sys
kernel = os.environ["FAKE_KERNEL"]
open(kernel + "/calls", "a").write("iptables " + " ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]
assert args[0] == "-t" and args[2] in ("-I", "-D"), args
rule = " ".join([args[1], args[3]] + args[4:])
path = kernel + "/iptables"
rules = open(path).read().splitlines() if os.path.exists(path) else []
if args[2] == "-I":
    rules.insert(0, rule)
elif rule in rules:
    rules.remove(rule)
else:
    sys.exit(1)
open(path, "w").write("".join(line + "\n" for line in rules))
''',
    "ip": r'''
import os, sys
kernel, net = os.environ["FAKE_KERNEL"], os.environ["SG_SYS_NET_ROOT"]
args = sys.argv[1:]
if args[:2] != ["addr", "show"]:
    open(kernel + "/calls", "a").write("ip " + " ".join(args) + "\n")
def lines(path):
    return open(path).read().splitlines() if os.path.exists(path) else []
def save(path, items):
    open(path, "w").write("".join(item + "\n" for item in items))
if args[0] == "rule":
    rules, spec = lines(kernel + "/rules"), " ".join(args[2:])
    if args[1] == "add":
        rules.append(spec)
    elif spec in rules:
        rules.remove(spec)
    else:
        sys.exit(2)
    save(kernel + "/rules", rules)
elif args[0] == "addr":
    iface = args[-1]
    if not os.path.isdir(net + "/" + iface):
        sys.exit(1)
    addrs = lines(kernel + "/addr." + iface)
    if args[1] == "show":
        print(f"5: {iface}: <BROADCAST,MULTICAST> mtu 1500")
        for addr in addrs:
            print(f"    inet {addr} brd 192.168.50.255 scope global {iface}")
        sys.exit(0)
    if args[1] == "add":
        if args[2] in addrs:
            sys.exit(2)
        addrs.append(args[2])
    elif args[2] in addrs:
        addrs.remove(args[2])
    else:
        sys.exit(2)
    save(kernel + "/addr." + iface, addrs)
elif args[:2] == ["link", "set"]:
    open(net + "/" + args[2] + "/flags", "w").write("0x1003\n" if args[3] == "up" else "0x1002\n")
''',
}
FAKE_DAEMON = r'''#!/bin/sh
proc="$SG_PROC_ROOT/$$"
mkdir -p "$proc"
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"".join(a.encode() + b"\0" for a in sys.argv[2:]))' "$proc/cmdline" "$0" "$@"
trap 'rm -rf "$proc"; exit 0' TERM
echo started
while :; do sleep 1 & wait $!; done
'''


def ko(name, release):
    return b"\x7fELF\x01\x01\x01" + b"\x00" * 9 + b"license=GPL\x00vermagic=" + release.encode() + \
        b" preempt mod_unload ARMv7 \x00name=" + name.encode() + b"\x00depends=cfg80211\x00\n\x00"


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


class Car:
    def __init__(self, base, manifest=MANIFEST, others=None):
        self.base = base
        self.state = base / "data/modules" / MODULE
        self.payload = base / "payload"
        self.proc = base / "proc"
        self.kernel = base / "kernel"
        self.net = base / "sys/class/net"
        self.live = base / "live"
        for path in (self.state.parent, self.proc / "sys/kernel", self.kernel, self.net / "rtwlan0",
                     self.net / "wlan0", self.live, base / "modules", base / "tools/system/bin"):
            path.mkdir(parents=True, exist_ok=True)
        (self.proc / "modules").write_text("")
        (self.proc / "sys/kernel/osrelease").write_text(RELEASE + "\n")
        (self.net / "rtwlan0/flags").write_text("0x1002\n")
        (self.net / "wlan0/flags").write_text("0x1003\n")
        (base / "boot_id").write_text("boot-a\n")
        (self.live / "ro.board.platform").write_text("tcc803x")
        (self.live / "ro.build.product").write_text("NEEV.KOR.0000.V039.001.260902")
        (base / f"modules/{MODULE}.properties").write_text(manifest)
        listed = [MODULE]
        for other, text in (others or {}).items():
            (base / f"modules/{other}.properties").write_text(text)
            listed.append(other)
        (base / "modules.list").write_text("".join(f"{item}\n" for item in listed))
        for name, body in FAKE_TOOLS.items():
            executable(base / "tools/system/bin" / name, f"#!{sys.executable}\n" + body)
        fake = base / "fake"
        executable(fake / "getprop", '#!/bin/sh\ncat "$FAKE_LIVE/$1" 2>/dev/null || true\n')
        for directory in ("tcc803x", "generic"):
            path = self.payload / "drivers" / directory / "r8188eu.ko"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(ko("r8188eu", RELEASE))
        (self.payload / "drivers/wrong.ko").write_bytes(ko("wrongmagic", "3.18.0"))
        executable(self.payload / "bin/fake-daemon", FAKE_DAEMON)
        self.env = car_env(dict(
            os.environ, PATH=f"{fake}:{os.environ['PATH']}", FAKE_LIVE=str(self.live), FAKE_KERNEL=str(self.kernel),
            SG_PROC_ROOT=str(self.proc), SG_SYS_NET_ROOT=str(self.net), SG_BOOT_ID_FILE=str(base / "boot_id"),
            HMG_SEOGAEMO_TOOL_ROOT=str(base / "tools"), HMG_SEOGAEMO_BASE=str(base),
            HMG_SEOGAEMO_STATE=str(self.state), HMG_SEOGAEMO_MODULE_DIR=str(self.payload),
            SG_DATA_ROOT=str(base / "data")))
        self.pids = []

    def sh(self, body, code=0):
        runner = self.base / "runner"
        runner.write_text(f'. "{COMMON}"\n{body}\n')
        result = subprocess.run([SHELL, str(runner)], env=self.env, capture_output=True, text=True, timeout=60)
        assert result.returncode == code, (body, code, result.returncode, result.stdout, result.stderr)
        return result

    def calls(self):
        path = self.kernel / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def ledger(self):
        path = self.base / "data/ledger/ledger.tsv"
        rows = path.read_text().splitlines()[1:] if path.exists() else []
        return [tuple(row.split("\t")[2:4]) + (row.split("\t")[6],) for row in rows]

    def ledger_text(self, op, side):
        rows = (self.base / "data/ledger/ledger.tsv").read_text().splitlines()[1:]
        ref = [row.split("\t") for row in rows if row.split("\t")[2] == op][-1][4 if side == "before" else 5]
        return (self.base / "data/ledger" / ref).read_text()

    def lines(self, name):
        path = self.kernel / name
        return path.read_text().splitlines() if path.exists() else []

    def daemon_pid(self):
        pid = int((self.state / "daemon.fakesupp").read_text().splitlines()[1])
        self.pids.append(pid)
        return pid

    def reboot(self):
        (self.base / "boot_id").write_text("boot-b\n")

    def cleanup(self):
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_gone(pid, limit=10.0):
    deadline = time.monotonic() + limit
    while alive(pid):
        assert time.monotonic() < deadline, f"process {pid} still alive"
        time.sleep(0.05)


def test_kmod_apply_revert(base):
    car = Car(base)
    car.sh("sg_kmod_load r8188eu")
    assert (car.proc / "modules").read_text().split()[0] == "r8188eu"
    assert (car.kernel / "params.r8188eu").read_text() == "rtw_ips_mode=0 rtw_power_mgnt=0"
    assert car.calls() == [f"insmod {car.payload}/drivers/tcc803x/r8188eu.ko rtw_ips_mode=0 rtw_power_mgnt=0"]
    car.sh("sg_kmod_load r8188eu\nsg_kmod_loaded r8188eu")
    assert len(car.calls()) == 1
    assert ("kmod_load", "r8188eu", "ok") in car.ledger()
    car.sh("sg_revert_all")
    assert (car.proc / "modules").read_text() == ""
    assert car.calls()[-1] == "rmmod r8188eu"
    assert ("kmod_unload", "r8188eu", "ok") in car.ledger()
    assert not (car.state / "kmod.r8188eu").exists() and not (car.state / "changes").exists()
    car.sh("sg_kmod_loaded r8188eu", code=1)
    # Without a payload for this platform the default kmod.<name>= path is used.
    (car.live / "ro.board.platform").write_text("tcc897x")
    car.sh("sg_kmod_load r8188eu")
    assert car.calls()[-1].startswith(f"insmod {car.payload}/drivers/generic/r8188eu.ko ")


def test_kmod_refusals(base):
    car = Car(base)
    car.sh("sg_kmod_load wrongmagic", code=4)
    car.sh("sg_kmod_load cfg80211", code=2)
    car.sh("sg_kmod_load 'r8188eu;reboot'", code=2)
    car.sh("sg_kmod_load", code=2)
    (car.proc / "modules").write_text("r8188eu 16384 0 - Live 0xbf000000\n")
    car.sh("sg_kmod_load r8188eu", code=3)
    assert not (car.state / "kmod.r8188eu").exists()
    (car.proc / "modules").write_text("")
    (base / f"modules/{MODULE}.properties").write_text(
        MANIFEST.replace("kmod_params.r8188eu=rtw_ips_mode=0 rtw_power_mgnt=0", "kmod_params.r8188eu=x=$(reboot)"))
    car.sh("sg_kmod_load r8188eu", code=2)
    (base / f"modules/{MODULE}.properties").write_text(
        MANIFEST.replace("kmod.r8188eu.tcc803x=drivers/tcc803x/r8188eu.ko", "kmod.r8188eu.tcc803x=../../etc/x.ko"))
    car.sh("sg_kmod_load r8188eu", code=2)
    assert car.calls() == [] and car.ledger() == []
    claimed = Car(base / "claimed", others={"other": "id=other\nkmods=r8188eu\n"})
    claimed.sh("sg_kmod_load r8188eu", code=3)
    assert claimed.calls() == []


def test_kmod_timeout(base):
    for op in ("insmod", "rmmod"):
        car = Car(base / op)
        if op == "rmmod":
            car.sh("sg_kmod_load r8188eu")
        executable(car.base / "tools/system/bin" / op,
                   f"#!{sys.executable}\nimport time\ntime.sleep(120)\n")
        # Exercise the real timeout loop quickly. Model an uninterruptible child
        # by leaving it alive after the signal helper; no final wait is allowed.
        command = "sg_kmod_load r8188eu" if op == "insmod" else "sg_revert_all"
        started = time.monotonic()
        try:
            car.sh('sleep() { /bin/sleep 0.001; }\nsg_kill_tree() { :; }\n' + command, code=1)
            assert time.monotonic() - started < 10
            assert (car.state / "kmod.r8188eu").exists()
            assert "kmod\tr8188eu" in (car.state / "changes").read_text()
            pending = car.state / "kmod.r8188eu.pending"
            pid = int(pending.read_text().splitlines()[1])
            assert alive(pid)
            assert "timed out" in (car.state / "module.log").read_text()
            car.sh("sg_kmod_load r8188eu", code=1)
            car.sh("sg_kmod_loaded r8188eu", code=1)
            car.sh("sg_revert_all", code=1)
        finally:
            if (car.state / "kmod.r8188eu.pending").exists():
                pid = int((car.state / "kmod.r8188eu.pending").read_text().splitlines()[1])
                os.kill(pid, signal.SIGKILL)
        car.reboot()
        (car.proc / "modules").write_text("")
        car.sh("sg_revert_all")
        assert not pending.exists()


def test_daemon_apply_revert(base):
    car = Car(base)
    try:
        car.sh("sg_daemon_start fakesupp")
        pid = car.daemon_pid()
        assert alive(pid)
        expected = [f"{car.payload}/bin/fake-daemon", "-i", "rtwlan0", "-c", f"{car.state}/supp.conf"]
        assert (car.proc / str(pid) / "cmdline").read_bytes() == b"".join(a.encode() + b"\0" for a in expected)
        assert "started" in (car.state / "daemon.fakesupp.log").read_text()
        car.sh("sg_daemon_start fakesupp\nsg_daemon_running fakesupp")
        assert car.daemon_pid() == pid
        assert [row for row in car.ledger() if row[0] == "daemon_start"] == [("daemon_start", "fakesupp", "ok")]
        car.sh("sg_revert_all")
        wait_gone(pid)
        assert ("daemon_stop", "fakesupp", "ok") in car.ledger()
        assert not (car.state / "daemon.fakesupp").exists()
        car.sh("sg_daemon_running fakesupp", code=1)
    finally:
        car.cleanup()


def test_daemon_pid_reuse(base):
    car = Car(base)
    try:
        car.sh("sg_daemon_start fakesupp")
        pid = car.daemon_pid()
        # The PID now belongs to a different program: revert must not signal it.
        (car.proc / str(pid) / "cmdline").write_bytes(b"/system/bin/other\0")
        car.sh("sg_daemon_running fakesupp", code=1)
        car.sh("sg_revert_all")
        assert alive(pid)
        assert ("daemon_stop", "fakesupp", "absent") in car.ledger()
    finally:
        car.cleanup()


def test_daemon_refusals(base):
    for spec in ("@payload@/bin/fake-daemon ;reboot", "@payload@/bin/fake-daemon $(id)",
                 "@payload@/bin/fake-daemon -c `id`", "/data/local/tmp/fake-daemon",
                 "@payload@/../bin/fake-daemon", "@payload@/bin/fake-daemon @home@/x",
                 "@payload@/bin/fake-daemon @state@x", "@payload@/bin/fake-daemon *",
                 "sh -c reboot", "/system/bin/sh -c 'reboot'"):
        car = Car(base / f"spec{len(list(base.glob('spec*')))}", MANIFEST.replace(
            "daemon.fakesupp=@payload@/bin/fake-daemon -i rtwlan0 -c @state@/supp.conf", "daemon.fakesupp=" + spec))
        assert car.sh("sg_daemon_start fakesupp; echo rc=$?").stdout.strip() == "rc=2", spec
        assert not (car.state / "daemon.fakesupp").exists(), spec
    car = Car(base / "undeclared")
    car.sh("sg_daemon_start hostapd", code=2)
    car.sh("sg_daemon_start 'fake;supp'", code=2)
    same = "id=other\ndaemons=x\ndaemon.x=@payload@/bin/fake-daemon -i rtwlan0 -c @state@/supp.conf\n"
    Car(base / "claimed", others={"other": same}).sh("sg_daemon_start fakesupp", code=3)


def test_net_rules(base):
    car = Car(base)
    car.sh("sg_net_rule 1\nsg_net_rule 2\nsg_net_rule 1")
    assert car.lines("iptables") == ["nat POSTROUTING -o rtwlan0 -j MASQUERADE"]
    assert car.lines("rules") == ["from 192.168.50.0/24 lookup 60"]
    assert car.calls() == ["iptables -t nat -I POSTROUTING -o rtwlan0 -j MASQUERADE",
                           "ip rule add from 192.168.50.0/24 lookup 60"]
    assert car.ledger_text("net_rule_add", "after").strip() == "ip rule from 192.168.50.0/24 lookup 60"
    car.sh("sg_revert_all")
    assert car.lines("iptables") == [] and car.lines("rules") == []
    assert car.calls()[2:] == ["ip rule del from 192.168.50.0/24 lookup 60",
                               "iptables -t nat -D POSTROUTING -o rtwlan0 -j MASQUERADE"]
    assert ("net_rule_del", "1", "ok") in car.ledger() and ("net_rule_del", "2", "ok") in car.ledger()
    # Someone else deletes the rule within the same boot: conflict, the record stays.
    car.sh("sg_net_rule 1")
    (car.kernel / "iptables").write_text("")
    result = car.sh("sg_revert_all", code=3)
    assert "info.restore_conflict=" in result.stdout and (car.state / "net.1").exists()
    car.reboot()
    car.sh("sg_revert_all")
    assert not (car.state / "net.1").exists()


def test_net_rule_refusals(base):
    car = Car(base)
    car.sh("sg_net_rule 3", code=2)
    car.sh("sg_net_rule 01", code=2)
    car.sh("sg_net_rule '1;reboot'", code=2)
    for rule in ("iptables -t nat -A POSTROUTING -j MASQUERADE", "iptables INPUT -F",
                 "iptables -t raw PREROUTING -j NOTRACK", "iptables INPUT -j ACCEPT;reboot",
                 "iptables INPUT -j $(reboot)", "iptables --modprobe=/data/x INPUT -j ACCEPT",
                 "iptables INPUT --delete 1", "iptables INPUT", "ip rule add from 1.2.3.4 lookup 5",
                 "ip rule flush", "ip route add default dev rtwlan0", "ip6tables INPUT -j DROP",
                 "iptables INPUT -s 10.0.0.* -j DROP", "iptables INPUT -j LOG --log-prefix @state@"):
        case = Car(base / f"rule{len(list(base.glob('rule*')))}", MANIFEST + f"net_rules.3={rule}\n")
        case.sh("sg_net_rule 3", code=2)
        assert case.calls() == [], rule
    Car(base / "claimed", others={"other": "id=other\nnet_rules.7=ip rule from 192.168.50.0/24 lookup 60\n"}).sh(
        "sg_net_rule 2", code=3)


def test_iface_addr(base):
    car = Car(base)
    car.sh("sg_iface_addr rtwlan0 192.168.50.1/24\nsg_iface_addr rtwlan0 192.168.50.1/24")
    assert car.lines("addr.rtwlan0") == ["192.168.50.1/24"]
    assert (car.net / "rtwlan0/flags").read_text() == "0x1003\n"
    assert car.calls() == ["ip addr add 192.168.50.1/24 dev rtwlan0", "ip link set rtwlan0 up"]
    assert ("iface_addr_add", "rtwlan0", "ok") in car.ledger()
    car.sh("sg_revert_all")
    assert car.lines("addr.rtwlan0") == [] and (car.net / "rtwlan0/flags").read_text() == "0x1002\n"
    assert ("iface_addr_del", "rtwlan0", "ok") in car.ledger()
    # A link that was already up stays up.
    (car.net / "rtwlan0/flags").write_text("0x1003\n")
    car.sh("sg_iface_addr rtwlan0 192.168.50.1/24")
    car.sh("sg_revert_all")
    assert (car.net / "rtwlan0/flags").read_text() == "0x1003\n"
    assert "ip link set rtwlan0 down" not in car.calls()[-2:]
    car.sh("sg_iface_addr wlan0 192.168.50.1/24", code=2)
    car.sh("sg_iface_addr rtwlan0 300.1.1.1/24", code=2)
    car.sh("sg_iface_addr rtwlan0 192.168.50.1", code=2)
    car.sh("sg_iface_addr 'rtwlan0;reboot' 192.168.50.1/24", code=2)
    car.sh("sg_iface_addr rtwlan9 192.168.50.1/24", code=1)
    (car.kernel / "addr.rtwlan0").write_text("192.168.50.1/24\n")
    car.sh("sg_iface_addr rtwlan0 192.168.50.1/24", code=3)
    (car.kernel / "addr.rtwlan0").write_text("")
    # The dongle was unplugged before revert: nothing is left to undo.
    car.sh("sg_iface_addr rtwlan0 192.168.50.1/24")
    for entry in (car.net / "rtwlan0").iterdir():
        entry.unlink()
    (car.net / "rtwlan0").rmdir()
    car.sh("sg_revert_all")
    assert ("iface_addr_del", "rtwlan0", "absent") in car.ledger()
    Car(base / "claimed", others={"other": "id=other\nowns_ifaces=rtw*\n"}).sh(
        "sg_iface_addr rtwlan0 192.168.50.1/24", code=3)


def test_revert_after_reboot(base):
    car = Car(base)
    try:
        car.sh("sg_kmod_load r8188eu\nsg_iface_addr rtwlan0 192.168.50.1/24\n"
               "sg_daemon_start fakesupp\nsg_net_rule 1\nsg_net_rule 2")
        pid = car.daemon_pid()
        before = len(car.calls())
        # Restart: the kernel forgot everything; a live process with the old PID is not ours.
        car.reboot()
        for name in ("iptables", "rules", "addr.rtwlan0"):
            (car.kernel / name).write_text("")
        (car.proc / "modules").write_text("")
        (car.net / "rtwlan0/flags").write_text("0x1002\n")
        car.sh("sg_revert_all")
        assert len(car.calls()) == before and alive(pid)
        results = {(op, result) for op, _, result in car.ledger() if op.endswith(("_unload", "_stop", "_del"))}
        assert results == {("kmod_unload", "absent"), ("daemon_stop", "absent"),
                           ("net_rule_del", "absent"), ("iface_addr_del", "absent")}
        assert not (car.state / "changes").exists()
        assert not any(car.state.glob("kmod.*")) and not any(car.state.glob("net.*"))
        # A stale record never makes someone else's loaded module ours.
        car.sh("sg_kmod_load r8188eu")
        (base / "boot_id").write_text("boot-c\n")
        car.sh("sg_kmod_load r8188eu", code=3)
        car.sh("sg_revert_all")
        assert car.calls()[-1].startswith("insmod ") and "r8188eu" in (car.proc / "modules").read_text()
    finally:
        car.cleanup()


def test_declarations(base):
    car = Car(base)
    good = [("kmods", "r8188eu,cfg80211"), ("kmod.r8188eu", "drivers/r8188eu.ko"),
            ("kmod.r8188eu.tcc803x", "drivers/tcc803x/r8188eu.ko"), ("kmod_params.r8188eu", "a=1 b=x,y"),
            ("daemons", "wpa,dhcp-client"), ("daemon.wpa", "/system/bin/wpa_supplicant -i rtwlan0 -c@state@/w.conf"),
            ("daemon.dhcp", "@payload@/bin/udhcpc -p @state@/pid -s @payload@/script"),
            ("net_rules.1", "iptables FORWARD -i rtwlan0 ! -o rtwlan0 -j ACCEPT"),
            ("net_rules.12", "ip rule iif rtwlan0 lookup 61 prio 9000"), ("owns_ifaces", "rtwlan*,wlan1"),
            ("derived_bins", "hostapd"), ("daemon_user.wpa", "wifi"),
            ("derived_bin.hostapd", "/system/bin/hostapd /data/misc/wifi/all_sta.list usb_sta.list")]
    bad = [("kmods", ""), ("kmods", "R8188"), ("kmods", "a,,b"), ("kmod.r8188eu", "/system/lib/r.ko"),
           ("kmod.r8188eu", "drivers/r8188eu.so"), ("kmod.r8188eu.tcc.803", "d/r.ko"), ("kmod.R", "d/r.ko"),
           ("kmod_params.r8188eu", "a=1;b=2"), ("kmod_params.r8188eu", "flag"), ("kmod_params.r8188eu", "a=$(x)"),
           ("daemons", "-x"), ("daemon.wpa", "/system/bin/../xbin/su"), ("daemon.wpa", "/system/lib/x"),
           ("daemon.wpa", "/system/bin/wpa @state@@payload@"), ("daemon.wpa", "/system/bin/wpa a|b"),
           ("daemon.wpa", "/system/bin/wpa @state@x"), ("net_rules.0", "ip rule from all lookup 1"),
           ("net_rules.1", "iptables -t nat POSTROUTING -I x"), ("net_rules.1", "ip rule show"),
           ("owns_ifaces", "*"), ("owns_ifaces", "rtw[0-9]"), ("derived_bins", "-x"),
           ("daemon_user.wpa", "root"), ("daemon_user.wpa", "system"),
           ("derived_bin.hostapd", "/data/hostapd /data/x.list a"), ("derived_bin.hostapd", "/system/bin/hostapd data/x.list a"),
           ("derived_bin.hostapd", "/system/bin/hostapd /data/x.list a/b"), ("derived_bin.hostapd", "/system/bin/hostapd /d/x longername"),
           ("derived_bin.hostapd", "/system/bin/hostapd /data/../x.list a"), ("derived_bin.hostapd", "/system/bin/hostapd /data/x.list"),
           ("unknown", "x")]
    body = "".join(f"sg_transient_decl_ok '{k}' '{v}' || {{ echo 'refused {k}={v}'; exit 1; }}\n" for k, v in good)
    body += "".join(f"if sg_transient_decl_ok '{k}' '{v}'; then echo 'accepted {k}={v}'; exit 1; fi\n" for k, v in bad)
    car.sh(body)
    # The build-time ownership pass uses the same rules and claims across modules.
    spec = importlib.util.spec_from_file_location("ownership", ROOT / "tools/module-ownership.py")
    ownership = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ownership)
    declared = {"kmods": "r8188eu", "kmod.r8188eu": "d/r.ko", "daemons": "wpa,dhcp",
                "daemon.wpa": "/system/bin/wpa", "daemon.dhcp": "/system/bin/dhcp", "derived_bins": "hostapd",
                "derived_bin.hostapd": "/system/bin/hostapd /data/misc/wifi/all_sta.list usb_sta.list"}
    for key, value in good:
        fields = dict(declared, **{key: value})
        if key == "kmods":
            fields["kmod.cfg80211"] = "d/c.ko"
        if key == "daemons":
            fields["daemon.dhcp-client"] = fields.pop("daemon.dhcp")
        ownership.transient("m", fields, {})
    for key, value in bad[:-1]:
        try:
            ownership.transient("m", dict(declared, **{key: value}), {})
        except ValueError:
            continue
        raise AssertionError(f"build accepted {key}={value}")

    def generate(modules):
        root = base / f"gen{len(list(base.glob('gen*')))}"
        for module, text in modules.items():
            (root / "modules" / module).mkdir(parents=True)
            (root / "modules" / module / "module.properties").write_text(text)
        (root / "order").write_text("".join(f"{module}\n" for module in modules))
        ownership.generate(root, root / "order", root / "lines")
    first = "kmods=r8188eu\nkmod.r8188eu=d/r.ko\nowns_ifaces=rtwlan*\nnet_rules.1=ip rule from all lookup 60\n"
    generate({"a": first, "b": "daemons=x\ndaemon.x=/system/bin/x\nowns_ifaces=wlan1\n"})
    for second in ("kmods=r8188eu\nkmod.r8188eu=d/other.ko\n", "owns_ifaces=rtwlan0\n", "owns_ifaces=rtw*\n",
                   "net_rules.4=ip rule from all lookup 60\n", "kmods=x\n", "daemons=x\n",
                   "kmod.r8188eu=d/r.ko\n", "net_rules.1=ip rule from all lookup 61\nnet_rules.1=ip rule from all lookup 62\n"):
        try:
            generate({"a": first, "b": second})
        except ValueError:
            continue
        raise AssertionError(f"build accepted second module: {second!r}")
    (base / "clash.properties").write_text("kmods=wrongmagic\n")
    assert car.sh(f'sg_transient_clash "{base}/clash.properties" other').stdout.strip() == MODULE
    (base / "clash.properties").write_text("kmods=other\nowns_ifaces=eth*\n")
    car.sh(f'sg_transient_clash "{base}/clash.properties" other', code=1)


def test_revert_transient_keeps_persistent(base):
    car = Car(base)
    try:
        car.sh("sg_kmod_load r8188eu\nsg_daemon_start fakesupp\nsg_net_rule 1")
        pid = car.daemon_pid()
        # A persistent record stays: only transient kinds are undone and dropped from changes.
        (car.state / "changes").write_text((car.state / "changes").read_text() + "prop\tpersist.kept\n")
        car.sh("sg_revert_transient keep_kmods")
        wait_gone(pid)
        assert (car.state / "changes").read_text() == "kmod\tr8188eu\nprop\tpersist.kept\n"
        car.sh("sg_kmod_loaded r8188eu")
        assert car.lines("iptables") == [] and not any(row.startswith("rmmod") for row in car.calls())
        car.sh("sg_revert_transient")
        assert (car.state / "changes").read_text() == "prop\tpersist.kept\n"
        assert (car.proc / "modules").read_text() == "" and car.lines("iptables") == []
        assert car.calls()[-2:] == ["iptables -t nat -D POSTROUTING -o rtwlan0 -j MASQUERADE", "rmmod r8188eu"]
        (car.state / "changes").unlink()
        car.sh("sg_kmod_load r8188eu")
        car.sh("sg_revert_transient")
        assert not (car.state / "changes").exists()
        car.sh("sg_revert_transient x", code=2)
    finally:
        car.cleanup()


def test_daemon_restart(base):
    car = Car(base)
    try:
        car.sh("sg_daemon_restart fakesupp")
        first = car.daemon_pid()
        car.sh("sg_daemon_restart fakesupp")
        second = car.daemon_pid()
        wait_gone(first)
        assert second != first and alive(second)
        assert [row[0] for row in car.ledger()] == ["daemon_start", "daemon_stop", "daemon_start"]
        car.sh("sg_daemon_restart hostapd", code=2)
        car.sh("sg_revert_all")
        wait_gone(second)
    finally:
        car.cleanup()


def test_system_daemon_seam(base):
    car = Car(base, MANIFEST.replace("daemon.fakesupp=@payload@/bin/fake-daemon", "daemon.fakesupp=/system/bin/fake-daemon"))
    executable(base / "tools/system/bin/fake-daemon", FAKE_DAEMON)
    try:
        car.sh("sg_daemon_start fakesupp\nsg_daemon_running fakesupp")
        pid = car.daemon_pid()
        assert (car.proc / str(pid) / "cmdline").read_bytes().split(b"\0")[0] == \
            str(base / "tools/system/bin/fake-daemon").encode()
        car.sh("sg_revert_all")
        wait_gone(pid)
    finally:
        car.cleanup()


def test_daemon_exit_reason(base):
    car = Car(base)
    executable(car.payload / "bin/fake-daemon", "#!/bin/sh\nexit 3\n")
    car.sh("sg_daemon_start fakesupp", code=1)
    assert "daemon fakesupp did not stay up: exited 3" in (car.state / "module.log").read_text()
    assert ("daemon_start", "fakesupp", "failed") in car.ledger()


def test_daemon_user(base):
    car = Car(base, MANIFEST + "daemon_user.fakesupp=wifi\n")
    executable(base / "fake/chown", '#!/bin/sh\necho "chown $*" >> "$FAKE_KERNEL/calls"\n')
    car.state.mkdir(parents=True, exist_ok=True)
    (car.state / "supp.conf").write_text("network={}\n")
    run = car.state / "run/fakesupp"
    try:
        car.sh("sg_daemon_start fakesupp\nsg_daemon_running fakesupp")
        pid = car.daemon_pid()
        # The config is a private copy in the wifi-owned run directory, passed relative to it.
        argv = (car.proc / str(pid) / "cmdline").read_bytes().split(b"\0")
        assert argv[1:5] == [b"-i", b"rtwlan0", b"-c", b"supp.conf"], argv
        assert (run / "supp.conf").read_text() == "network={}\n"
        assert f"chown 1010:1010 {run}" in car.calls() and f"chown 1010:1010 {run}/supp.conf" in car.calls()
        car.sh("sg_revert_all")
        wait_gone(pid)
    finally:
        car.cleanup()
    Car(base / "other", MANIFEST + "daemon_user.fakesupp=root\n").sh("sg_daemon_start fakesupp", code=2)


def test_derived_program(base):
    classes = base / "binpatch-classes"
    subprocess.run(["javac", "-nowarn", "-d", str(classes),
                    str(ROOT / "core/hsm/src/com/seogaemo/hmg/core/hsm/HmgSeogaemoBinPatch.java")],
                   check=True, capture_output=True)
    manifest = MANIFEST.replace("daemon.fakesupp=@payload@/bin/fake-daemon", "daemon.fakesupp=/system/bin/fake-daemon")
    manifest += ("derived_bins=fakehostapd\n"
                 "derived_bin.fakehostapd=/system/bin/fake-daemon /data/misc/wifi/all_sta.list usb_sta.list\n")
    car = Car(base, manifest)
    executable(base / "fake/app_process", f'#!/bin/sh\nshift\nexec java -cp "{classes}" "$@"\n')
    stock = base / "tools/system/bin/fake-daemon"
    copy = car.state / "bin/fakehostapd"
    try:
        # Nothing to replace: the daemon runs as an identical private copy.
        executable(stock, FAKE_DAEMON)
        car.sh("sg_daemon_start fakesupp\nsg_daemon_running fakesupp")
        pid = car.daemon_pid()
        assert (car.proc / str(pid) / "cmdline").read_bytes().split(b"\0")[0] == str(copy).encode()
        assert copy.read_bytes() == stock.read_bytes()
        car.sh("sg_revert_all")
        wait_gone(pid)
        # Every occurrence becomes the NUL-padded file name; the stock program is only read.
        blob = b"\x7fELF" + b"/data/misc/wifi/all_sta.list\x00x" * 2
        stock.write_bytes(blob)
        car.sh("sg_bin_derive fakehostapd")
        assert copy.read_bytes() == blob.replace(b"/data/misc/wifi/all_sta.list", b"usb_sta.list".ljust(28, b"\0"))
        assert stock.read_bytes() == blob
        rows = [row for row in car.ledger() if row[0] == "bin_derive"]
        assert len(rows) == 2 and all(row[2] == "ok" for row in rows)
        car.sh("sg_bin_derive fakehostapd")
        assert [row for row in car.ledger() if row[0] == "bin_derive"] == rows
        car.sh("sg_bin_derive other", code=2)
    finally:
        car.cleanup()


def test_peer_info(base):
    car = Car(base)
    car.sh("sg_peer_publish radio=usb interface=rtwlan0 ip=192.168.50.1 ssid=HMG-Seogaemo-1a2b ready=1 empty=")
    peer = base / "data/peer" / MODULE
    assert peer.read_text().splitlines()[0] == "radio=usb" and oct(peer.parent.stat().st_mode & 0o777) == "0o700"
    assert car.sh(f"sg_peer_info {MODULE} ssid").stdout == "HMG-Seogaemo-1a2b\n"
    assert car.sh(f"sg_peer_info {MODULE} empty").stdout == "\n"
    car.sh(f"sg_peer_info {MODULE} channel", code=1)
    car.sh("sg_peer_info other radio", code=1)
    for bad in ("sg_peer_info '../x' radio", f"sg_peer_info {MODULE} 'ra dio'", f"sg_peer_info {MODULE}",
                "sg_peer_publish 'Radio=usb'", "sg_peer_publish radio", "sg_peer_publish 'ssid=a|b'",
                "sg_peer_publish 'ssid=$(reboot)'", "sg_peer_publish 'ssid=a\nradio=x'"):
        car.sh(bad, code=2)
    assert car.sh(f"sg_peer_info {MODULE} radio").stdout == "usb\n"
    car.sh("sg_peer_publish")
    assert not peer.exists()
    car.sh(f"sg_peer_info {MODULE} radio", code=1)


def test_mutation_lint(base):
    module = base / "modules/x/root/x.sh"
    module.parent.mkdir(parents=True)
    lint = ROOT / "tools/lint-module-root.py"
    for line in ("insmod /data/x.ko", "rmmod r8188eu", "modprobe cfg80211", "kill 1234", "ip addr add 1.2.3.4/24 dev rtwlan0",
                 "ip -4 rule add from all lookup 5", "/system/bin/ip link set rtwlan0 up", "iptables -F",
                 "sg_tool_iptables -t nat -F", "sg_net_rule_exec add x", "sg_kmod_revert r8188eu", "nohup daemon &"):
        module.write_text(f'. "$HMG_SEOGAEMO_BASE/lib/common.sh"\n{line}\n')
        result = subprocess.run([sys.executable, str(lint), str(module)], capture_output=True, text=True)
        assert result.returncode != 0 and "direct mutation" in result.stderr, line
    module.write_text('. "$HMG_SEOGAEMO_BASE/lib/common.sh"\nsg_kmod_load r8188eu\nsg_daemon_start wpa\n'
                      'sg_net_rule 1\nsg_iface_addr rtwlan0 192.168.50.1/24\nsg_print "info.hotspot_ip=$ip"\n'
                      'sg_daemon_running wpa && sg_kmod_loaded r8188eu\n')
    subprocess.run([sys.executable, str(lint), str(module)], check=True, capture_output=True)


run_tests([
    test_kmod_apply_revert,
    test_kmod_refusals,
    test_daemon_apply_revert,
    test_daemon_pid_reuse,
    test_daemon_refusals,
    test_net_rules,
    test_net_rule_refusals,
    test_iface_addr,
    test_revert_after_reboot,
    test_declarations,
    test_revert_transient_keeps_persistent,
    test_daemon_restart,
    test_system_daemon_seam,
    test_daemon_exit_reason,
    test_daemon_user,
    test_derived_program,
    test_peer_info,
    test_kmod_timeout,
    test_mutation_lint,
], "transient runtime tests passed")
