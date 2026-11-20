#!/usr/bin/env python3
"""Android Auto lane packing of the aa-tbt-*.recipe segments (payload/recipes/aa-lane-routes.s).

The native patch packs the lanes of the first NavigationState step into next-turn event 34: "nn",
then per lane 8 hex digits (a lane byte and three arrow bytes). Upstream wrote 1 or 2 as the lane
byte; now it is the mask of the lane's recommended arrow slots, and U-turn right keeps its arrow.

Always: the segment sites equal the assembled source (needs clang and llvm-objcopy for thumbv7;
skipped with a note when missing) and both recipes carry the same code. When the python module
`unicorn` is installed the real Thumb code is run on protobuf NavigationState messages and the
event-34 strings are compared (the host test of AaTurns/CpLaneFrame covers the Java side).
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.abspath(os.path.join(HERE, "..", ".."))
RECIPES = ("aa-tbt-48ee793a", "aa-tbt-a0bea1c4", "aa-tbt-dbfe7bd2")
UPSTREAM_LEN = {"aa-tbt-48ee793a": 5546, "aa-tbt-a0bea1c4": 5640, "aa-tbt-dbfe7bd2": 5546}
# segment offset, bytes as patched (little-endian halfwords): the upstream bytes are in payload/recipes/apply-aa-lane-routes.py
SITES = ((0xF7E, 4), (0xFF2, 6), (0x101C, 4), (0x1598, 1))
MAIN = 0x7EC


def fail(msg):
    print("FAIL aalanes: " + msg)
    sys.exit(1)


def segment(name):
    with open(os.path.join(MOD, "files", "recipes", name + ".recipe")) as f:
        m = re.search(r"^segment \S+ ([0-9a-f]+)$", f.read(), re.M)
    if not m:
        fail(name + ": no segment line")
    return bytes.fromhex(m.group(1))


def tool(*names):
    for n in names:
        for d in [None, "/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]:
            p = shutil.which(n, path=d) if d else shutil.which(n)
            if p:
                return p
    return None


def assembled(tail):
    clang, objcopy = tool("clang"), tool("llvm-objcopy", "objcopy")
    if not clang or not objcopy:
        return None
    with tempfile.TemporaryDirectory() as d:
        obj, out = os.path.join(d, "x.o"), os.path.join(d, "x.bin")
        r = subprocess.run([clang, "--target=thumbv7-linux-androideabi", "-x", "assembler-with-cpp", "-DTAIL=%d" % tail,
                            "-c", os.path.join(MOD, "payload", "recipes", "aa-lane-routes.s"), "-o", obj],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode:
            return None
        if subprocess.run([objcopy, "-O", "binary", "--only-section=.text", obj, out]).returncode:
            return None
        return open(out, "rb").read()


def check_sites():
    segs = {n: segment(n) for n in RECIPES}
    for n, seg in segs.items():
        tail = (UPSTREAM_LEN[n] + 3) & ~3
        if len(seg) <= tail:
            fail("%s: segment has no tail (%d bytes)" % (n, len(seg)))
        blob = assembled(tail)
        if blob is None:
            print("note aalanes: no clang for thumbv7, assembled check skipped")
            continue
        for off, ln in SITES:
            if seg[off:off + ln] != blob[off:off + ln]:
                fail("%s: segment +0x%x differs from payload/recipes/aa-lane-routes.s: %s vs %s" % (n, off, seg[off:off + ln].hex(), blob[off:off + ln].hex()))
        if seg[tail:tail + len(blob) - tail] != blob[tail:]:
            fail("%s: the tail differs from payload/recipes/aa-lane-routes.s" % n)
        if any(seg[UPSTREAM_LEN[n]:tail]):
            fail("%s: padding before the tail is not zero" % n)
    # the code is the same in both recipes (the rel32 slots at 0x40..0x53 differ, a0bea1c4 has an extra helper after the code)
    a, b = segs[RECIPES[0]], segs[RECIPES[1]]
    for i in range(0x54, UPSTREAM_LEN[RECIPES[0]]):
        if a[i] != b[i] and not 0x101C <= i < 0x1020:   # the branch to the tail differs by where the tail is
            fail("recipes differ at segment +0x%x" % i)
    ta, tb = (UPSTREAM_LEN[RECIPES[0]] + 3) & ~3, (UPSTREAM_LEN[RECIPES[1]] + 3) & ~3
    if a[ta:-4] != b[tb:tb + len(a) - ta - 4]:   # the last 4 bytes branch back, relative to the tail
        fail("the tails of the two recipes differ")
    if len(b) - tb != len(a) - ta:
        fail("the tails of the two recipes differ in length")


# ---- the real Thumb code on NavigationState messages (optional)

def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def fld(num, payload):
    return varint(num << 3 | 2) + varint(len(payload)) + payload


def vfld(num, v):
    return varint(num << 3) + varint(v)


def state(lanes):
    """NavigationState{steps[0]: maneuver, cue, lanes (each a list of (shape, recommended)), roads}; recommended None: field absent"""
    def direction(shape, rec):
        return vfld(1, shape) + (b"" if rec is None else vfld(2, 1 if rec else 0))
    def lane(dirs):
        return b"".join(fld(1, direction(s, r)) for s, r in dirs)
    step = fld(1, vfld(1, 4)) + fld(2, fld(1, b"Turn left")) + b"".join(fld(3, lane(l)) for l in lanes) + fld(4, fld(1, b"Main St"))
    return fld(1, step)


class Emulator:
    SEG, STK, DAT, STUB = 0x10000000, 0x70000000, 0x30000000, 0x20000000

    def __init__(self, seg):
        from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE, UcError  # noqa: F401
        self.seg = seg

    def lanes(self, proto):
        from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_CODE, UcError
        from unicorn.arm_const import (UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_R0, UC_ARM_REG_R1,
                                       UC_ARM_REG_R2, UC_ARM_REG_R3)
        mu = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
        mu.mem_map(self.SEG, 0x10000)
        mu.mem_write(self.SEG, self.seg)
        mu.mem_map(self.STK, 0x100000)
        mu.mem_map(self.DAT, 0x100000)
        mu.mem_map(self.STUB, 0x1000)
        mu.mem_write(self.DAT + 0x2C, struct.pack("<I", 0x12345678))   # the handle's field the entry insists on
        mu.mem_write(self.DAT + 0x1000, proto)
        sp = self.STK + 0xF0000
        mu.reg_write(UC_ARM_REG_SP, sp)
        mu.mem_write(sp, struct.pack("<4I", self.STUB + 0x10, self.STUB + 0x20, self.STUB + 0x30, self.STUB + 0x40))
        ret = self.STUB + 0x100
        mu.mem_write(ret, b"\x00\xbf")
        mu.reg_write(UC_ARM_REG_LR, ret | 1)
        for reg, val in ((UC_ARM_REG_R0, self.DAT), (UC_ARM_REG_R1, 0x8006), (UC_ARM_REG_R2, self.DAT + 0x1000), (UC_ARM_REG_R3, len(proto))):
            mu.reg_write(reg, val)
        events = []

        def hook(uc, addr, size, ud):
            if addr == self.SEG + 0x1D8:      # the event emitter: (handle, callback, assign, free, str, len, side, event, a, b)
                lr = uc.reg_read(UC_ARM_REG_LR)
                s = uc.reg_read(UC_ARM_REG_SP)
                st = struct.unpack("<6i", bytes(uc.mem_read(s, 24)))
                text = bytes(uc.mem_read(st[0], st[1])) if st[0] and 0 <= st[1] < 4096 else b""
                events.append((st[3], text))
            else:                              # the library's helpers: return 0
                lr = uc.reg_read(UC_ARM_REG_LR)
                uc.reg_write(UC_ARM_REG_R0, 0)
            uc.reg_write(UC_ARM_REG_PC, lr)
        mu.hook_add(UC_HOOK_CODE, hook, None, self.SEG + 0x1D8, self.SEG + 0x1D9)
        mu.hook_add(UC_HOOK_CODE, hook, None, self.STUB + 0x10, self.STUB + 0x50)
        try:
            mu.emu_start((self.SEG + MAIN) | 1, ret, count=2000000)
        except UcError as e:
            fail("the lane code crashed: %s" % e)
        return [t.decode() for ev, t in events if ev == 34]


# (name, lanes, wanted event 34 string): "nn" lanes, per lane mask + three arrow classes
VECTORS = (
    ("straight+right with the right on the route, then right only",
     [[(1, False), (5, True)], [(5, True)]], "02" + "02010300" + "01030000"),
    ("no recommendation: masks stay 0",
     [[(1, False)], [(1, None), (5, False)]], "02" + "00010000" + "00010300"),
    ("U-turn left and right both draw the U-turn arrow",
     [[(8, True)], [(9, True)]], "02" + "01050000" + "01050000"),
    ("three arrows, the middle one on the route; a fourth direction is dropped",
     [[(2, False), (3, True), (4, False), (5, True)]], "01" + "02080207"),
    ("a lane without a usable arrow is left out",
     [[(0, True)], [(1, True)]], "01" + "01010000"),
    ("no lanes", [], ""),
    ("at most eight lanes", [[(7, True)]] * 9, "08" + "01040000" * 8),
)


def check_behaviour():
    try:
        import unicorn  # noqa: F401
    except ImportError:
        print("note aalanes: python module unicorn missing, the emulated lane code check skipped")
        return 0
    n = 0
    for name in RECIPES:
        emu = Emulator(segment(name))
        for title, lanes, want in VECTORS:
            got = emu.lanes(state(lanes))
            if got != [want]:
                fail("%s: %s: got %r, wanted %r" % (name, title, got, [want]))
            n += 1
    return n


def main():
    check_sites()
    n = check_behaviour()
    print("ok aalanes: patch sites and tail in both recipes%s" % ("" if not n else ", %d emulated lane strings" % n))


if __name__ == "__main__":
    main()
