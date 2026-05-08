import os
import sys

target = os.environ["BAZEL_TARGET_NAME"]

# sys.argv[0] is the script path; the rest come from the launcher's
# `args` attribute (passed via `"$@"` in run.tmpl.sh).
actual = sys.argv[1:]

expected_by_target = {
    "test_args_one": ["alpha"],
    "test_args_many": ["one", "two", "three"],
    "test_args_with_spaces": ["hello world", "another arg"],
    "test_args_empty": [],
    # `args = ["$(rootpath :payload.txt)", "$(SOME_VAR)"]` — verifies
    # `$(location)` / `$(MAKE_VAR)` expansion in the launcher's args.
    "test_expand_args": [
        "py/tests/py-venv-multi-exec/payload.txt",
        "SOME_VALUE",
    ],
}

expected = expected_by_target.get(target)
assert expected is not None, f"unexpected BAZEL_TARGET_NAME: {target}"
assert actual == expected, f"expected argv={expected!r}, got {actual!r}"

print(f"entry_args ok ({target}): {actual!r}")
