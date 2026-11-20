#!/usr/bin/env python3
"""Android Auto turn-by-turn UTF-8 length helper (aa-tbt-*.recipe, segment offset 0x17a).

The helper returns how many bytes of a string go into the NavigationStatus callbacks (at most
96). The version upstream HMG-API ships (and we shipped) dropped trailing continuation bytes even for short strings,
so the last Hangul syllable arrived incomplete. This test runs the actual Thumb bytes of the
recipes (and of the old helper, to reproduce the bug) in a small interpreter, compares them with
a host model and with Python's own UTF-8 decoder, and checks the recipe slot against the
assembled payload/recipes/aa-utf8-len.s when clang is available.
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
SLOT, SLOT_LEN = 0x17A, 32
LIMIT = 96
# The helper as upstream HMG-API 1.0.2 and our recipes shipped it (the bug).
OLD = bytes.fromhex("6029024628bf602108460139535c03f0c003802b00d070470029f5d108467047")


def fail(msg):
    print("FAIL aautf8: " + msg)
    sys.exit(1)


def segment(name):
    with open(os.path.join(MOD, "files", "recipes", name + ".recipe")) as f:
        m = re.search(r"^segment \S+ ([0-9a-f]+)$", f.read(), re.M)
    if not m:
        fail(name + ": no segment line")
    return bytes.fromhex(m.group(1))


class Thumb:
    """Just enough Thumb/Thumb-2 for the two helpers; anything else aborts the test."""

    def __init__(self, code, data):
        self.code, self.data = code, data
        self.r = [0] * 16
        self.n = self.z = self.c = self.v = False
        self.it = []   # condition of each remaining IT-block instruction

    def cond(self, cc):
        n, z, c, v = self.n, self.z, self.c, self.v
        base = (z, c, n, v, c and not z, n == v, (n == v) and not z)[cc >> 1] if cc < 14 else True
        return (not base) if (cc & 1) and cc < 14 else base

    def sub(self, a, b, store=None):
        res = (a - b) & 0xFFFFFFFF
        self.n, self.z, self.c = bool(res >> 31), res == 0, a >= b
        self.v = bool(((a ^ b) & (a ^ res)) >> 31)
        return res

    def nz(self, res):
        self.n, self.z = bool(res >> 31), res == 0

    def load8(self, addr):
        off = addr - 0x1000
        if not 0 <= off < len(self.data):
            fail("helper read outside the string at +%d (length %d)" % (off, len(self.data)))
        return self.data[off]

    def run(self, ptr, length, entry=0):
        r = self.r
        r[0], r[1], r[14] = ptr, length, 0xFFFFFFF0
        pc, steps = entry, 0
        while True:
            steps += 1
            if steps > 2000:
                fail("helper does not terminate")
            hw = struct.unpack_from("<H", self.code, pc)[0]
            run = True
            if self.it:
                cc = self.it.pop(0)
                run = self.cond(cc)
            nxt = pc + 2
            if (hw & 0xF800) >= 0xE800 and (hw >> 11) in (0x1D, 0x1E, 0x1F):   # 32-bit
                hw2 = struct.unpack_from("<H", self.code, pc + 2)[0]
                nxt = pc + 4
                if (hw & 0xFBE0) == 0xF000 and (hw2 & 0x8000) == 0:           # and.w rd, rn, #imm
                    imm = ((hw >> 10) & 1) << 11 | ((hw2 >> 12) & 7) << 8 | (hw2 & 0xFF)
                    if imm > 0xFF or (hw & 0x10):
                        fail("unsupported and.w form at 0x%x" % pc)
                    if run:
                        r[(hw2 >> 8) & 0xF] = r[hw & 0xF] & imm
                else:
                    fail("unsupported instruction %04x %04x at 0x%x" % (hw, hw2, pc))
            elif hw == 0x4770:                                                 # bx lr
                if run:
                    if r[14] == 0xFFFFFFF0:
                        return r[0]
                    fail("bx lr to an unexpected address")
            elif (hw & 0xFF00) == 0xBF00:                                      # it / nop
                mask = hw & 0xF
                if mask:
                    fc = (hw >> 4) & 0xF
                    n = 4 - (mask & -mask).bit_length() + 1
                    conds = [fc]
                    for i in range(1, n):
                        bit = (mask >> (4 - i)) & 1
                        conds.append(fc if bit == (fc & 1) else fc ^ 1)
                    self.it = conds
            elif (hw & 0xF800) == 0x2800:                                      # cmp rn, #imm8
                if run:
                    self.sub(r[(hw >> 8) & 7], hw & 0xFF)
            elif (hw & 0xF800) == 0x2000:                                      # movs rd, #imm8
                if run:
                    r[(hw >> 8) & 7] = hw & 0xFF
                    self.nz(hw & 0xFF)
            elif (hw & 0xF800) == 0x3800:                                      # subs rdn, #imm8
                if run:
                    d = (hw >> 8) & 7
                    r[d] = self.sub(r[d], hw & 0xFF)
            elif (hw & 0xFF00) == 0x4600:                                      # mov rd, rm
                if run:
                    r[(hw & 7) | ((hw >> 4) & 8)] = r[(hw >> 3) & 0xF]
            elif (hw & 0xFFC0) == 0x4000:                                      # ands rdn, rm
                if run:
                    d = hw & 7
                    r[d] &= r[(hw >> 3) & 7]
                    self.nz(r[d])
            elif (hw & 0xFE00) == 0x5C00:                                      # ldrb rt, [rn, rm]
                if run:
                    r[hw & 7] = self.load8(r[(hw >> 3) & 7] + r[(hw >> 6) & 7])
            elif (hw & 0xF000) == 0xD000 and (hw >> 8) & 0xF < 14:             # b<cond>
                if run and self.cond((hw >> 8) & 0xF):
                    off = hw & 0xFF
                    nxt = pc + 4 + 2 * (off - 256 if off & 0x80 else off)
            else:
                fail("unsupported instruction %04x at 0x%x" % (hw, pc))
            pc = nxt


def call(code, s):
    t = Thumb(code, s)
    return t.run(0x1000, len(s))


def model_old(s):
    """What the bug did, in words: for a string ending in a continuation byte it kept the lead
    byte of the last character and none of its continuation bytes."""
    n = min(len(s), LIMIT)
    while True:
        r, n = n, n - 1
        if (s[n] & 0xC0) != 0x80:
            return r
        if n == 0:
            return 0


def model_new(s):
    if len(s) <= LIMIT:
        return len(s)
    n = LIMIT
    while n > 0 and (s[n] & 0xC0) == 0x80:
        n -= 1
    return n


def samples():
    out = []
    chars = ["a", "Z", "~", "é", "ß", "한", "글", "쀀", "퀀", "€", "\U0001F600", "\U00020000"]
    out += [c.encode() for c in chars]
    out += [s.encode() for s in ("우회", "우회쀀", "U턴", "직진", "고속도로 진입", "Turn left onto Teheran-ro",
                                 "서울 강남구 테헤란로 152 (역삼동)", "A한B글C", "a" * 40 + "한글" * 10)]
    out += [chr(c).encode() for c in range(0xAC00, 0xD7A4)]               # every Hangul syllable
    out += [("우회" + chr(c)).encode() for c in range(0xAC00, 0xD7A4)]
    out += [("ab" + chr(c)).encode() for c in range(0xAC00, 0xD7A4, 7)]
    for ch in ("é", "한", "\U0001F600"):                                  # boundary inside 2/3/4-byte characters
        w = len(ch.encode())
        for pad in range(LIMIT - 2 * w - 2, LIMIT + 4):
            for tail in range(1, 4):
                out.append(("a" * pad + ch * tail).encode())
                out.append((ch * tail + "a" * pad).encode())
    for total in (LIMIT - 1, LIMIT, LIMIT + 1, LIMIT + 2):               # exact lengths 95..98
        out.append(b"a" * total)
        out.append(("한" * (total // 3)).encode() + b"a" * (total % 3))
        out.append(("é" * (total // 2)).encode() + b"a" * (total % 2))
    out.append(b"\x80" * 120)                                             # not UTF-8 at all: stay in bounds
    out.append(b"a" + b"\x80" * 120)
    return out


def check_behaviour(label, code):
    """The helper from the recipe bytes agrees with the host model and with a UTF-8 decoder."""
    n = 0
    for s in samples():
        got = call(code, s)
        if got != model_new(s):
            fail("%s: %r (%d bytes): helper %d, model %d" % (label, s, len(s), got, model_new(s)))
        if got > LIMIT:
            fail("%s: %r: %d bytes exceed %d" % (label, s, got, LIMIT))
        try:
            s.decode("utf-8")
        except UnicodeDecodeError:
            n += 1
            continue
        if len(s) <= LIMIT and got != len(s):
            fail("%s: short string %r cut from %d to %d bytes" % (label, s, len(s), got))
        try:
            s[:got].decode("utf-8")
        except UnicodeDecodeError:
            fail("%s: %r cut inside a character at %d" % (label, s, got))
        if len(s) > LIMIT and got < LIMIT - 3:
            fail("%s: %r over-trimmed to %d" % (label, s, got))
        n += 1
    return n


def check_bug_reproduced():
    """The old bytes cut every short string that ends in a multi-byte character."""
    for s in samples():
        if len(s) > LIMIT:
            continue
        try:
            s.decode("utf-8")
        except UnicodeDecodeError:
            continue
        old = call(OLD, s)
        if old != model_old(s):
            fail("old helper model drifted for %r: %d vs %d" % (s, old, model_old(s)))
    for syl in range(0xAC00, 0xD7A4):
        s = chr(syl).encode()
        old = call(OLD, s)
        if old == len(s) or len(s) != 3:
            fail("old helper did not cut U+%04X" % syl)
        if s[:old].decode("utf-8", "replace") == chr(syl):
            fail("old helper kept U+%04X whole" % syl)
    # The reported symptoms: the last syllable arrives as its lead byte alone.
    for text in ("우회쀀", "U퀀"):
        s = text.encode()
        old = call(OLD, s)
        if old != len(s) - 2 or s[:old].decode("utf-8", "replace") == text:
            fail("old helper does not reproduce the cut of %r" % text)
    for s in (b"abc", b"a" * 96):
        if call(OLD, s) != len(s):
            fail("old helper cut an ASCII string")


def assembled():
    clang = os.environ.get("CLANG") or shutil.which("clang")
    if not clang:
        return None
    src = os.path.join(MOD, "payload", "recipes", "aa-utf8-len.s")
    with tempfile.TemporaryDirectory() as d:
        obj = os.path.join(d, "u.o")
        r = subprocess.run([clang, "--target=armv7a-linux-androideabi", "-mthumb", "-c", src, "-o", obj],
                           capture_output=True, text=True)
        if r.returncode:
            return None
        with open(obj, "rb") as f:
            e = f.read()
    # ELF32 little endian: find the .text section
    shoff, shentsize, shnum, shstrndx = struct.unpack_from("<I", e, 0x20)[0], *struct.unpack_from("<HHH", e, 0x2E)
    secs = [struct.unpack_from("<IIIIIIIIII", e, shoff + i * shentsize) for i in range(shnum)]
    strtab = secs[shstrndx]
    for sec in secs:
        name = e[strtab[4] + sec[0]:].split(b"\0", 1)[0]
        if name == b".text":
            return e[sec[4]:sec[4] + sec[5]]
    return None


def main():
    fixed = None
    segs = {}
    for name in RECIPES:
        seg = segment(name)
        segs[name] = seg
        slot = seg[SLOT:SLOT + SLOT_LEN]
        if slot == OLD:
            fail(name + ": still carries the unfixed UTF-8 length helper")
        if seg.count(OLD[:8]) or seg.count(bytes.fromhex("6029024628bf")):
            fail(name + ": a copy of the old helper remains in the segment")
        if fixed is None:
            fixed = slot
        elif slot != fixed:
            fail(name + ": helper differs between the two recipes")
    # Only the slot differs between the two stock variants' helpers: neighbours stay as shipped.
    for name, seg in segs.items():
        if seg[SLOT + SLOT_LEN:SLOT + SLOT_LEN + 2] != bytes.fromhex("70b5"):
            fail(name + ": the code after the slot moved")
    cases = check_behaviour("recipe bytes", fixed)
    check_bug_reproduced()
    obj = assembled()
    if obj is None:
        print("note aautf8: no clang for thumbv7, assembled check skipped")
    else:
        if obj != fixed:
            fail("recipe slot differs from payload/recipes/aa-utf8-len.s: %s vs %s" % (fixed.hex(), obj.hex()))
    print("ok aautf8: %d strings, fixed helper correct in both recipes, old helper reproduces the cut%s"
          % (cases, "" if obj is None else ", slot equals the assembled source"))


main()
