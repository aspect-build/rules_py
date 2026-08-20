#!/usr/bin/env python3
"""Calls a single compiled kernel directly via ctypes.

awkward_IndexedArray64_numnull counts negative ("null") entries in an
IndexedArray's index buffer. fromindex=[0,-1,2,-1,4] has 2 nulls.
"""
import ctypes
from numpy import int64
from awkward_cpp.cpu_kernels import kernel


def main() -> None:
    fromindex = (ctypes.c_int64 * 5)(0, -1, 2, -1, 4)
    numnull = ctypes.c_int64(0)
    func = kernel[("awkward_IndexedArray_numnull", int64, int64)]
    err = func(ctypes.pointer(numnull), fromindex, 5)
    if err.str:
        raise RuntimeError("kernel error: {}".format(err.str))
    assert numnull.value == 2, "expected 2 nulls, got {}".format(numnull.value)
    print("OK")


if __name__ == "__main__":
    main()
