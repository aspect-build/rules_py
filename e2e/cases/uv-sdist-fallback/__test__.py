"""Smoke test that cowsay built from sdist (via no-binary-package) works.

cowsay 6.0 ships both an sdist and a `-none-any.whl`. With `no-binary-package
= ["cowsay"]` the resolver must produce a `sdist_build__*` repo so the
package can be built from source. Importing and exercising cowsay verifies
the sdist build pathway end-to-end.
"""

import cowsay

output = cowsay.get_output_string("cow", "sdist fallback works!")
assert "sdist fallback works!" in output
print("cowsay imported from sdist: OK")
