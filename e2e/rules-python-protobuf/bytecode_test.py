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


def layout(directory: str, stem: str) -> tuple[list[str], list[str]]:
    """(expected, unexpected) bytecode files. These rules_python libraries keep
    their sources, so pyc_only ships both layouts: CPython reads __pycache__
    beside a present source."""
    pycache = os.path.join(directory, "__pycache__", "{}.{}.pyc".format(stem, tag))
    sourceless = os.path.join(directory, stem + ".pyc")
    return {"pycache": ([pycache], [sourceless]), "sourceless": ([sourceless, pycache], [])}[mode]


expected, unexpected = layout(root, module)
assert os.path.exists(os.path.join(root, module + ".py")), os.listdir(root)
for path in expected:
    assert os.path.exists(path), os.listdir(root)
for path in unexpected:
    assert not os.path.exists(path), os.listdir(root)

runtime_expected, runtime_unexpected = layout(runtime, "message")
assert os.path.exists(os.path.join(runtime, "message.py")), os.listdir(runtime)
for path in runtime_expected:
    assert os.path.exists(path) == runtime_compiled, os.listdir(runtime)
for path in runtime_unexpected:
    assert not os.path.exists(path), os.listdir(runtime)

generated = importlib.import_module(module)
descriptor = next(iter(generated.DESCRIPTOR.message_types_by_name.values()))
message_class = getattr(generated, descriptor.name)
message = message_class(**{descriptor.fields[0].name: "pycache"})
assert message_class.FromString(message.SerializeToString()) == message
print("OK")
