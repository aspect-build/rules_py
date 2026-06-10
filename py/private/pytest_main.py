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
from typing import List

try:
    import pytest
except ModuleNotFoundError as e:
    print("ERROR: pytest must be included in the deps of the py_pytest_main or py_test target")
    raise e

# None means coverage wasn't enabled
cov = None
# For workaround of https://github.com/nedbat/coveragepy/issues/963
coveragepy_absfile_mapping = {}

# Since our py_test had InstrumentedFilesInfo, we know Bazel will hand us this environment variable.
# https://bazel.build/rules/lib/providers/InstrumentedFilesInfo
if "COVERAGE_MANIFEST" in os.environ:
    try:
        import coverage
        # The lines are files that matched the --instrumentation_filter flag
        with open(os.getenv("COVERAGE_MANIFEST"), "r") as mf:
            manifest_entries = mf.read().splitlines()
            cov = coverage.Coverage(include = manifest_entries)
            # coveragepy incorrectly converts our entries by following symlinks
            # record a mapping of their conversion so we can undo it later in reporting the coverage
            coveragepy_absfile_mapping = {coverage.files.abs_file(mfe): mfe for mfe in manifest_entries}
        cov.start()
    except ModuleNotFoundError as e:
        print("WARNING: python coverage setup failed. Do you need to include the 'coverage' package as a dependency of py_pytest_main?", e)
        pass

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

    junit_xml_out = os.environ.get("XML_OUTPUT_FILE")
    if junit_xml_out is not None:
        args.append(f"--junitxml={junit_xml_out}")

        suite_name = os.environ.get("BAZEL_TARGET")
        if suite_name:
            args.extend(["-o", f"junit_suite_name={suite_name}"])

    test_shard_index = os.environ.get("TEST_SHARD_INDEX")
    test_total_shards = os.environ.get("TEST_TOTAL_SHARDS")
    test_shard_status_file = os.environ.get("TEST_SHARD_STATUS_FILE")
    if (
        all([test_shard_index, test_total_shards, test_shard_status_file])
        and int(test_total_shards) > 1
    ):
        args.extend([
            f"--shard-id={test_shard_index}",
            f"--num-shards={test_total_shards}",
        ])
        Path(test_shard_status_file).touch()
        plugins.append(ShardPlugin())

    test_filter = os.environ.get("TESTBRIDGE_TEST_ONLY")
    if test_filter is not None:
        args.append(f"-k={test_filter}")

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
    target_name = os.environ.get("BAZEL_TARGET_NAME", "")
    target = os.environ.get("BAZEL_TARGET", "")
    if target:
        package = target.split(":")[0].lstrip("/")
        paths_file = os.path.join(package, target_name + ".pytest_paths")
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
        # https://bazel.build/configure/coverage
        coverage_output_file = os.getenv("COVERAGE_OUTPUT_FILE")

        unfixed_dat = coverage_output_file + ".tmp"
        cov.lcov_report(outfile = unfixed_dat)
        cov.save()
        
        with open(unfixed_dat, "r") as unfixed:
          with open(coverage_output_file, "w") as output_file:
            for line in unfixed:
              # Workaround https://github.com/nedbat/coveragepy/issues/963
              # by mapping SF: records to un-do the symlink-following
              if line.startswith('SF:'):
                sourcefile = line[3:].rstrip()
                if sourcefile in coveragepy_absfile_mapping:
                    output_file.write(f"SF:{coveragepy_absfile_mapping[sourcefile]}\n")
                    continue
              # Workaround https://github.com/bazelbuild/bazel/issues/25118
              # by removing 'end line number' from FN: records
              if line.startswith('FN:'):
                parts = line[3:].split(",")  # Remove 'FN:' and split by commas
                if len(parts) == 3:
                  output_file.write(f"FN:{parts[0]},{parts[2]}")
                  continue
              output_file.write(line)
        os.unlink(unfixed_dat)

    sys.exit(exit_code)
