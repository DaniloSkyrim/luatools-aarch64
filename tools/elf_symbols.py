#!/usr/bin/env python3
"""Minimal read-only ELF64 section/symbol inspector.

Used to fingerprint the aarch64 Steam client modules and to check whether
their internal C++ symbols survive stripping. No third-party dependencies.
"""
import struct
import sys


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("not a little-endian ELF64 file")
    e_shoff = u64(data, 0x28)
    e_shentsize = u16(data, 0x3A)
    e_shnum = u16(data, 0x3C)
    e_shstrndx = u16(data, 0x3E)
    raw = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        raw.append({
            "name_off": u32(data, off),
            "type": u32(data, off + 4),
            "flags": u64(data, off + 8),
            "addr": u64(data, off + 16),
            "offset": u64(data, off + 24),
            "size": u64(data, off + 32),
            "link": u32(data, off + 40),
            "info": u32(data, off + 44),
            "align": u64(data, off + 48),
            "entsize": u64(data, off + 56),
        })
    strtab = raw[e_shstrndx]
    names = data[strtab["offset"]:strtab["offset"] + strtab["size"]]
    for s in raw:
        end = names.find(b"\0", s["name_off"])
        s["name"] = names[s["name_off"]:end].decode("utf-8", "replace")
    return raw


def symbols(data, secs):
    symsec = next((s for s in secs if s["name"] == ".symtab"), None)
    if symsec is None:
        return None
    strsec = secs[symsec["link"]]
    strs = data[strsec["offset"]:strsec["offset"] + strsec["size"]]
    count = symsec["size"] // symsec["entsize"]
    out = []
    for i in range(count):
        off = symsec["offset"] + i * symsec["entsize"]
        name_off = u32(data, off)
        info = data[off + 4]
        value = u64(data, off + 8)
        size = u64(data, off + 16)
        end = strs.find(b"\0", name_off)
        name = strs[name_off:end].decode("utf-8", "replace")
        out.append({"name": name, "value": value, "size": size,
                    "bind": info >> 4, "type": info & 0xF})
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: elf_symbols.py <file> [substring ...]")
    path = sys.argv[1]
    needles = sys.argv[2:]
    with open(path, "rb") as fh:
        data = fh.read()
    secs = sections(data)
    print(f"file={path} size={len(data)}")
    print("sections:")
    for s in secs:
        print(f"  {s['name']:<22} type={s['type']:<3} size={s['size']}")
    syms = symbols(data, secs)
    if syms is None:
        print("symtab: ABSENT")
        return
    print(f"symtab: {len(syms)} symbols")
    if needles:
        for n in needles:
            hits = [s for s in syms if n in s["name"]]
            print(f"matches for {n!r}: {len(hits)}")
            for s in hits[:20]:
                print(f"  {s['value']:#x} size={s['size']} {s['name']}")


if __name__ == "__main__":
    main()
