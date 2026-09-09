#!/usr/bin/env python3
import numpy as np


def main() -> None:
    # Plain elementwise arithmetic never touches BLAS regardless of build
    # config — a baseline sanity check that the compiled core imported and
    # runs at all.
    a = np.array([1, 2, 3], dtype=np.int64)
    b = np.array([4, 5, 6], dtype=np.int64)
    result = (a + b).tolist()
    assert result == [5, 7, 9], "elementwise add: got {}, expected [5, 7, 9]".format(result)

    # Matrix multiplication normally routes through BLAS (dgemm) when one is
    # linked; built with -Dblas=none, numpy falls back to its own internal
    # gemm loop instead — this specifically exercises that fallback path is
    # numerically correct, not just present.
    m1 = np.array([[1.0, 2.0], [3.0, 4.0]])
    m2 = np.array([[5.0, 6.0], [7.0, 8.0]])
    product = (m1 @ m2).tolist()
    expected = [[19.0, 22.0], [43.0, 50.0]]
    assert product == expected, "matmul (no-BLAS fallback): got {}, expected {}".format(product, expected)

    print("OK")


if __name__ == "__main__":
    main()
