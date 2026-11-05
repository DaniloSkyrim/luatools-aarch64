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


def arch_blocks(text):
    """Return the byte ranges of the per-architecture signature tables.

    src/patterns.cpp wraps the tables in `#if SLS_ARCH_ARM64 ... #else ... #endif`,
    so a plain file scan would collect both and report the other architecture's
    signatures as missing. Yields (arch, body) pairs; arch is "aarch64" for the
    #if branch and "x86" for the #else branch.
    """
    lines = text.splitlines(keepends=True)
    start = None
    arch = None
    out = []
    for line in lines:
        stripped = line.strip()
        if start is None and stripped.startswith("#if") and "SLS_ARCH_ARM64" in stripped:
            start = len(line)
            arch = "aarch64"
            body = []
            continue
        if start is not None:
            if stripped.startswith("#else"):
                out.append((arch, "".join(body)))
                arch = "x86"
                body = []
                continue
            if stripped.startswith("#endif"):
                out.append((arch, "".join(body)))
                start = None
                arch = None
                continue
            body.append(line)
    if start is not None:
        out.append((arch, "".join(body)))
    return out


def parse_patterns(path, arch=None):
    text = open(path, encoding="utf-8").read()
    blocks = arch_blocks(text)
    if arch:
        blocks = [b for a, b in blocks if a == arch]
        text = "\n".join(blocks)
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
    arch = None
    argv = sys.argv[1:]
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--arch":
            if i + 1 >= len(argv):
                raise SystemExit("--arch needs a value (aarch64 or x86)")
            arch = argv[i + 1]
            i += 2
            continue
        args.append(argv[i])
        i += 1
    if len(args) < 2:
        raise SystemExit("usage: check_patterns.py <patterns.cpp> <elf> [--arch aarch64|x86]")
    patterns = parse_patterns(args[0], arch)
    data = open(args[1], "rb").read()
    secs = elf.sections(data)
    segs = executable_segments(data, secs)
    print(f"patterns={len(patterns)} arch={arch or 'all'} executable_bytes={sum(len(b) for _, b in segs)}")
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
