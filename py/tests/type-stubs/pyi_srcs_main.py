import os

# `pyi_srcs` is build-time only, so the stub must not sit beside this file in runfiles.
stub = os.path.join(os.path.dirname(__file__), "annotated.pyi")
assert not os.path.exists(stub), "type stub leaked into runfiles: " + stub
