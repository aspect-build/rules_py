"""Test that py_venv works when both py_proto_library and pip protobuf are deps."""
import unittest


class ProtoVenvTest(unittest.TestCase):
    def test_import_generated_proto(self):
        import empty_pb2
        msg = empty_pb2.EmptyMessage()
        self.assertIsNotNone(msg)

    def test_import_protobuf_runtime(self):
        from google.protobuf import descriptor
        self.assertIsNotNone(descriptor)


if __name__ == "__main__":
    unittest.main()
