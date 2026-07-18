#!/usr/bin/env python3
# SPDX-License-Identifier: Unlicense
#
# Minimal USBDEVFS_RESET helper for pigeoncam-usb-reset.sh (FR7b, last-resort
# tier). Implemented in Python rather than compiled from the commonly
# circulated usbreset.c: the ioctl number is a well-documented, stable part
# of the Linux USB device filesystem UAPI (linux/usbdevice_fs.h), so no
# external C source needs to be fetched or trusted, and no C toolchain needs
# to become a Tier 1 dependency - python3 is already pulled in transitively
# by `yq` (see lib/pigeoncam-common.sh).
import fcntl
import sys

USBDEVFS_RESET = 0x5514  # _IO('U', 20)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} /dev/bus/usb/BBB/DDD", file=sys.stderr)
        return 2
    node = sys.argv[1]
    try:
        with open(node, "wb") as f:
            fcntl.ioctl(f, USBDEVFS_RESET, 0)
    except OSError as exc:
        print(f"USBDEVFS_RESET failed on {node}: {exc}", file=sys.stderr)
        return 1
    print(f"USBDEVFS_RESET succeeded on {node}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
