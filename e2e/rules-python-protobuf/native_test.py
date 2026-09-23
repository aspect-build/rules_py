"""Round-trip a message whose bindings come from protobuf's native
py_proto_library: a srcs-less rules_python target that only forwards the
generated module through PyInfo."""

from native_greeting_pb2 import NativeGreeting

greeting = NativeGreeting(recipient="rules_py", times=2)
assert NativeGreeting.FromString(greeting.SerializeToString()) == greeting
print("OK")
