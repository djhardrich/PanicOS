#!/usr/bin/env python3
"""Build an Android bootimg (BOOT_IMAGE_HEADER_V0) from kernel + ramdisk.

Usage:
    build-android-bootimg.py --vendor-bootimg <vendor.img> \\
        --kernel <Image> [--ramdisk <ramdisk.cpio.gz>] \\
        --cmdline "<kernel cmdline>" \\
        --out <new-boot.img>

If --vendor-bootimg is given, the script reads the vendor's bootimg
header to inherit the kernel/ramdisk/tags/second base addresses + page
size + (optionally) the kernel itself if --kernel is omitted.

Header format reference:
    https://source.android.com/docs/core/architecture/bootloader/boot-image-header
    Specifically Boot image header v0 (Android < 9 / older AOSP).

This is a focused implementation for the TrimUI Brick / Allwinner A133
flow. Only covers v0 headers (which is what TrimUI's bootimg uses, per
the kernel/ramdisk addrs we read at 0x40080000 / 0x42000000).
"""
import argparse
import os
import struct
import sys


# Android bootimg v0 header (Android pre-9). Fixed at 1648 bytes plus
# padding to the bootimg's page_size.
BOOTIMG_MAGIC = b"ANDROID!"
HEADER_FMT = (
    "<"        # little-endian, no struct alignment
    "8s"       # magic
    "I"        # kernel_size
    "I"        # kernel_addr
    "I"        # ramdisk_size
    "I"        # ramdisk_addr
    "I"        # second_size
    "I"        # second_addr
    "I"        # tags_addr
    "I"        # page_size
    "I"        # header_version (0 for v0)
    "I"        # os_version
    "16s"      # name
    "512s"     # cmdline
    "32s"      # id (SHA-1)
    "1024s"    # extra_cmdline
)
HEADER_SIZE = struct.calcsize(HEADER_FMT)


def parse_vendor_bootimg(path):
    """Read an Android bootimg and return its header fields + payloads."""
    with open(path, "rb") as f:
        raw = f.read()
    if not raw.startswith(BOOTIMG_MAGIC):
        sys.exit(f"error: {path} is not an Android bootimg (missing ANDROID! magic)")
    hdr = struct.unpack_from(HEADER_FMT, raw, 0)
    (magic, kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
     second_size, second_addr, tags_addr, page_size, header_version,
     os_version, name, cmdline, _id, extra_cmdline) = hdr

    if header_version != 0:
        sys.exit(f"error: only bootimg header v0 supported (this is v{header_version})")

    # Layout: header at 0, then kernel, ramdisk, second — each padded
    # up to page_size.
    def aligned(n, p): return (n + p - 1) // p * p

    kernel_off = page_size
    ramdisk_off = kernel_off + aligned(kernel_size, page_size)
    second_off = ramdisk_off + aligned(ramdisk_size, page_size)

    return {
        "header_size": HEADER_SIZE,
        "page_size": page_size,
        "kernel_addr": kernel_addr,
        "ramdisk_addr": ramdisk_addr,
        "second_addr": second_addr,
        "tags_addr": tags_addr,
        "os_version": os_version,
        "name": name.rstrip(b"\x00"),
        "cmdline": cmdline.rstrip(b"\x00"),
        "extra_cmdline": extra_cmdline.rstrip(b"\x00"),
        "kernel": raw[kernel_off:kernel_off + kernel_size],
        "ramdisk": raw[ramdisk_off:ramdisk_off + ramdisk_size],
        "second": raw[second_off:second_off + second_size],
    }


def build_bootimg(vendor_meta, kernel_bytes, ramdisk_bytes, cmdline, out_path):
    """Pack a v0 bootimg with the given kernel + ramdisk + cmdline."""
    page_size = vendor_meta["page_size"]

    full_cmdline = cmdline.encode("utf-8")
    if len(full_cmdline) > 512 + 1024:
        sys.exit("error: cmdline too long (>1536 bytes)")
    main_cmdline = full_cmdline[:512]
    extra_cmdline = full_cmdline[512:]

    header = struct.pack(
        HEADER_FMT,
        BOOTIMG_MAGIC,
        len(kernel_bytes),
        vendor_meta["kernel_addr"],
        len(ramdisk_bytes),
        vendor_meta["ramdisk_addr"],
        0,                            # second_size (none)
        vendor_meta["second_addr"],
        vendor_meta["tags_addr"],
        page_size,
        0,                            # header_version
        vendor_meta["os_version"],
        vendor_meta["name"][:16].ljust(16, b"\x00"),
        main_cmdline.ljust(512, b"\x00"),
        b"\x00" * 32,                 # id (SHA-1; bootloader doesn't verify)
        extra_cmdline.ljust(1024, b"\x00"),
    )

    def pad_to_page(data):
        rem = len(data) % page_size
        if rem == 0:
            return b""
        return b"\x00" * (page_size - rem)

    with open(out_path, "wb") as f:
        f.write(header)
        f.write(b"\x00" * (page_size - HEADER_SIZE))
        f.write(kernel_bytes)
        f.write(pad_to_page(kernel_bytes))
        f.write(ramdisk_bytes)
        f.write(pad_to_page(ramdisk_bytes))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vendor-bootimg", required=True,
                    help="Vendor bootimg to inherit kernel/ramdisk/tags addrs from")
    ap.add_argument("--kernel",
                    help="Kernel binary to pack (default: vendor's kernel)")
    ap.add_argument("--ramdisk",
                    help="Ramdisk to pack (default: vendor's ramdisk; specify ours to override)")
    ap.add_argument("--cmdline", default="",
                    help="Kernel cmdline (default: empty)")
    ap.add_argument("--out", required=True,
                    help="Output bootimg path")
    args = ap.parse_args()

    vendor = parse_vendor_bootimg(args.vendor_bootimg)

    if args.kernel:
        with open(args.kernel, "rb") as f:
            kernel_bytes = f.read()
    else:
        kernel_bytes = vendor["kernel"]

    if args.ramdisk:
        with open(args.ramdisk, "rb") as f:
            ramdisk_bytes = f.read()
    else:
        ramdisk_bytes = vendor["ramdisk"]

    build_bootimg(vendor, kernel_bytes, ramdisk_bytes, args.cmdline, args.out)
    print(f">>> wrote {args.out} "
          f"(kernel={len(kernel_bytes)} ramdisk={len(ramdisk_bytes)} "
          f"cmdline={args.cmdline!r})")


if __name__ == "__main__":
    main()
