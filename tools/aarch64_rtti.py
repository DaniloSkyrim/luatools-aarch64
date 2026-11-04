#!/usr/bin/env python3
"""Locate Itanium-ABI RTTI type_info objects and vtables in an ELF64 image.

Read-only. Used to prove that the aarch64 Steam client keeps RTTI for the
classes SLSsteam patches, and to dump vtable entries (method RVAs) so hooks
can be resolved by vtable index instead of x86 byte signatures.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import elf_symbols as elf  # noqa: E402


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: aarch64_rtti.py <elf> <ClassName> [index ...]")
    path, cls = sys.argv[1], sys.argv[2]
    want = [int(x, 0) for x in sys.argv[3:]]
    data = open(path, "rb").read()
    secs = elf.sections(data)
    alloc = [s for s in secs if s["type"] in (1, 14) and s["size"] and s["addr"]]

    def vaddr_to_off(addr):
        for s in alloc:
            if s["addr"] <= addr < s["addr"] + s["size"]:
                return s["offset"] + (addr - s["addr"])
        return None

    def read_u64_at_va(addr):
        off = vaddr_to_off(addr)
        if off is None or off + 8 > len(data):
            return None
        return struct.unpack_from("<Q", data, off)[0]

    def dump(addr, n):
        off = vaddr_to_off(addr)
        vals = struct.unpack_from("<%dQ" % n, data, off) if off else ()
        return vals

    # Itanium type name is length-prefixed: "\x0dCSteamEngine".
    needle = bytes([len(cls)]) + cls.encode()
    name_vas = []
    for s in alloc:
        blob = data[s["offset"]:s["offset"] + s["size"]]
        start = 0
        while True:
            i = blob.find(needle, start)
            if i < 0:
                break
            name_vas.append(s["addr"] + i)
            start = i + 1
    print(f"name strings for {cls}: {len(name_vas)}")
    if not name_vas:
        return

    # type_info = { vptr, name* } -> find an 8-byte pointer to the name string
    typeinfos = []
    for s in alloc:
        blob = data[s["offset"]:s["offset"] + s["size"]]
        for i in range(0, len(blob) - 7, 8):
            val = struct.unpack_from("<Q", blob, i)[0]
            if val in name_vas:
                typeinfos.append(s["addr"] + i - 8)
    typeinfos = sorted(set(typeinfos))
    print(f"type_info candidates: {len(typeinfos)}")
    for ti in typeinfos[:10]:
        print(f"  typeinfo @ {ti:#x} name={read_u64_at_va(ti + 8):#x}")

    # vtable[-1] == typeinfo
    found = 0
    for s in alloc:
        blob = data[s["offset"]:s["offset"] + s["size"]]
        for i in range(8, len(blob) - 7, 8):
            val = struct.unpack_from("<Q", blob, i)[0]
            if val in typeinfos:
                vt = s["addr"] + i - 8
                found += 1
                print(f"vtable for {cls} @ {vt:#x} (typeinfo {val:#x})")
                entries = dump(vt, 48)
                for idx, fn in enumerate(entries):
                    if idx == 0:
                        continue
                    if fn == 0:
                        break
                    if not want or (idx - 1) in want or idx <= 12:
                        print(f"    [{idx - 1:3d}] {fn:#x}")
    print(f"vtables found: {found}")


if __name__ == "__main__":
    main()
