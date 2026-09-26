import sys
from pathlib import Path

with_stubs, without_stubs = (Path(path).read_text().splitlines() for path in sys.argv[1:3])
stub_entry = "    types_requests: types_requests"

assert stub_entry in with_stubs, with_stubs
assert without_stubs == [line for line in with_stubs if line != stub_entry], without_stubs
