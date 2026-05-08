import os

target = os.environ["BAZEL_TARGET_NAME"]

# Each consumer sets its own `data = [...]` and forwards the file's
# runfile path via env. The launcher's `data` attr is independent of
# the venv — different consumers can ship different runfiles while
# sharing the same venv.
EXPECTATIONS = {
    "test_data_alpha": "alpha-payload\n",
    "test_data_beta":  "beta-payload\n",
}

expected = EXPECTATIONS.get(target)
assert expected is not None, f"unexpected BAZEL_TARGET_NAME: {target}"

# DATA_PATH is set per-target via `$(rootpath :data_*.txt)`; the cwd
# at test time is the runfiles root, so a relative open() resolves it.
data_path = os.environ["DATA_PATH"]
content = open(data_path).read()
assert content == expected, f"expected {expected!r}, got {content!r}"

print(f"entry_data ok ({target}): {data_path}")
