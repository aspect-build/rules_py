"""Smoke test that cowsay built from sdist via a forced-native build works.

cowsay is pure Python; the `native = true` annotation forces its sdist to
build under `pep517_native_whl` (see the snapshot in e2e/BUILD.bazel for
the structural assertion). Importing and exercising cowsay verifies that
the forced-native pathway still produces an installable wheel.
"""

import cowsay

output = cowsay.get_output_string("cow", "native annotation works!")
assert "native annotation works!" in output
print("cowsay imported from forced-native sdist build: OK")
