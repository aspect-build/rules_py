"""Round-trip a protobuf message whose Python bindings are produced by
rules_proto_grpc_python.

The generated `greeting_pb2` module is emitted by a rules_python `py_library`
(via `python_proto_library`) and pulls in the protobuf runtime through
`@protobuf//:protobuf_python`. Both expose the upstream `PyInfo` provider. This
test exists to prove aspect_rules_py's venv assembly still collects the
transitive sources/imports of such a target after rules_py stopped importing
`PyInfo` directly from rules_python (#1223) and began consuming its own
re-exported provider seam.
"""

import greeting_pb2


def test_roundtrip():
    original = greeting_pb2.Greeting(name="rules_py", message="hello, world")

    wire = original.SerializeToString()

    parsed = greeting_pb2.Greeting()
    parsed.ParseFromString(wire)

    assert parsed.name == "rules_py", parsed.name
    assert parsed.message == "hello, world", parsed.message


if __name__ == "__main__":
    test_roundtrip()
    print("OK")
