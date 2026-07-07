load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":dep_groups.bzl", "resolve_dependency_group_specs")

def _flat_group_test_impl(ctx):
    env = unittest.begin(ctx)
    groups = {"dev": ["pytest", "ruff==0.1.0"]}
    asserts.equals(env, ["pytest", "ruff==0.1.0"], resolve_dependency_group_specs(groups, "dev"))
    asserts.equals(env, [], resolve_dependency_group_specs({"empty": []}, "empty"))
    return unittest.end(env)

flat_group_test = unittest.make(_flat_group_test_impl)

def _include_group_test_impl(ctx):
    env = unittest.begin(ctx)

    # Includes expand in place, preserving spec order.
    groups = {
        "lint": ["ruff"],
        "dev": ["pytest", {"include-group": "lint"}, "mypy"],
    }
    asserts.equals(
        env,
        ["pytest", "ruff", "mypy"],
        resolve_dependency_group_specs(groups, "dev"),
    )
    return unittest.end(env)

include_group_test = unittest.make(_include_group_test_impl)

def _nested_include_test_impl(ctx):
    env = unittest.begin(ctx)
    groups = {
        "leaf": ["a", "b"],
        "mid": [{"include-group": "leaf"}, "c"],
        "top": ["d", {"include-group": "mid"}],
    }
    asserts.equals(
        env,
        ["d", "a", "b", "c"],
        resolve_dependency_group_specs(groups, "top"),
    )
    return unittest.end(env)

nested_include_test = unittest.make(_nested_include_test_impl)

def dep_groups_test_suite():
    unittest.suite(
        "dep_groups_tests",
        flat_group_test,
        include_group_test,
        nested_include_test,
    )
