"""A shim for executing pytest that supports test filtering, sharding, and more.

Copied from https://github.com/caseyduquettesc/rules_python_pytest/blob/331e0e511130cf4859b7589a479db6c553974abf/python_pytest/pytest_shim.py
"""

import sys
import os

import pytest


if __name__ == "__main__":
    pytest_args = ["--ignore=external"]

    args = sys.argv[1:]
    # pytest < 8.0 runs tests twice if __init__.py is passed explicitly as an argument.
    # Remove any __init__.py file to avoid that.
    # pytest.version_tuple is available since pytest 7.0
    # https://github.com/pytest-dev/pytest/issues/9313
    if not hasattr(pytest, "version_tuple") or pytest.version_tuple < (8, 0):
        args = [arg for arg in args if arg.startswith("-") or os.path.basename(arg) != "__init__.py"]

    if os.environ.get("XML_OUTPUT_FILE"):
        pytest_args.append("--junitxml={xml_output_file}".format(xml_output_file=os.environ.get("XML_OUTPUT_FILE")))

    # Handle test sharding - requires pytest-shard plugin.
    if os.environ.get("TEST_SHARD_INDEX") and os.environ.get("TEST_TOTAL_SHARDS"):
        pytest_args.append("--shard-id={shard_id}".format(shard_id=os.environ.get("TEST_SHARD_INDEX")))
        pytest_args.append("--num-shards={num_shards}".format(num_shards=os.environ.get("TEST_TOTAL_SHARDS")))
        if os.environ.get("TEST_SHARD_STATUS_FILE"):
            open(os.environ["TEST_SHARD_STATUS_FILE"], "a").close()

    # Handle plugins that generate reports - if they are provided with relative paths (via args),
    # re-write it under bazel's test undeclared outputs dir.
    if os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR"):
        undeclared_output_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")

        # Flags that take file paths as value.
        path_flags = [
            "--report-log",  # pytest-reportlog
            "--json-report-file",  # pytest-json-report
            "--html",  # pytest-html
        ]
        for i, arg in enumerate(args):
            for flag in path_flags:
                if arg.startswith(f"{flag}="):
                    arg_split = arg.split("=", 1)
                    if len(arg_split) == 2 and not os.path.isabs(arg_split[1]):
                        args[i] = f"{flag}={undeclared_output_dir}/{arg_split[1]}"

    if os.environ.get("TESTBRIDGE_TEST_ONLY"):
        test_filter = os.environ["TESTBRIDGE_TEST_ONLY"]

        # If the test filter does not start with a class-like name, then use test filtering instead
        if not test_filter[0].isupper():
            # --test_filter=test_module.test_fn or --test_filter=test_module/test_file.py
            pytest_args.extend(args)
            pytest_args.append("-k={filter}".format(filter=test_filter))
        else:
            # --test_filter=TestClass.test_fn
            for arg in args:
                if not arg.startswith("--"):
                    # arg is a src file. Add test class/method selection to it.
                    # test.py::TestClass::test_fn
                    arg = "{arg}::{module_fn}".format(arg=arg, module_fn=test_filter.replace(".", "::"))
                pytest_args.append(arg)
    else:
        pytest_args.extend(args)

    print(pytest_args, file=sys.stderr)
    raise SystemExit(pytest.main(pytest_args))
