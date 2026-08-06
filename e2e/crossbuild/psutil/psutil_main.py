#!/usr/bin/env python3
import psutil


def main() -> None:
    # cpu_count()/virtual_memory().total read real /proc/cpuinfo and
    # /proc/meminfo via psutil's compiled Linux backend (_psutil_linux.so) —
    # both must be positive on any real (or QEMU-emulated) Linux system.
    cpu_count = psutil.cpu_count()
    assert cpu_count is not None and cpu_count >= 1, "cpu_count() returned {!r}".format(cpu_count)
    mem_total = psutil.virtual_memory().total
    assert mem_total > 0, "virtual_memory().total returned {!r}".format(mem_total)
    print("OK")


if __name__ == "__main__":
    main()
