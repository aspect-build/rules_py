"""Generated proto modules get bytecode from the deps aspect; the protobuf
runtime only when it arrives through PyInfo deps (rules_proto_grpc), not
runfiles alone (py_proto_library). Files are checked before the import.
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
    sourceless = os.path.join(directory, stem + ".pyc")
    return {"pyc": (pycache, sourceless), "pyc_only": (sourceless, pycache)}[mode]


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
