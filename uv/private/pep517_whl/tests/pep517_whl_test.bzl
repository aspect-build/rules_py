"""Analysis tests: pep517_native_whl forwards toolchain make-variables
into the PySdistNativeBuild action env.

Inspecting the action at analysis time avoids actually running a PEP 517
build to verify the env wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:cc_toolchain_config_lib.bzl", "env_entry", "env_set", "feature")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//uv/private:source_built_wheel.bzl", "SourceBuiltWheelInfo")
load("//uv/private/pep517_whl:cc_layer.bzl", "cc_layer_test_util")
load("//uv/private/pep517_whl:pep517_native_whl.bzl", "cross_detection_test_util", "cross_identity_test_util")

_ACTION_ENV = "//command_line_option:action_env"
_HOST_ENV = [
    "PYTHONHOME=/host/home",
    "PYTHONPATH=/host/path",
    "PYTHONPLATLIBDIR=host-lib",
    "PYTHONSAFEPATH=1",
    "RUNFILES_MANIFEST_ONLY=1",
]

def _hostile_env_transition_impl(settings, _attr):
    names = {entry.split("=", 1)[0]: True for entry in _HOST_ENV}
    action_env = [
        entry
        for entry in settings[_ACTION_ENV]
        if entry.split("=", 1)[0].upper() not in names
    ]
    return {_ACTION_ENV: action_env + _HOST_ENV}

_hostile_env_transition = transition(
    implementation = _hostile_env_transition_impl,
    inputs = [_ACTION_ENV],
    outputs = [_ACTION_ENV],
)

def _hostile_python_env_target_impl(ctx):
    return [DefaultInfo(files = ctx.attr.target[0][DefaultInfo].files)]

hostile_python_env_target = rule(
    implementation = _hostile_python_env_target_impl,
    attrs = {
        "target": attr.label(
            cfg = _hostile_env_transition,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

# Env vars selected from the configured C++ action tools. SYSROOT is omitted
# because some toolchains legitimately have an empty sysroot.
_CC_ENV_KEYS = ["CC", "CXX", "AR", "LD", "STRIP"]

# Env vars sourced from the Java runtime toolchain's TemplateVariableInfo.
_JDK_ENV_KEYS = ["JAVA_HOME", "JAVA"]

_REQUIRED_ENV_KEYS = _CC_ENV_KEYS + _JDK_ENV_KEYS

def _toolchain_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    build_actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(
        env,
        1,
        len(build_actions),
        "expected exactly one PySdistNativeBuild action",
    )

    action_env = build_actions[0].env
    missing = [k for k in _REQUIRED_ENV_KEYS if k not in action_env]
    asserts.equals(
        env,
        [],
        missing,
        "missing env keys on action; got: {}".format(sorted(action_env.keys())),
    )
    for key in _REQUIRED_ENV_KEYS:
        asserts.true(
            env,
            action_env.get(key),
            "${} should resolve to a non-empty toolchain path".format(key),
        )

    args = build_actions[0].argv
    marker_index = args.index("--execroot-marker")
    marker = args[marker_index + 1]
    asserts.equals(env, "-I{}/relative/include".format(marker), action_env.get("CPPFLAGS"))
    asserts.equals(env, "{}/relative/libdep.a".format(marker), action_env.get("LDFLAGS"))

    action_inputs = [f.path for f in build_actions[0].inputs.to_list()]
    for key in _CC_ENV_KEYS:
        asserts.true(
            env,
            action_env.get(key) in action_inputs,
            "{} should select a declared C++ action tool".format(key),
        )

    return analysistest.end(env)

pep517_native_whl_toolchain_env_test = analysistest.make(_toolchain_env_test_impl)

def _console_scripts_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, SourceBuiltWheelInfo in target, "source-built wheel metadata is absent")
    asserts.equals(
        env,
        tuple(ctx.attr.expected_console_scripts),
        target[SourceBuiltWheelInfo].console_scripts,
    )
    return analysistest.end(env)

pep517_whl_console_scripts_test = analysistest.make(
    _console_scripts_test_impl,
    attrs = {"expected_console_scripts": attr.string_list()},
)

def _execroot_collision_toolchain_impl(_ctx):
    return [platform_common.TemplateVariableInfo({"EXECROOT": "collision"})]

execroot_collision_toolchain = rule(implementation = _execroot_collision_toolchain_impl)

def _execroot_collision_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "exports the reserved `EXECROOT` make-variable")
    return analysistest.end(env)

pep517_native_whl_execroot_collision_test = analysistest.make(
    _execroot_collision_test_impl,
    expect_failure = True,
)

def _fake_runtime(short_path):
    return struct(interpreter = struct(short_path = short_path))

def _interpreter_platform_triple_test_impl(ctx):
    env = unittest.begin(ctx)
    triple = cross_detection_test_util.interpreter_platform_triple
    asserts.equals(
        env,
        "aarch64-apple-darwin",
        triple(_fake_runtime("../python_3_12_aarch64-apple-darwin/python")),
    )
    asserts.equals(
        env,
        "x86_64-unknown-linux-gnu",
        triple(_fake_runtime("../python_3_13_x86_64_unknown_linux_gnu/bin/python3")),
    )
    asserts.equals(
        env,
        "aarch64-apple-darwin",
        triple(_fake_runtime("../rules_python++python+python_3_11_aarch64-apple-darwin/bin/python3")),
    )
    asserts.equals(env, None, triple(_fake_runtime("tools/python/bin/python3")))
    asserts.equals(env, None, triple(_fake_runtime("../custom_interpreter/bin/python")))
    asserts.equals(env, None, triple(None))
    asserts.equals(env, None, triple(struct(interpreter = None)))
    return unittest.end(env)

interpreter_platform_triple_test = unittest.make(_interpreter_platform_triple_test_impl)

def _cross_decision_test_impl(ctx):
    env = unittest.begin(ctx)
    decision = cross_detection_test_util.cross_decision
    linux = "x86_64-unknown-linux-gnu"
    darwin = "aarch64-apple-darwin"

    # Matching triples prove native, even without the sentinel registered.
    asserts.false(env, decision(linux, linux, False))

    # Differing triples prove cross, even when a sentinel resolved.
    asserts.true(env, decision(darwin, linux, True))

    # Unrecognizable identities fall back to the sentinel.
    asserts.false(env, decision(None, linux, True))
    asserts.true(env, decision(None, linux, False))
    asserts.true(env, decision(darwin, None, False))
    asserts.false(env, decision(None, None, True))
    return unittest.end(env)

cross_decision_test = unittest.make(_cross_decision_test_impl)

def _cross_mode_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(env, 1, len(actions), "expected the cross build action to analyze")
    if actions:
        action = actions[0]
        argv = action.argv
        asserts.true(env, "--cross" in argv, "cross mode must reach the helper")
        for flag, value in (("--target-os", "linux"), ("--target-cpu", "aarch64")):
            asserts.true(
                env,
                flag in argv and argv[argv.index(flag) + 1] == value,
                "expected {} {} in argv; got: {}".format(flag, value, list(argv)),
            )
        asserts.equals(
            env,
            "linux-aarch64",
            action.env.get("_PYTHON_HOST_PLATFORM"),
            "the target's python platform identity must reach the backend",
        )
        asserts.true(
            env,
            action.env.get("CFLAGS"),
            "the target CC toolchain's compile flags must reach the backend",
        )
        asserts.true(
            env,
            action.env.get("RULES_PY_TARGET_INCLUDE"),
            "the target interpreter's include dir must reach the backend",
        )
        input_basenames = [f.basename for f in action.inputs.to_list()]
        asserts.true(
            env,
            "pyconfig.h" in input_basenames,
            "the target interpreter's headers must be action inputs — the " +
            "compile must not fall back to the exec runtime's pyconfig.h",
        )
    return analysistest.end(env)

# Runs against the repo's own dev llvm toolchain, which can target
# linux-aarch64 from any host; the wheel-producing end-to-end version lives
# in e2e/crossbuild/pycross-setuptools.
pep517_native_whl_cross_mode_test = analysistest.make(
    _cross_mode_test_impl,
    config_settings = {
        "//command_line_option:platforms": [Label("//uv/private/pep517_whl/tests:cross_target_platform")],
    },
)

def _python_host_platform_test_impl(ctx):
    env = unittest.begin(ctx)
    derive = cross_identity_test_util.derive_python_host_platform
    for target_os, target_cpu, expected in (
        ("linux", "x86_64", "linux-x86_64"),
        ("linux", "aarch64", "linux-aarch64"),
        ("linux", "x86", "linux-i686"),
        ("linux", "arm", "linux-armv7l"),
        ("darwin", "aarch64", "macosx-11.0-arm64"),
        ("darwin", "x86_64", "macosx-11.0-x86_64"),
        ("windows", "x86_64", None),
        (None, None, None),
    ):
        asserts.equals(env, expected, derive(target_os, target_cpu))
    return unittest.end(env)

python_host_platform_test = unittest.make(_python_host_platform_test_impl)

def _fake_runtime_file(p):
    return struct(basename = p.split("/")[-1], dirname = p.rsplit("/", 1)[0], path = p)

def _target_python_artifacts_test_impl(ctx):
    env = unittest.begin(ctx)
    collect = cross_identity_test_util.target_python_artifacts
    runtime = struct(
        interpreter_version_info = struct(major = 3, minor = 12),
        files = depset([
            _fake_runtime_file("repo/lib/python3.12/_sysconfigdata__linux_aarch64-linux-gnu.py"),
            _fake_runtime_file("repo/lib/python3.12/os.py"),
            _fake_runtime_file("repo/include/python3.12/Python.h"),
            _fake_runtime_file("repo/include/python3.12/pyconfig.h"),
            _fake_runtime_file("repo/bin/python3"),
        ]),
    )
    artifacts = collect(runtime)
    asserts.equals(
        env,
        "repo/lib/python3.12/_sysconfigdata__linux_aarch64-linux-gnu.py",
        artifacts.sysconfig.path,
    )
    asserts.equals(env, "repo/include/python3.12", artifacts.include_dir)
    asserts.equals(env, 2, len(artifacts.include_files))

    empty = collect(None)
    asserts.equals(env, None, empty.sysconfig)
    asserts.equals(env, None, empty.include_dir)
    return unittest.end(env)

target_python_artifacts_test = unittest.make(_target_python_artifacts_test_impl)

def _absolutize_flag_test_impl(ctx):
    env = unittest.begin(ctx)
    absolutize = cc_layer_test_util.absolutize_flag
    marker = cc_layer_test_util.execroot_marker
    for flag, expected in (
        # Bare relative paths get the execroot marker; bare absolute paths
        # and pathless arguments pass through.
        ("external/llvm/lib/crt1.o", marker + "/external/llvm/lib/crt1.o"),
        ("/usr/lib/crt1.o", "/usr/lib/crt1.o"),
        ("-lm", "-lm"),
        ("", ""),
        # Path-flag prefixes: relative values marked, absolute untouched.
        ("-Iexternal/llvm/include", "-I" + marker + "/external/llvm/include"),
        ("-I/usr/include", "-I/usr/include"),
        ("-Bexternal/llvm/bin", "-B" + marker + "/external/llvm/bin"),
        # "--sysroot=" is deliberately not cc_layer's job: build_helper's
        # _absolutize_sysroot_flags rewrites it at execution time (it also
        # handles values the backend re-splices after the chdir).
        ("--sysroot=external/llvm/sysroot", "--sysroot=external/llvm/sysroot"),
        ("-O2", "-O2"),
    ):
        asserts.equals(env, expected, absolutize(flag))
    return unittest.end(env)

absolutize_flag_test = unittest.make(_absolutize_flag_test_impl)

def _derived_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    build_actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(env, 1, len(build_actions), "expected exactly one PySdistNativeBuild action")
    if not build_actions:
        return analysistest.end(env)
    action_env = build_actions[0].env
    for key in ctx.attr.derived_keys:
        asserts.true(
            env,
            action_env.get(key),
            "{} must be derived from the listed toolchain's make-variables; env keys: {}".format(key, sorted(action_env.keys())),
        )
    for key, value in ctx.attr.expected_env.items():
        asserts.equals(env, value, action_env.get(key), "explicit env must win over the derived value for " + key)
    for key in ctx.attr.absent_keys:
        asserts.false(env, key in action_env, "{} must not leak into the action env".format(key))
    return analysistest.end(env)

pep517_native_whl_derived_env_test = analysistest.make(
    _derived_env_test_impl,
    attrs = {
        "derived_keys": attr.string_list(doc = "Env keys that must be present and non-empty without an explicit `env` entry."),
        "expected_env": attr.string_dict(doc = "Env entries that must hold exactly these (explicit) values."),
        "absent_keys": attr.string_list(doc = "Env keys that must not appear (make-variable names are not env keys)."),
    },
)

def _config_settings_args_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = [a for a in target.actions if a.mnemonic in ("PySdistBuild", "PySdistNativeBuild")]
    asserts.equals(env, 1, len(actions), "expected exactly one wheel build action")
    if actions:
        argv = list(actions[0].argv)
        expected = ctx.attr.expected
        if not expected:
            asserts.false(env, "--config-setting" in argv, "no config_settings must mean no --config-setting; got: {}".format(argv))
        else:
            found = [argv[i:i + len(expected)] == expected for i in range(len(argv) - len(expected) + 1)]
            asserts.true(
                env,
                any(found),
                "expected the contiguous flags {} (keys sorted, values in declared order); got: {}".format(expected, argv),
            )
    return analysistest.end(env)

config_settings_args_test = analysistest.make(
    _config_settings_args_test_impl,
    attrs = {
        "expected": attr.string_list(
            doc = "Exact `--config-setting key=value` flag sequence the helper must receive; empty asserts absence.",
        ),
    },
)

def _absolutize_msvc_entries_test_impl(ctx):
    env = unittest.begin(ctx)
    absolutize = cc_layer_test_util.absolutize_msvc_entries
    marker = cc_layer_test_util.execroot_marker
    for value, expected in (
        # Relative entries get the execroot marker; drive-letter, rooted and
        # UNC entries and empty segments pass through.
        ("external\\msvc\\bin", marker + "\\external\\msvc\\bin"),
        ("C:\\Windows\\System32", "C:\\Windows\\System32"),
        ("\\\\server\\share", "\\\\server\\share"),
        ("/abs/include", "/abs/include"),
        ("a\\b;C:\\c;d", marker + "\\a\\b;C:\\c;" + marker + "\\d"),
        ("a;;b", marker + "\\a;;" + marker + "\\b"),
        ("", ""),
    ):
        asserts.equals(env, expected, absolutize(value))
    return unittest.end(env)

absolutize_msvc_entries_test = unittest.make(_absolutize_msvc_entries_test_impl)

def _msvc_toolchain_config_impl(ctx):
    def env_feature(name, action, key, value):
        return feature(
            name = name,
            enabled = True,
            env_sets = [env_set(actions = [action], env_entries = [env_entry(key, value)])],
        )

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "msvc-stub",
        host_system_name = "local",
        target_system_name = "local",
        target_cpu = "x64_windows",
        target_libc = "msvcrt",
        compiler = "msvc-cl",
        abi_version = "local",
        abi_libc_version = "local",
        cxx_builtin_include_directories = [],
        features = [
            env_feature("stub_path", ACTION_NAMES.c_compile, "PATH", "msvc_stub\\bin;msvc_stub\\tools"),
            env_feature("stub_include", ACTION_NAMES.c_compile, "INCLUDE", "msvc_stub\\include;msvc_stub\\sdk\\include"),
            env_feature("stub_lib", ACTION_NAMES.cpp_link_dynamic_library, "LIB", "msvc_stub\\lib;msvc_stub\\sdk\\lib"),
        ],
    )

msvc_toolchain_config = rule(
    implementation = _msvc_toolchain_config_impl,
    provides = [CcToolchainConfigInfo],
)

_MSVC_ENV_MARKER = cc_layer_test_util.execroot_marker + "\\"

def _msvc_entries(action, name):
    return action.env.get(name, "").split(";")

def _msvc_runs_cl_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(env, 1, len(actions), "expected one PySdistNativeBuild action")
    if actions:
        action = actions[0]
        asserts.true(env, "--msvc" in action.argv, "missing --msvc: %s" % action.argv)
        asserts.false(env, "--cross" in action.argv, "native build ran in cross mode")
        for name in ["CC", "CXX", "AR", "LD", "STRIP", "CFLAGS", "LDSHAREDFLAGS"]:
            asserts.false(env, name in action.env, name + " is set for cl.exe")
        for name in ["PATH", "INCLUDE", "LIB"]:
            entries = _msvc_entries(action, name)
            asserts.true(env, len(entries) > (1 if name == "PATH" else 2), name + " lacks the toolchain entries")
            for entry in entries:
                asserts.true(env, entry.startswith(_MSVC_ENV_MARKER), "%s entry without the execroot marker: %s" % (name, entry))
            asserts.true(env, "msvc_stub\\" in entries[0], name + " does not start with the toolchain: " + entries[0])
        asserts.true(env, _msvc_entries(action, "INCLUDE")[-1].endswith("\\include"), "INCLUDE lacks the interpreter include dir")
        asserts.true(env, _msvc_entries(action, "LIB")[-1].endswith("\\libs"), "LIB lacks the interpreter libs dir")
        inputs = [f.path for f in action.inputs.to_list()]
        asserts.true(env, any([p.endswith("libs/python312.lib") for p in inputs]), "python312.lib is not an input")
        asserts.true(env, any([p.endswith("include/pyconfig.h") for p in inputs]), "pyconfig.h is not an input")
    return analysistest.end(env)

def _msvc_cross_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "MSVC sdist builds need a Windows execution platform matching the target")
    return analysistest.end(env)

_MSVC_WINDOWS_X64 = [Label("//uv/private/pep517_whl/tests:msvc_windows_x64")]
_MSVC_SETTINGS = {
    "//command_line_option:platforms": _MSVC_WINDOWS_X64,
    "//command_line_option:extra_toolchains": [
        Label("//uv/private/pep517_whl/tests:msvc_cc_toolchain"),
        Label("//uv/private/pep517_whl/tests:msvc_python_toolchain"),
        Label("//uv/private/pep517_whl/tests:msvc_native_build_toolchain"),
    ],
}

# A Windows executor lets the build run natively: the action drives cl.exe.
pep517_native_whl_msvc_test = analysistest.make(
    _msvc_runs_cl_test_impl,
    config_settings = _MSVC_SETTINGS | {"//command_line_option:extra_execution_platforms": _MSVC_WINDOWS_X64},
)

# With only the Linux executor the same target is a cross build, which MSVC
# does not support.
pep517_native_whl_msvc_linux_exec_test = analysistest.make(
    _msvc_cross_fails_test_impl,
    expect_failure = True,
    config_settings = _MSVC_SETTINGS,
)
