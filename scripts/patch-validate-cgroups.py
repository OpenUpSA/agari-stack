#!/usr/bin/env python3
"""Neutralise k3s' cgroup-v2 validation by patching validateCgroupsV2() to `return nil`.

Why: k3s' `cgroups.Validate()` (pkg/cgroups/cgroups_linux.go) hard-requires the
`cpu`, `cpuset` and `memory` controllers in the cgroup namespace root. An
unprivileged (rootless) user cannot get `cpuset` delegated, because the root cgroup's
`cgroup.subtree_control` does not (and, without root, cannot) list cpuset. That makes
container-based Kubernetes (k3d/kind) impossible on such a host.

This shim rewrites the first bytes of
github.com/k3s-io/k3s/pkg/cgroups.validateCgroupsV2 to `xor eax,eax; ret` (return
nil). Everything else is untouched, in particular kubelet's own cgroup checks, which
do pass inside a private cgroup namespace whose root only offers
cpu/io/memory/pids.

Function lookup uses the Go pclntab function table (names, entries and funcoff base
are read from .gopclntab), so the patch is precise in a ~200 MB static binary and is
independent of where the code and data ended up.

Usage: patch-k3s-validate-cgroups.py <k3s-binary> <output-binary>
"""

import bisect
import struct
import sys


def load_segments(blob):
    e_phoff = struct.unpack_from("<Q", blob, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", blob, 0x36)[0]
    e_phnum = struct.unpack_from("<H", blob, 0x38)[0]
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        (p_type,) = struct.unpack_from("<I", blob, off)
        p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from("<QQQQ", blob, off + 8)
        if p_type == 1:  # PT_LOAD
            segs.append((p_vaddr, p_offset, p_filesz))
    return segs


def va_to_off(segs, va):
    for vaddr, offset, filesz in segs:
        if vaddr <= va < vaddr + filesz:
            return offset + (va - vaddr)
    return None


def section_by_name(blob, want):
    e_shoff = struct.unpack_from("<Q", blob, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", blob, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", blob, 0x3C)[0]
    strtab_off = None
    raw = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, _flags, addr, offset, size = struct.unpack_from("<IIQQQQ", blob, off)
        raw.append((name, typ, addr, offset, size))
        if typ == 3:
            strtab_off = offset
    for name, _typ, addr, offset, size in raw:
        end = blob.index(b"\x00", strtab_off + name)
        if blob[strtab_off + name : end].decode() == want:
            return addr, offset, size
    raise SystemExit(f"section {want} not found")


def parse_function_table(blob):
    """Return (entry_va_of, function_names) built from the Go pclntab."""
    _addr, offset, _size = section_by_name(blob, ".gopclntab")
    magic = struct.unpack_from("<I", blob, offset)[0]
    if magic != 0xFFFFFFF1:
        raise SystemExit(f"unsupported gopclntab magic {magic:#x} (not a Go 1.18+ binary)")
    nfunc = struct.unpack_from("<Q", blob, offset + 8)[0]
    text_start = struct.unpack_from("<Q", blob, offset + 24)[0]
    funcname_offset = struct.unpack_from("<Q", blob, offset + 32)[0]
    pcln_offset = struct.unpack_from("<Q", blob, offset + 64)[0]

    functab = offset + pcln_offset
    entries = []
    func_offsets = []
    for i in range(nfunc):
        entry_off, func_off = struct.unpack_from("<II", blob, functab + i * 8)
        entries.append(entry_off)
        func_offsets.append(func_off)
    if func_offsets != sorted(func_offsets):
        raise SystemExit("unexpected functab layout: funcoff is not ordered")

    name_table = offset + funcname_offset

    def func_name(i):
        start = functab + func_offsets[i] + 4  # _func.nameOff
        name_off = struct.unpack_from("<i", blob, start)[0]
        start = name_table + name_off
        return blob[start : blob.index(b"\x00", start)].decode()

    return text_start, entries, func_offsets, func_name


def main(src, dst):
    blob = bytearray(open(src, "rb").read())
    segs = load_segments(blob)
    text_start, entries, func_offsets, func_name = parse_function_table(blob)
    functab = None

    matches = []
    for i in range(len(entries)):
        if func_name(i).endswith("cgroups.validateCgroupsV2"):
            matches.append(i)
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one validateCgroupsV2 symbol, found {len(matches)}")

    i = matches[0]
    name = func_name(i)
    va = text_start + entries[i]
    off = va_to_off(segs, va)
    if off is None:
        raise SystemExit("cannot map function virtual address to a file offset")
    nextindex = bisect.bisect_right(entries, entries[i])
    print(f"patching {name}")
    print(f"  entry va=0x{va:x} file offset=0x{off:x}")
    if nextindex < len(entries):
        print(f"  next function: {func_name(nextindex)}")
    print(f"  before: {blob[off:off + 8].hex(' ')}")
    blob[off : off + 3] = b"\x31\xc0\xc3"  # xor eax, eax; ret  -> return nil
    print(f"  after : {blob[off:off + 8].hex(' ')}")
    with open(dst, "wb") as fh:
        fh.write(blob)
    print(f"wrote {dst}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
