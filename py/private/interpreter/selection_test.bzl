"""Tests for exact PBS cohort selection."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":selection.bzl", "build_toolchain_plan", "find_asset", "parse_sha256sums")

_SHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
_RELEASE_OLD = "20260101"
_RELEASE_NEW = "20260202"
_LINUX = "x86_64-unknown-linux-gnu"
_WINDOWS = "x86_64-pc-windows-msvc"

_PLATFORMS = {
    _LINUX: {
        "compatible_with": ["linux", "x86_64"],
        "register_exec_tools": True,
        "target_settings": {"libc": "glibc"},
    },
    _WINDOWS: {
        "compatible_with": ["windows", "x86_64"],
        "register_exec_tools": True,
    },
}
_BUILD_CONFIGS = {
    "install_only": {
        "freethreaded": False,
        "strip_prefix": "python",
    },
}
_SETTINGS = {
    "config_settings": [],
    "exec_compatible_with": [],
    "target_compatible_with": [],
}

def _asset(filename):
    return {"filename": filename, "sha256": _SHA}

def _indices(include_old_linux = True):
    old = {
        "3.15/{}/install_only".format(_WINDOWS): {
            "3.15.0a1": _asset("windows-a1"),
        },
    }
    if include_old_linux:
        old["3.15/{}/install_only".format(_LINUX)] = {
            "3.15.0a1": _asset("linux-a1"),
        }
    return {
        _RELEASE_NEW: {
            "3.15/{}/install_only".format(_LINUX): {
                "3.15.0a2": _asset("linux-a2"),
            },
        },
        _RELEASE_OLD: old,
    }

def _plan(include_old_linux = True):
    return build_toolchain_plan(
        major_minor = "3.15",
        release_dates = [_RELEASE_NEW, _RELEASE_OLD],
        release_indices = _indices(include_old_linux),
        platforms = _PLATFORMS,
        build_configs = _BUILD_CONFIGS,
        allow_pre_release = True,
        settings = _SETTINGS,
    )

def _exact_cohort_selection_test_impl(ctx):
    env = unittest.begin(ctx)
    plan = _plan()
    targets = {entry["platform"]: entry for entry in plan["targets"]}
    asserts.equals(env, 2, len(targets), "both target assets remain registered")
    repositories = {entry["name"]: entry for entry in plan["repositories"]}

    execs = {
        (entry["target_platforms"][0], entry["compatible_with"][0]): entry
        for entry in plan["execs"]
    }
    linux_target_linux_exec = execs[(_LINUX, "linux")]
    windows_target_linux_exec = execs[(_WINDOWS, "linux")]
    asserts.equals(env, "3.15.0a2", repositories[linux_target_linux_exec["repo"]]["full_version"], "Linux target uses a2")
    asserts.equals(env, "3.15.0a1", repositories[windows_target_linux_exec["repo"]]["full_version"], "Windows target pairs with Linux a1")
    asserts.true(env, "cohort_20260101_3_15_0a1" in windows_target_linux_exec["repo"], "older companion repository is cohort-qualified")
    return unittest.end(env)

exact_cohort_selection_test = unittest.make(_exact_cohort_selection_test_impl)

def _release_index_retains_versions_test_impl(ctx):
    env = unittest.begin(ctx)
    suffix = "{}-install_only.tar.gz".format(_LINUX)
    index = parse_sha256sums("\n".join([
        "{} cpython-3.15.0a1+{}-{}".format(_SHA, _RELEASE_OLD, suffix),
        "{} cpython-3.15.0a2+{}-{}".format(_SHA, _RELEASE_OLD, suffix),
    ]), _RELEASE_OLD)
    versions = index["3.15/{}/install_only".format(_LINUX)]
    asserts.equals(env, ["3.15.0a1", "3.15.0a2"], sorted(versions.keys()), "release index retains every full version")
    selected = find_asset("3.15", _LINUX, "install_only", [_RELEASE_OLD], {_RELEASE_OLD: index})
    asserts.equals(env, "3.15.0a2", selected["full_version"], "normal selection still chooses the newest full version")
    return unittest.end(env)

release_index_retains_versions_test = unittest.make(_release_index_retains_versions_test_impl)

def _missing_companion_test_impl(ctx):
    env = unittest.begin(ctx)
    plan = _plan(include_old_linux = False)
    asserts.equals(env, 2, len(plan["targets"]), "missing exec companion does not remove target assets")
    windows_cohort_execs = [
        entry
        for entry in plan["execs"]
        if entry["target_platforms"] == [_WINDOWS]
    ]
    asserts.equals(env, 1, len(windows_cohort_execs), "only the missing Linux pairing is omitted")
    asserts.equals(env, ["windows", "x86_64"], windows_cohort_execs[0]["compatible_with"])
    return unittest.end(env)

missing_companion_test = unittest.make(_missing_companion_test_impl)

def _cohort_executor_cardinality_test_impl(ctx):
    env = unittest.begin(ctx)
    indices = _indices()
    indices[_RELEASE_OLD]["3.15/{}/install_only".format(_LINUX)]["3.15.0a2"] = _asset("linux-old-a2")
    indices[_RELEASE_OLD]["3.15/{}/install_only".format(_WINDOWS)]["3.15.0a2"] = _asset("windows-old-a2")
    plan = build_toolchain_plan(
        major_minor = "3.15",
        release_dates = [_RELEASE_OLD],
        release_indices = indices,
        platforms = _PLATFORMS,
        build_configs = _BUILD_CONFIGS,
        allow_pre_release = True,
        settings = _SETTINGS,
    )
    asserts.equals(env, 2, len(plan["targets"]), "two target platforms share one cohort")
    asserts.equals(env, 2, len(plan["execs"]), "one cohort emits one entry per executor, not per target")
    for entry in plan["execs"]:
        asserts.equals(env, [_LINUX, _WINDOWS], entry["target_platforms"], "cohort groups both target platforms")
    return unittest.end(env)

cohort_executor_cardinality_test = unittest.make(_cohort_executor_cardinality_test_impl)

def _release_date_distinguishes_cohorts_test_impl(ctx):
    env = unittest.begin(ctx)
    indices = {
        _RELEASE_NEW: {
            "3.15/{}/install_only".format(_LINUX): {
                "3.15.0a1": _asset("linux-new-a1"),
            },
        },
        _RELEASE_OLD: {
            "3.15/{}/install_only".format(_LINUX): {
                "3.15.0a1": _asset("linux-old-a1"),
            },
            "3.15/{}/install_only".format(_WINDOWS): {
                "3.15.0a1": _asset("windows-old-a1"),
            },
        },
    }
    plan = build_toolchain_plan(
        major_minor = "3.15",
        release_dates = [_RELEASE_NEW, _RELEASE_OLD],
        release_indices = indices,
        platforms = _PLATFORMS,
        build_configs = _BUILD_CONFIGS,
        allow_pre_release = True,
        settings = _SETTINGS,
    )
    repositories = {entry["name"]: entry for entry in plan["repositories"]}
    linux_companions = [
        entry
        for entry in plan["execs"]
        if entry["compatible_with"][0] == "linux"
    ]
    linux_target = [entry for entry in linux_companions if entry["target_platforms"] == [_LINUX]]
    windows_target = [entry for entry in linux_companions if entry["target_platforms"] == [_WINDOWS]]
    asserts.equals(env, 1, len(linux_target))
    asserts.equals(env, 1, len(windows_target))
    asserts.equals(env, _RELEASE_NEW, repositories[linux_target[0]["repo"]]["release_date"])
    asserts.equals(env, _RELEASE_OLD, repositories[windows_target[0]["repo"]]["release_date"])
    asserts.true(
        env,
        linux_target[0]["cohort"] != windows_target[0]["cohort"],
        "equal versions from different releases remain separate",
    )
    return unittest.end(env)

release_date_distinguishes_cohorts_test = unittest.make(_release_date_distinguishes_cohorts_test_impl)

def _build_config_distinguishes_cohorts_test_impl(ctx):
    env = unittest.begin(ctx)
    build_configs = {
        "install_only": {
            "freethreaded": False,
            "strip_prefix": "python",
        },
        "freethreaded": {
            "freethreaded": True,
            "strip_prefix": "python/install",
        },
    }
    plan = build_toolchain_plan(
        major_minor = "3.15",
        release_dates = [_RELEASE_OLD],
        release_indices = {
            _RELEASE_OLD: {
                "3.15/{}/install_only".format(_LINUX): {
                    "3.15.0a1": _asset("linux-install-only"),
                },
                "3.15/{}/freethreaded".format(_LINUX): {
                    "3.15.0a1": _asset("linux-freethreaded"),
                },
            },
        },
        platforms = {_LINUX: _PLATFORMS[_LINUX]},
        build_configs = build_configs,
        allow_pre_release = True,
        settings = _SETTINGS,
    )
    asserts.equals(env, 2, len(plan["targets"]))
    asserts.equals(env, 2, len(plan["execs"]))
    asserts.equals(env, 2, len({entry["cohort"]: True for entry in plan["execs"]}), "build configurations remain separate cohorts")
    asserts.equals(env, ["freethreaded", "install_only"], sorted([entry["build_config"] for entry in plan["repositories"]]))
    return unittest.end(env)

build_config_distinguishes_cohorts_test = unittest.make(_build_config_distinguishes_cohorts_test_impl)

def selection_test_suite():
    unittest.suite(
        "selection_tests",
        build_config_distinguishes_cohorts_test,
        exact_cohort_selection_test,
        release_index_retains_versions_test,
        release_date_distinguishes_cohorts_test,
        missing_companion_test,
        cohort_executor_cardinality_test,
    )
