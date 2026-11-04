#!/usr/bin/env python3
"""Check SLSsteam byte signatures against an ELF image.

Parses the Pattern_t table from a SLSsteam src/patterns.cpp, then scans the
executable segments of the target module. Reports unique / ambiguous / missing
matches, which is the first gate before a 64-bit or ARM build is viable.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import elf_symbols as elf  # noqa: E402

PATTERN_RE = re.compile(
    r'Pattern_t\s+(\w+)\s*\{\s*"([^"]+)"\s*,\s*"([0-9A-Fa-f? ]+)"\s*,'
    r'\s*(?:SigFollowMode::|MemHlp::SigFollowMode::)?(\w+)'
)


def parse_patterns(path):
    text = open(path, encoding="utf-8").read()
    out = []
    for name, display, sig, mode in PATTERN_RE.findall(text):
        out.append((name, display, sig, mode))
    return out


def compile_sig(sig):
    toks = sig.split()
    return [(int(t, 16) if t != "?" else None) for t in toks]


def scan(data, segs, sig):
    hits = []
    for base, buf in segs:
        i = 0
        n = len(sig)
        while i + n <= len(buf):
            ok = True
            for j, want in enumerate(sig):
                if want is not None and buf[i + j] != want:
                    ok = False
                    break
            if ok:
                hits.append(base + i)
                i += 1
            else:
                i += 1
    return hits


def executable_segments(data, secs):
    out = []
    for s in secs:
        if s["type"] == 1 and (s["flags"] & 0x4):  # SHF_EXECINSTR
            out.append((s["addr"], data[s["offset"]:s["offset"] + s["size"]]))
    return out


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: check_patterns.py <patterns.cpp> <elf>")
    patterns = parse_patterns(sys.argv[1])
    data = open(sys.argv[2], "rb").read()
    secs = elf.sections(data)
    segs = executable_segments(data, secs)
    print(f"patterns={len(patterns)} executable_bytes={sum(len(b) for _, b in segs)}")
    unique = ambig = miss = 0
    for name, display, sig, mode in patterns:
        hits = scan(data, segs, compile_sig(sig))
        if len(hits) == 1:
            unique += 1
            print(f"OK        {name:<28} {display:<45} {hits[0]:#x} ({mode})")
        elif not hits:
            miss += 1
            print(f"MISS      {name:<28} {display:<45}")
        else:
            ambig += 1
            print(f"AMBIG({len(hits)}) {name:<28} {display:<45} first={hits[0]:#x}")
    print(f"\nsummary: unique={unique} ambiguous={ambig} missing={miss}")


if __name__ == "__main__":
    main()
