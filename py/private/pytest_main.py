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
from pathlib import Path
from typing import List, Optional

try:
    import pytest
except ModuleNotFoundError as e:
    print("ERROR: pytest must be included in the deps of the py_pytest_main or py_test target")
    raise e


class _BazelTestEnv:
    """Consolidated accessor for environment variables injected by Bazel test runner.

    See https://bazel.build/reference/test-encyclopedia#initial-conditions
    """

    def __init__(self):
        self.coverage_manifest = os.environ.get("COVERAGE_MANIFEST")
        self.coverage_output_file = os.environ.get("COVERAGE_OUTPUT_FILE")
        self.xml_output_file = os.environ.get("XML_OUTPUT_FILE")
        self.test_shard_index = os.environ.get("TEST_SHARD_INDEX")
        self.test_total_shards = os.environ.get("TEST_TOTAL_SHARDS")
        self.test_shard_status_file = os.environ.get("TEST_SHARD_STATUS_FILE")
        self.test_filter = os.environ.get("TESTBRIDGE_TEST_ONLY")
        self.bazel_target = os.environ.get("BAZEL_TARGET", "")
        self.bazel_target_name = os.environ.get("BAZEL_TARGET_NAME", "")

    def is_sharded(self) -> bool:
        if not all([self.test_shard_index, self.test_total_shards, self.test_shard_status_file]):
            return False
        try:
            return int(self.test_total_shards) > 1
        except ValueError:
            return False


# None means coverage wasn't enabled
cov = None
# Mapping to undo coveragepy symlink-following behavior.
# TODO: Validate whether this workaround is still required with coveragepy >= 7.x.
# The underlying issue (https://github.com/nedbat/coveragepy/issues/963) may have
# been resolved; if so, this mapping and the post-processing loop below can be removed.
# See also: https://github.com/bazelbuild/bazel/issues/25118 for the FN: record fix.
coveragepy_absfile_mapping = {}

# Since our py_test provides InstrumentedFilesInfo, Bazel sets COVERAGE_MANIFEST.
# https://bazel.build/rules/lib/providers/InstrumentedFilesInfo
_bazel_env = _BazelTestEnv()
if _bazel_env.coverage_manifest:
    try:
        import coverage
        with open(_bazel_env.coverage_manifest, "r") as mf:
            manifest_entries = mf.read().splitlines()
            cov = coverage.Coverage(include=manifest_entries)
            # coveragepy may follow symlinks when resolving absolute paths,
            # causing mismatches with Bazel's manifest. Record a reverse mapping
            # so we can restore the original paths in the LCOV output.
            coveragepy_absfile_mapping = {
                coverage.files.abs_file(mfe): mfe for mfe in manifest_entries
            }
        cov.start()
    except ModuleNotFoundError as e:
        print(
            "WARNING: python coverage setup failed. "
            "Do you need to include the 'coverage' package as a dependency of py_pytest_main?",
            e,
        )

from pytest_shard import ShardPlugin

if __name__ == "__main__":
    # This statement will be replaced if the user provides a chdir path
    _ = 0  # no-op

    os.environ["ENV"] = "testing"

    plugins = []
    args = [
        "--verbose",
        # Avoid loading of the plugin "cacheprovider".
        "-p",
        "no:cacheprovider",
    ]

    # Ignore the legacy external/ symlink tree that Bazel may create
    # in WORKSPACE mode or as a compat shim under bzlmod.
    if os.path.isdir("external"):
        args.extend(["--ignore", "external"])

    if _bazel_env.xml_output_file is not None:
        args.append(f"--junitxml={_bazel_env.xml_output_file}")
        if _bazel_env.bazel_target:
            args.extend(["-o", f"junit_suite_name={_bazel_env.bazel_target}"])

    if _bazel_env.is_sharded():
        args.extend([
            f"--shard-id={_bazel_env.test_shard_index}",
            f"--num-shards={_bazel_env.test_total_shards}",
        ])
        Path(_bazel_env.test_shard_status_file).touch()
        plugins.append(ShardPlugin())

    if _bazel_env.test_filter is not None:
        args.append(f"-k={_bazel_env.test_filter}")

    # This list will be replaced if the user provides args to bake in
    user_args: List[str] = []
    if len(user_args) > 0:
        args.extend(user_args)

    cli_args = sys.argv[1:]
    if len(cli_args) > 0:
        args.extend(cli_args)

    # Read the pytest paths args file written by the pytest_paths rule.
    # Contains directories (one per line) where pytest should search for tests,
    # relative to the workspace root (which is CWD at test time).  When present,
    # these are passed as positional args so pytest collects only from those
    # directories instead of autodiscovering from CWD.
    if _bazel_env.bazel_target:
        package = _bazel_env.bazel_target.split(":")[0].lstrip("/")
        paths_file = os.path.join(package, _bazel_env.bazel_target_name + ".pytest_paths")
        if os.path.isfile(paths_file):
            with open(paths_file) as f:
                for line in f:
                    d = line.strip()
                    if not d:
                        continue
                    if os.path.isdir(d):
                        args.append(d)

    exit_code = pytest.main(args, plugins=plugins)

    if exit_code != 0:
        print("Pytest exit code: " + str(exit_code), file=sys.stderr)
        print("Ran pytest.main with " + str(args), file=sys.stderr)
    elif cov:
        cov.stop()
        coverage_output_file = _bazel_env.coverage_output_file
        if coverage_output_file:
            unfixed_dat = coverage_output_file + ".tmp"
            cov.lcov_report(outfile=unfixed_dat)
            cov.save()

            with open(unfixed_dat, "r") as unfixed:
                with open(coverage_output_file, "w") as output_file:
                    for line in unfixed:
                        # Workaround https://github.com/nedbat/coveragepy/issues/963
                        # by mapping SF: records to un-do the symlink-following
                        if line.startswith("SF:"):
                            sourcefile = line[3:].rstrip()
                            if sourcefile in coveragepy_absfile_mapping:
                                output_file.write(f"SF:{coveragepy_absfile_mapping[sourcefile]}\n")
                                continue
                        # Workaround https://github.com/bazelbuild/bazel/issues/25118
                        # by removing 'end line number' from FN: records
                        if line.startswith("FN:"):
                            parts = line[3:].split(",")  # Remove 'FN:' and split by commas
                            if len(parts) == 3:
                                output_file.write(f"FN:{parts[0]},{parts[2]}")
                                continue
                        output_file.write(line)
            os.unlink(unfixed_dat)

    sys.exit(exit_code)
