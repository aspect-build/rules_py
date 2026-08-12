"""Analysis-test helpers for pep517_native_whl(cc_deps = ...)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//uv/private/pep517_whl:rule.bzl", "ALLOWED_LINK_FLAG_SHAPES", "ALLOWED_Z_KEYWORDS")

# Golden copies of the accepted link-flag shapes and -z keywords. Deliberately
# duplicated: the acceptance assertions in the content test below cover each
# shape and keyword by exemplar, so an entry dropped from a rule.bzl tuple could
# quietly drop its coverage instead of turning a test red. Comparing the
# exported tuples against these copies at load time fails the package (naming
# both copies) the moment they diverge.
_ALLOWED_LINK_FLAG_SHAPES_GOLDEN = (
    ("exact", "-pthread"),
    ("prefix", "-L"),
    ("wl_arg", "-rpath"),
    ("wl_arg", "-rpath-link"),
    ("wl_arg", "--version-script"),
    ("wl_keyword", "-z"),
    ("wl_exact", "--enable-new-dtags"),
)

_ALLOWED_Z_KEYWORDS_GOLDEN = (
    "relro",
    "now",
    "noexecstack",
    "origin",
)

def assert_allowlist_matches_golden():
    """Fail at load if rule.bzl's allowlist drifts from the golden copies here."""
    if tuple(ALLOWED_LINK_FLAG_SHAPES) != _ALLOWED_LINK_FLAG_SHAPES_GOLDEN:
        fail(
            "ALLOWED_LINK_FLAG_SHAPES in rule.bzl no longer matches the golden " +
            "copy in test.bzl. Update both, and the acceptance exemplars below. " +
            "rule.bzl has: {}".format(list(ALLOWED_LINK_FLAG_SHAPES)),
        )
    if tuple(ALLOWED_Z_KEYWORDS) != _ALLOWED_Z_KEYWORDS_GOLDEN:
        fail(
            "ALLOWED_Z_KEYWORDS in rule.bzl no longer matches the golden copy " +
            "in test.bzl. Update both, and the acceptance exemplars below. " +
            "rule.bzl has: {}".format(list(ALLOWED_Z_KEYWORDS)),
        )

# A plain cc_library cannot populate compilation_context.framework_includes on
# Linux (Apple `-F` search paths), so this shim synthesizes a CcInfo carrying
# only framework_includes. It lets the analysis content test pin the `-F`
# emission and marker-anchoring without a macOS toolchain.
def _cc_framework_shim_impl(ctx):
    compilation_context = cc_common.create_compilation_context(
        framework_includes = depset(ctx.attr.framework_includes),
    )
    return [CcInfo(compilation_context = compilation_context)]

cc_framework_shim = rule(
    implementation = _cc_framework_shim_impl,
    attrs = {"framework_includes": attr.string_list()},
)

def _cc_deps_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    build_actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(
        env,
        1,
        len(build_actions),
        "expected exactly one PySdistNativeBuild action",
    )

    action = build_actions[0]
    args = action.argv
    asserts.true(
        env,
        "--cc-deps-info" in args,
        "action should carry --cc-deps-info; got: {}".format(args),
    )

    inputs = action.inputs.to_list()
    info_path = args[args.index("--cc-deps-info") + 1]
    input_paths = [f.path for f in inputs]
    asserts.true(
        env,
        info_path in input_paths,
        "cc-deps-info params file should be an action input",
    )

    # Every header and archive in the merged two-dep closure must reach the
    # action inputs BY NAME, so a mutant that drops one of the three libraries
    # fails rather than passing on the survivors (the previous "some .h / some
    # .a" probes could not tell the closure apart from a single dep).
    input_basenames = [f.basename for f in inputs]
    for header in ("cc_dep.h", "chain_dep.h", "chain_dep2.h"):
        asserts.true(
            env,
            header in input_basenames,
            "cc_deps header {} should be an action input; got {}".format(header, input_basenames),
        )

    # Archives are matched by their lib<name>. prefix (not exact basename) so the
    # toolchain's pic vs non-pic archive choice does not matter; each of the
    # three must be present exactly once.
    for lib in ("libcc_dep.", "libchain_dep.", "libchain_dep2."):
        matches = [b for b in input_basenames if b.startswith(lib) and b.endswith(".a")]
        asserts.equals(
            env,
            1,
            len(matches),
            "expected exactly one {}a archive among inputs; got {}".format(lib, input_basenames),
        )

    return analysistest.end(env)

