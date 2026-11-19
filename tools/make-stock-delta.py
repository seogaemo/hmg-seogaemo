#!/usr/bin/env python3
"""Make a stock-relative HSD1 file. Only the build host needs bsdiff4 (1.2.6)."""
import argparse
import gzip
import hashlib
import struct
from pathlib import Path

from bsdiff4 import core

parser = argparse.ArgumentParser(description=__doc__)
for name in ("stock", "replacement", "output"):
    parser.add_argument(name, type=Path)
args = parser.parse_args()
stock, updated = args.stock.read_bytes(), args.replacement.read_bytes()
controls, differences, extra = core.diff(stock, updated)
patch = bytearray(b"HSD1" + hashlib.sha256(stock).digest() + hashlib.sha256(updated).digest())
patch.extend(struct.pack(">III", len(stock), len(updated), len(controls)))
i = j = 0
for add, copy, seek in controls:
    patch.extend(struct.pack(">iii", add, copy, seek))
    patch.extend(differences[i:i + add])
    patch.extend(extra[j:j + copy])
    i += add
    j += copy
assert i == len(differences) and j == len(extra)
args.output.write_bytes(gzip.compress(patch, compresslevel=9, mtime=0))
