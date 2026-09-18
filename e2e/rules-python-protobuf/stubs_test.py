"""protobuf's py_proto_library emits `greeting_pb2.pyi` only through
rules_python's `PyInfo.transitive_pyi_files`; the rules_py venv has to place it
beside `greeting_pb2.py` for type checkers to see the generated message types.
"""

import os

import greeting_pb2

stub = os.path.splitext(greeting_pb2.__file__)[0] + ".pyi"
assert os.path.exists(stub), "missing generated stub next to " + greeting_pb2.__file__

with open(stub) as handle:
    assert "class Greeting" in handle.read(), stub
