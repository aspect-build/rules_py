"""Bytecode for a rules_python-generated proto module comes from rules_py's
deps aspect; rules_python's own runfiles retain the generated source in every
mode. The protobuf runtime is compiled only when it reaches the test through
PyInfo deps (rules_proto_grpc) rather than runfiles alone (py_proto_library).
Files are checked before the import so the interpreter cannot have written
them itself.
"""

import importlib
import os
import sys

mode = os.environ["EXPECT_PYC"]
module = os.environ["MODULE"]
runtime_compiled = os.environ["EXPECT_RUNTIME_PYC"] == "1"
root = os.path.join(
    os.environ["TEST_SRCDIR"], os.environ["TEST_WORKSPACE"], os.environ["MODULE_DIR"]
)
runtime = os.path.join(
    os.environ["TEST_SRCDIR"], "protobuf+", "python", "google", "protobuf"
)
tag = sys.implementation.cache_tag


def layout(directory: str, stem: str) -> tuple[str, str]:
    pycache = os.path.join(directory, "__pycache__", "{}.{}.pyc".format(stem, tag))
    legacy = os.path.join(directory, stem + ".pyc")
    return {"pyc": (pycache, legacy), "pyc_only": (legacy, pycache)}[mode]


expected, unexpected = layout(root, module)
assert os.path.exists(os.path.join(root, module + ".py")), os.listdir(root)
assert os.path.exists(expected), os.listdir(root)
assert not os.path.exists(unexpected), os.listdir(root)

runtime_expected, runtime_unexpected = layout(runtime, "message")
assert os.path.exists(os.path.join(runtime, "message.py")), os.listdir(runtime)
assert os.path.exists(runtime_expected) == runtime_compiled, os.listdir(runtime)
assert not os.path.exists(runtime_unexpected), os.listdir(runtime)

generated = importlib.import_module(module)
descriptor = next(iter(generated.DESCRIPTOR.message_types_by_name.values()))
message_class = getattr(generated, descriptor.name)
message = message_class(**{descriptor.fields[0].name: "pyc"})
assert message_class.FromString(message.SerializeToString()) == message
print("OK")
