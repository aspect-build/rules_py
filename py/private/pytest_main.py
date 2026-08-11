# -*- mode: python -*-
# Copyright 2022 Aspect Build Systems, Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import sys
import os
from typing import List

import aspect_rules_py_launcher_env as launcher_env

launcher_env.set_test_tmpdir()

try:
    import pytest
except ModuleNotFoundError as e:
    print("ERROR: pytest must be included in the deps of the py_pytest_main or py_test target")
    raise e

cov = launcher_env.start_coverage()

from pytest_shard import ShardPlugin

def main() -> int:
    # Resolve the explicit test files from the .pytest_paths file written by the
    # pytest_paths rule before any chdir: the file and the paths it lists are
    # relative to the runfiles root, which is CWD at startup. Passing the files
    # (not their directory) scopes collection to this target's own srcs — a
    # workspace-root source would otherwise leave pytest to recurse the whole
    # runfiles tree.
    test_paths: List[str] = []
    target_name = os.environ.get("BAZEL_TARGET_NAME", "")
    target = os.environ.get("BAZEL_TARGET", "")
    if target:
        package = target.split(":")[0].lstrip("/")
        paths_file = os.path.join(package, target_name + ".pytest_paths")
        if os.path.isfile(paths_file):
            with open(paths_file) as f:
                for line in f:
                    p = line.strip()
                    if p and os.path.exists(p):
                        test_paths.append(os.path.abspath(p))

    # This statement will be replaced if the user provides a chdir path
    _ = 0  # no-op

    os.environ["ENV"] = "testing"

    plugins: List[ShardPlugin] = []
    args: List[str] = [
        "--verbose",
        # Avoid loading of the plugin "cacheprovider".
        "-p",
        "no:cacheprovider",
    ]

    # Ignore the legacy external/ symlink tree that Bazel may create
    # in WORKSPACE mode or as a compat shim under bzlmod.
    if os.path.isdir("external"):
        args.extend(["--ignore", "external"])

    junit_xml_out = os.environ.get("XML_OUTPUT_FILE")
    if junit_xml_out is not None:
        args.append(f"--junitxml={junit_xml_out}")

        suite_name = os.environ.get("BAZEL_TARGET")
        if suite_name:
            args.extend(["-o", f"junit_suite_name={suite_name}"])

    shard = launcher_env.shard_info()
    if shard is not None:
        shard_index, total_shards = shard
        args.extend([
            f"--shard-id={shard_index}",
            f"--num-shards={total_shards}",
        ])
        launcher_env.advertise_sharding()
        plugins.append(ShardPlugin())

    test_filter = os.environ.get("TESTBRIDGE_TEST_ONLY")
    if test_filter is not None:
        args.append(f"-k={test_filter}")

    # Opt-in from py_pytest_test(consider_namespace_packages = True). Gated here
    # rather than baked into the args by the macro, because only the driver can see
    # the pytest a target actually resolved: the ini option arrived in pytest 8.1,
    # and older pytest treats an unknown -o key as a warning -- or an error under
    # --strict-config -- which would leave an opted-in target silently keeping the
    # truncated module names it opted out of.
    if os.environ.get("RULES_PY_CONSIDER_NAMESPACE_PACKAGES") == "1":
        if getattr(pytest, "version_tuple", (0,)) >= (8, 1):
            args.extend(["-o", "consider_namespace_packages=true"])
        else:
            print(
                "WARNING: consider_namespace_packages requires pytest >= 8.1; this target "
                f"resolved pytest {getattr(pytest, '__version__', 'unknown')}. Test modules "
                "keep their truncated names.",
                file=sys.stderr,
            )

    # This list will be replaced if the user provides args to bake in
    user_args: List[str] = []
    if len(user_args) > 0:
        args.extend(user_args)

    cli_args = sys.argv[1:]
    if len(cli_args) > 0:
        args.extend(cli_args)

    # Pass the test files as positional args so pytest collects only this
    # target's own srcs instead of autodiscovering from CWD. Absolute so they
    # stay valid even if the user baked in a chdir.
    args.extend(test_paths)

    exit_code = pytest.main(args, plugins=plugins)

    if exit_code != 0:
        print("Pytest exit code: " + str(exit_code), file=sys.stderr)
        print("Ran pytest.main with " + str(args), file=sys.stderr)
    elif cov:
        launcher_env.write_lcov(cov)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
