"""py_test consumer of the shared venv.

Asserts that both cowsay and colorama — the wheels carried by the
shared :venv — resolve under this test's interpreter, proving
`external_venv = :venv` on a py_test produces the same sys.path as on
a py_binary pointing at the same venv.

Written as a plain-asserts `main` (not `pytest_main = True`) so the
shared venv's dep list stays minimal — no need to also carry
`pytest_shard` / `default_pytest_main` just to satisfy the
analysis-time subset-coverage check.
"""

import sys


def main():
    import cowsay
    assert callable(cowsay.get_output_string), "cowsay not importable"

    import colorama
    assert isinstance(colorama.Fore.RED, str), "colorama not importable"

    # The interpreter must be the shared venv's, not the host Python.
    # The shared venv target is `:venv`, so its bin/python lives at
    # `.../py/tests/shared-external-venv/.venv/bin/python`.
    assert "/py/tests/shared-external-venv/.venv/bin/python" in sys.executable, sys.executable


if __name__ == "__main__":
    main()
