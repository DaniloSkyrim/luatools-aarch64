import struct
import sys

# usage: mkelf.py <out> <machine> [etype]
# Writes a 64-byte ELF64 header, which is all the installer inspects (magic,
# e_machine, e_type). machine: 0xB7 aarch64, 0x3E x86-64, 0x03 i386.
path = sys.argv[1]
machine = int(sys.argv[2], 0)
etype = int(sys.argv[3]) if len(sys.argv) > 3 else 3

hdr = bytearray(64)
hdr[0:4] = b"\x7fELF"
hdr[4] = 2   # ELFCLASS64
hdr[5] = 1   # ELFDATA2LSB
hdr[6] = 1   # EV_CURRENT
struct.pack_into("<H", hdr, 16, etype)
struct.pack_into("<H", hdr, 18, machine)
struct.pack_into("<I", hdr, 20, 1)

with open(path, "wb") as fh:
    fh.write(bytes(hdr))