pep517_native_whl_cc_deps_test = analysistest.make(_cc_deps_test_impl)

def _cc_deps_content_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    build_actions = [a for a in target.actions if a.mnemonic == "PySdistNativeBuild"]
    asserts.equals(
        env,
        1,
        len(build_actions),
        "expected exactly one PySdistNativeBuild action",
    )
    args = build_actions[0].argv
    marker = args[args.index("--execroot-marker") + 1]

    write_actions = [
        a
        for a in target.actions
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename == "cc_deps_info.json"
    ]
    asserts.equals(
        env,
        1,
        len(write_actions),
        "expected exactly one cc_deps_info.json write action",
    )
    info = json.decode(write_actions[0].content)

    # Every include (and Apple framework) search path must be anchored so it
    # survives the backend chdir.
    for flag in info["compile_flags"]:
        for prefix in ("-isystem", "-iquote", "-I", "-F"):
            if flag.startswith(prefix):
                asserts.true(
                    env,
                    flag[len(prefix):].startswith(marker + "/"),
                    "compile flag path should be marker-anchored: {}".format(flag),
                )
                break

    # Positive: the cc_dep(includes = ["."]) source dir must be emitted as a
    # marker-anchored include. Asserting a specific expected entry is PRESENT
    # (not merely that any emitted entry is well-formed) makes a mutant that
    # drops include emission fail rather than pass vacuously. Bazel 8 surfaces
    # cc_library(includes) via system_includes (-isystem); Bazel 9 surfaces the
    # same attribute via includes (-I). Accept either spelling of the same dir.
    expected_system = "-isystem{}/{}".format(marker, ctx.label.package)
    expected_plain = "-I{}/{}".format(marker, ctx.label.package)
    asserts.true(
        env,
        expected_system in info["compile_flags"] or expected_plain in info["compile_flags"],
        "cc_dep(includes=['.']) should emit {} or {}; got {}".format(
            expected_system,
            expected_plain,
            info["compile_flags"],
        ),
    )

    # Positive: chain_dep2's transitive define must reach compile_flags as a bare
    # -D (no marker: defines carry symbols, not paths). Asserting the specific
    # entry makes a mutant that drops -D emission fail rather than pass vacuously.
    asserts.true(
        env,
        "-DCHAIN_BONUS=3" in info["compile_flags"],
        "transitive define should emit -DCHAIN_BONUS=3; got {}".format(info["compile_flags"]),
    )

    # Positive: the framework shim's Apple `-F` search path must be emitted as a
    # marker-anchored -F entry. A plain cc_library cannot produce
    # framework_includes on Linux, so this is the only coverage that the -F
    # emission and anchoring exist; behavioral macOS linking is out of reach on
    # Linux CI.
    expected_framework = "-F{}/vendor/Frameworks".format(marker)
    asserts.true(
        env,
        expected_framework in info["compile_flags"],
        "framework_includes should emit {}; got {}".format(expected_framework, info["compile_flags"]),
    )

    link_objects = info["link_objects"]
    for obj in link_objects:
        asserts.true(
            env,
            obj.startswith(marker + "/"),
            "link object should be marker-anchored: {}".format(obj),
        )

    # The two-level chain must contribute both archives, dependent before
    # dependency (topological order), alongside the second merged dep.
    chain = [i for i, obj in enumerate(link_objects) if obj.split("/")[-1].startswith("libchain_dep.")]
    chain2 = [i for i, obj in enumerate(link_objects) if obj.split("/")[-1].startswith("libchain_dep2.")]
    merged = [i for i, obj in enumerate(link_objects) if obj.split("/")[-1].startswith("libcc_dep.")]
    asserts.equals(env, 1, len(chain), "expected the direct chain archive; got {}".format(link_objects))
    asserts.equals(env, 1, len(chain2), "expected the transitive chain archive; got {}".format(link_objects))
    asserts.equals(env, 1, len(merged), "expected the second dep's archive; got {}".format(link_objects))
    asserts.true(
        env,
        chain[0] < chain2[0],
        "dependent archive should precede its dependency; got {}".format(link_objects),
    )

    asserts.true(
        env,
        "chainfoo" in info["link_libraries"],
        "-lchainfoo should land in link_libraries as a bare name; got {}".format(info["link_libraries"]),
    )

    # A declared additional_linker_inputs path inside a verbatim flag must be
    # marker-anchored, keyed on the file's declared execroot-relative path.
    # Covered in both the comma and the = spelling of --version-script.
    input_paths = [f.path for f in build_actions[0].inputs.to_list()]
    vs_paths = [p for p in input_paths if p.endswith("/vs.lds")]
    asserts.equals(env, 1, len(vs_paths), "version script should be an action input")
    for version_script in (
        "-Wl,--version-script,{}/{}".format(marker, vs_paths[0]),
        "-Wl,--version-script={}/{}".format(marker, vs_paths[0]),
    ):
        asserts.true(
            env,
            version_script in info["link_flags"],
            "declared version-script path should be marker-anchored in link_flags as {}; got {}".format(version_script, info["link_flags"]),
        )

    # Acceptance: one exemplar per allowed link-flag shape and directive form,
    # added to chain_dep's linkopts, must reach link_flags verbatim. The -L and
    # rpath dummy paths are fixture-relative and never linked (this fixture is
    # analysis-only). -pthread is the exact shape; -Lvendor/dummy is the glued
    # prefix; the -Wl, entries cover each argument directive in its comma and =
    # spelling, the reviewed -z keywords, the benign multi-directive compound,
    # and --enable-new-dtags comma-joined after an $ORIGIN rpath.
    link_flags = info["link_flags"]
    for exemplar in (
        "-Lvendor/dummy",
        "-Wl,-rpath,vendor/rpath",
        "-Wl,-rpath=vendor/rpath_eq",
        "-Wl,-rpath-link,vendor/rpath_link",
        "-Wl,-z,now",
        "-Wl,-z,relro,-z,now",
        "-Wl,-z,noexecstack",
        "-Wl,-z,origin",
        "-Wl,-rpath,$ORIGIN,--enable-new-dtags",
        "-pthread",
    ):
        asserts.true(
            env,
            exemplar in link_flags,
            "allowed link flag {} should land verbatim in link_flags; got {}".format(exemplar, link_flags),
        )

    # Relative order among the allowed flags follows linkopts order.
    expected_order = [
        "-Wl,--version-script,{}/{}".format(marker, vs_paths[0]),
        "-Wl,--version-script={}/{}".format(marker, vs_paths[0]),
        "-Lvendor/dummy",
        "-Wl,-rpath,vendor/rpath",
        "-Wl,-rpath=vendor/rpath_eq",
        "-Wl,-rpath-link,vendor/rpath_link",
        "-Wl,-z,now",
        "-Wl,-z,relro,-z,now",
        "-Wl,-z,noexecstack",
        "-Wl,-z,origin",
        "-Wl,-rpath,$ORIGIN,--enable-new-dtags",
        "-pthread",
    ]
    asserts.equals(
        env,
        expected_order,
        [flag for flag in link_flags if flag in expected_order],
        "allowed link flags should appear in linkopts order; got {}".format(link_flags),
    )

    return analysistest.end(env)

pep517_native_whl_cc_deps_content_test = analysistest.make(_cc_deps_content_test_impl)

def _cc_deps_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_message)
    return analysistest.end(env)

pep517_native_whl_cc_deps_failure_test = analysistest.make(
    _cc_deps_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_message": attr.string(mandatory = True)},
)
