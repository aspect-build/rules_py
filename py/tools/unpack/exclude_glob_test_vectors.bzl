"""Valid exclusion vectors shared by the installer and repository tests."""

EXCLUDE_GLOB_VECTORS = [
    ("demo/tests/test_root.py", "demo/**/tests/**", True),
    ("demo/nested/tests/test_nested.py", "demo/**/tests/**", True),
    ("demo/nested/not_tests/test_nested.py", "demo/**/tests/**", False),
    ("google/api/annotations.proto", "google/**/*.proto", True),
    ("google/api/annotations_pb2.py", "google/**/*.proto", False),
    ("demo/sdk-core/bin/tool", "demo/sdk-core", True),
    ("demo/data/sample,1.csv", "demo/data/sample,*.csv", True),
    ("demo/data/acb.txt", "demo/data/a*b*c.txt", False),
]

RECORD_PATH_EXCLUDE_VECTORS = [
    ("ns/__pycache__/test_one.cpython-311.pyc", "ns/test_*.py", True),
    ("ns/__pycache__/test_one.cpython-311.opt-1.pyc", "ns/test_*.py", True),
    ("pkg/__pycache__/test_api.v1.cpython-311.pyc", "pkg/test_*.py", True),
    ("pkg/__pycache__/test_api.v1.cpython-311.opt-1.pyc", "pkg/test_*.py", True),
    ("pkg/__pycache__/test_api.v1.cpython-311.opt-é.pyc", "pkg/test_*.py", True),
    ("ns/test_legacy.pyc", "ns/test_*.py", True),
    ("pkg/.pyc", "pkg/.py", True),
    ("pkg/.pyc", "pkg/.pyc.py", False),
    ("ns/__pycache__/keep.cpython-311.pyc", "ns/test_*.py", False),
    ("ns/__pycache__/test_one.cpython-311.opt-!.pyc", "ns/test_*.py", True),
    ("ns/__pycache__/test_one.cpython-311.opt-.pyc", "ns/test_*.py", False),
    ("ns/__pycache__/test_one..pyc", "ns/test_*.py", False),
    ("ns/__pycache__/test_one..opt-1.pyc", "ns/test_*.py", False),
    ("ns/__pycache__/.cpython-311.pyc", "ns/*.py", False),
    ("pkg/__pycache__/..pyc", "pkg/..py", False),
]
