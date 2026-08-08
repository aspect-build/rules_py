"""Smoke tests for resolve_wheel_collisions.

Validates the extraction from the former venv.bzl monolith didn't alter
behaviour: single-wheel, namespace-merge, and console-script-collision
code paths produce the expected output shapes.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//py/private/py_venv:virtuals_resolvers.bzl", "resolve_wheel_collisions")

def _mock_ctx(label):
    return struct(label = label)

def _make_wheel(
        site_packages_rfpath,
        metadata_top_levels = [],
        tl_claims = [],
        cs_claims = [],
        regular_roots = [],
        namespace_dirs = [],
        native_roots = [],
        ns_entries = [],
        top_levels = [],
        data_files = [],
        install_tree = None):
    return struct(
        site_packages_rfpath = site_packages_rfpath,
        metadata_top_levels = metadata_top_levels,
        tl_claims = tl_claims,
        cs_claims = cs_claims,
        regular_roots = regular_roots,
        namespace_dirs = namespace_dirs,
        native_roots = native_roots,
        ns_entries = ns_entries,
        top_levels = top_levels,
        data_files = data_files,
        install_tree = install_tree,
    )

def _claim(site_packages, is_ns = False, is_dir = False, is_native = False, ns_entries = []):
    return struct(
        site_packages = site_packages,
        is_ns = is_ns,
        is_dir = is_dir,
        is_native = is_native,
        ns_entries = ns_entries,
    )

def _cs_claim(site_packages, module, func):
    return struct(
        site_packages = site_packages,
        module = module,
        func = func,
    )

def _single_wheel_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    wheels = [
        _make_wheel(
            site_packages_rfpath = "external/pypi_foo/site-packages",
            metadata_top_levels = ["foo"],
            tl_claims = [("foo", _claim("external/pypi_foo/site-packages", is_dir = True))],
            cs_claims = [("foo-cli", _cs_claim("external/pypi_foo/site-packages", "foo.cli", "main"))],
            top_levels = ["foo"],
        ),
    ]
    top_level, fully_covered, cs_map, merge_groups, _data_files, _collisions = resolve_wheel_collisions(
        mock_ctx,
        wheels,
    )
    asserts.equals(env, "external/pypi_foo/site-packages", top_level["foo"])
    asserts.true(env, "external/pypi_foo/site-packages" in fully_covered)
    asserts.equals(env, "foo.cli", cs_map["foo-cli"].module)
    asserts.equals(env, "main", cs_map["foo-cli"].func)
    asserts.equals(env, 0, len(merge_groups))
    return unittest.end(env)

def _namespace_merge_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            metadata_top_levels = ["ns"],
            tl_claims = [("ns", _claim(sp_a, is_ns = True, ns_entries = ["ns/sub_a"]))],
            cs_claims = [],
            ns_entries = ["ns/sub_a"],
            namespace_dirs = ["ns"],
            top_levels = ["ns"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            metadata_top_levels = ["ns"],
            tl_claims = [("ns", _claim(sp_b, is_ns = True, ns_entries = ["ns/sub_b"]))],
            cs_claims = [],
            ns_entries = ["ns/sub_b"],
            namespace_dirs = ["ns"],
            top_levels = ["ns"],
        ),
    ]
    top_level, fully_covered, cs_map, merge_groups, _data_files, _collisions = resolve_wheel_collisions(
        mock_ctx,
        wheels,
    )
    asserts.equals(env, sp_a, top_level["ns/sub_a"])
    asserts.equals(env, sp_b, top_level["ns/sub_b"])
    asserts.equals(env, 0, len(merge_groups))
    return unittest.end(env)

def _console_script_collision_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            metadata_top_levels = [],
            tl_claims = [],
            cs_claims = [("tool", _cs_claim(sp_a, "pkg_a.cli", "main"))],
            top_levels = [],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            metadata_top_levels = [],
            tl_claims = [],
            cs_claims = [("tool", _cs_claim(sp_b, "pkg_b.cli", "main"))],
            top_levels = [],
        ),
    ]
    _, _, cs_map, _, _, _ = resolve_wheel_collisions(
        mock_ctx,
        wheels,
    )
    asserts.equals(env, "pkg_b.cli", cs_map["tool"].module)
    return unittest.end(env)

def _regular_collision_keeps_fallback_test_impl(ctx):
    """A non-namespace collision loser still keeps its whole-wheel fallback.

    Projecting the winner ahead of the loser is not enough to make the loser
    unreachable: a winner whose `__init__.py` calls `pkgutil.extend_path`
    grafts same-named directories found on sys.path onto `__path__`, and no
    wheel metadata distinguishes such a package from a plain one. Suppressing
    the loser here silently drops those contributions -- see
    //py/tests/py_venv_conflict:extend_path_regular_collision_test for the
    runtime failure it causes.
    """
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            tl_claims = [
                ("mod.py", _claim(sp_a)),
                ("only_a", _claim(sp_a, is_dir = True)),
            ],
            top_levels = ["mod.py", "only_a"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            tl_claims = [("mod.py", _claim(sp_b))],
            top_levels = ["mod.py"],
        ),
    ]
    top_level, fully_covered, _, _, _, _ = resolve_wheel_collisions(mock_ctx, wheels)

    # Last distinct claimant wins the contested name.
    asserts.equals(env, sp_b, top_level["mod.py"])

    # The loser keeps its uncontested top-level projected...
    asserts.equals(env, sp_a, top_level["only_a"])

    # ...but stays on the `.pth` fallback, so an extend_path winner can still
    # graft from it. The uncontested winner needs no fallback.
    asserts.false(env, sp_a in fully_covered, "collision loser must keep its fallback")
    asserts.true(env, sp_b in fully_covered)
    return unittest.end(env)

def _entryless_namespace_keeps_fallback_test_impl(ctx):
    """An entryless PEP 420 namespace still needs both wheels on `.pth`.

    Neither claimant declares `ns_entries`, so there is nothing to project
    per-entry and the namespace can only union by having both wheel roots on
    sys.path.
    """
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            tl_claims = [("ns", _claim(sp_a, is_ns = True, is_dir = True))],
            namespace_dirs = ["ns"],
            top_levels = ["ns"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            tl_claims = [("ns", _claim(sp_b, is_ns = True, is_dir = True))],
            namespace_dirs = ["ns"],
            top_levels = ["ns"],
        ),
    ]
    _, fully_covered, _, _, _, _ = resolve_wheel_collisions(mock_ctx, wheels)

    asserts.false(env, sp_a in fully_covered, "entryless namespace must keep its fallback")
    asserts.false(env, sp_b in fully_covered, "entryless namespace must keep its fallback")
    return unittest.end(env)

def _data_file_collision_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            data_files = ["share/common.txt", "share/only_a.txt"],
            top_levels = ["pkg_a"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            data_files = ["share/common.txt", "share/only_b.txt"],
            top_levels = ["pkg_b"],
        ),
    ]
    _, _, _, _, data_files, _collisions = resolve_wheel_collisions(
        mock_ctx,
        wheels,
    )

    # Disjoint files map to their own wheel; the shared path resolves to the
    # last distinct claimant; the shared path collides exactly once.
    asserts.equals(env, sp_a, data_files["share/only_a.txt"])
    asserts.equals(env, sp_b, data_files["share/only_b.txt"])
    asserts.equals(env, sp_b, data_files["share/common.txt"])
    asserts.equals(env, 1, len(_collisions))
    asserts.equals(env, "data file", _collisions[0].what)
    asserts.equals(env, "share/common.txt", _collisions[0].name)
    return unittest.end(env)

def _data_file_reserved_path_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp,
            cs_claims = [("acli", _cs_claim(sp, "a.cli", "main"))],
            data_files = [
                "bin/python",
                "bin/python3",
                "bin/activate",
                "pyvenv.cfg",
                "bin/acli",
                "lib/python3.12/site-packages/pkg_a/asset.txt",
                "lib/libextra.so",
                "bin",
                "bin/python/nested.txt",
                "share/keep.txt",
            ],
            top_levels = ["pkg_a"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            data_files = ["bin/acli"],
            top_levels = ["pkg_b"],
        ),
    ]
    _, _, _, _, data_files, collisions = resolve_wheel_collisions(mock_ctx, wheels)

    # Every venv-owned root is dropped whether it matches a declared output
    # exactly, nests under one, or contains one; each drop is reported so
    # `package_collisions` governs whether it is fatal. The lone survivor is
    # this wheel's alone, so it projects as the whole `share` directory.
    asserts.equals(env, {"share": sp}, data_files)
    asserts.equals(env, 9, len(collisions))

    # A drop reads as a drop, not as "provided by both X and the virtual
    # environment" — the venv declares no output at `bin/acli`, it owns `bin`
    # outright. Both claimants are named: there is no winner to single out.
    asserts.equals(
        env,
        ("data file `bin/acli` from {}, {} is not projected: the virtual " +
         "environment owns `bin` in the prefix.").format(sp, sp_b),
        [c.message for c in collisions if c.name == "bin/acli"][0],
    )
    return unittest.end(env)

def _data_file_nesting_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(site_packages_rfpath = sp_a, data_files = ["share/thing"], top_levels = ["pkg_a"]),
        _make_wheel(
            site_packages_rfpath = sp_b,
            data_files = ["share/thing/nested.txt", "share/other.txt"],
            top_levels = ["pkg_b"],
        ),
    ]
    _, _, _, _, data_files, collisions = resolve_wheel_collisions(mock_ctx, wheels)

    # One wheel's file is another's directory: keep the shallower claim, the
    # deeper one would nest an output inside a declared symlink.
    asserts.equals(env, sp_a, data_files["share/thing"])
    asserts.equals(env, sp_b, data_files["share/other.txt"])
    asserts.false(env, "share/thing/nested.txt" in data_files)
    asserts.equals(env, 1, len(collisions))
    asserts.equals(env, "share/thing/nested.txt", collisions[0].name)
    asserts.equals(
        env,
        ("data file `share/thing/nested.txt` from {} is not projected: it nests under " +
         "data file `share/thing` from {}, which the prefix binds first.").format(sp_b, sp_a),
        collisions[0].message,
    )
    return unittest.end(env)

def _data_file_collapse_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            data_files = [
                "share/jupyter/labext/a.js",
                "share/jupyter/labext/b.js",
                "share/jupyter/labext/static/c.js",
                "etc/cfg/x.json",
                "toplevel.txt",
            ],
            top_levels = ["pkg_a"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            data_files = ["share/jupyter/nbext/d.js"],
            top_levels = ["pkg_b"],
        ),
    ]
    _, _, _, _, data_files, collisions = resolve_wheel_collisions(mock_ctx, wheels)

    # Six files become four projections. `share/` and `share/jupyter/` are
    # shared, so resolution descends through them; below that each directory has
    # a single owner and binds whole. `etc` collapses from its root, not from
    # `etc/cfg`. A file at the prefix root has no directory to collapse into.
    asserts.equals(env, {
        "toplevel.txt": sp_a,
        "etc": sp_a,
        "share/jupyter/labext": sp_a,
        "share/jupyter/nbext": sp_b,
    }, data_files)

    # Collapsing is a projection change only — nothing here is contested.
    asserts.equals(env, [], collisions)
    return unittest.end(env)

def _namespace_entry_collapse_test_impl(ctx):
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_cccl/site-packages"
    sp_b = "external/pypi_runtime/site-packages"

    # An `__init__.py`-free header tree resolves every file to its own
    # namespace entry (see `derive_layout`), which is what makes the
    # collapse load-bearing rather than cosmetic.
    entries_a = [
        "nvidia/cu13/include/cccl/cuda/std/atomic",
        "nvidia/cu13/include/cccl/cuda/std/version",
        "nvidia/cu13/include/cccl/nv/target",
        "nvidia/cu13/lib/libcccl.so",
    ]
    entries_b = [
        "nvidia/cu13/include/cuda_runtime.h",
        "nvidia/cu13/bin/nvcc",
    ]
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            tl_claims = [("nvidia", _claim(sp_a, is_ns = True, is_dir = True, ns_entries = entries_a))],
            ns_entries = entries_a,
            namespace_dirs = ["nvidia/cu13", "nvidia/cu13/include"],
            top_levels = ["nvidia"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            tl_claims = [("nvidia", _claim(sp_b, is_ns = True, is_dir = True, ns_entries = entries_b))],
            ns_entries = entries_b,
            namespace_dirs = ["nvidia/cu13", "nvidia/cu13/include"],
            top_levels = ["nvidia"],
        ),
    ]
    top_level, _, _, merge_groups, _, collisions = resolve_wheel_collisions(mock_ctx, wheels)

    # Six per-file symlinks become four directory symlinks. `nvidia/cu13` and
    # `nvidia/cu13/include` are shared, so resolution descends through them;
    # below that each directory has a single owner and binds whole. A file
    # directly under a shared directory has nothing to collapse into.
    asserts.equals(env, {
        "nvidia/cu13/include/cccl": sp_a,
        "nvidia/cu13/lib": sp_a,
        "nvidia/cu13/include/cuda_runtime.h": sp_b,
        "nvidia/cu13/bin": sp_b,
    }, top_level)

    # Collapsing is a projection change only -- nothing here is contested.
    asserts.equals(env, [], collisions)
    asserts.equals(env, 0, len(merge_groups))
    return unittest.end(env)

def _namespace_entry_collapse_respects_losers_test_impl(ctx):
    """A `.pth`-routed loser still blocks collapse above its files.

    Both wheels ship `ns/pkg/mod.py`, so the earlier claimant loses that entry
    and falls back to `.pth`. Binding `ns/pkg` to the winner would hide the
    loser's sibling file from the PEP 420 `__path__` union, so the shared
    directory must stay per-entry.
    """
    env = unittest.begin(ctx)
    mock_ctx = _mock_ctx(ctx.label)
    sp_a = "external/pypi_a/site-packages"
    sp_b = "external/pypi_b/site-packages"
    entries_a = ["ns/pkg/mod.py", "ns/pkg/only_a.py"]
    entries_b = ["ns/pkg/mod.py"]
    wheels = [
        _make_wheel(
            site_packages_rfpath = sp_a,
            tl_claims = [("ns", _claim(sp_a, is_ns = True, is_dir = True, ns_entries = entries_a))],
            ns_entries = entries_a,
            namespace_dirs = ["ns/pkg"],
            top_levels = ["ns"],
        ),
        _make_wheel(
            site_packages_rfpath = sp_b,
            tl_claims = [("ns", _claim(sp_b, is_ns = True, is_dir = True, ns_entries = entries_b))],
            ns_entries = entries_b,
            namespace_dirs = ["ns/pkg"],
            top_levels = ["ns"],
        ),
    ]
    top_level, _, _, _, _, collisions = resolve_wheel_collisions(mock_ctx, wheels)

    asserts.equals(env, {
        "ns/pkg/mod.py": sp_b,
        "ns/pkg/only_a.py": sp_a,
    }, top_level)
    asserts.equals(env, 1, len(collisions))
    asserts.equals(env, "ns/pkg/mod.py", collisions[0].name)
    return unittest.end(env)

_single_wheel_test = unittest.make(_single_wheel_test_impl)
_namespace_merge_test = unittest.make(_namespace_merge_test_impl)
_console_script_collision_test = unittest.make(_console_script_collision_test_impl)
_regular_collision_keeps_fallback_test = unittest.make(_regular_collision_keeps_fallback_test_impl)
_entryless_namespace_keeps_fallback_test = unittest.make(_entryless_namespace_keeps_fallback_test_impl)
_data_file_collision_test = unittest.make(_data_file_collision_test_impl)
_data_file_reserved_path_test = unittest.make(_data_file_reserved_path_test_impl)
_data_file_nesting_test = unittest.make(_data_file_nesting_test_impl)
_data_file_collapse_test = unittest.make(_data_file_collapse_test_impl)
_namespace_entry_collapse_test = unittest.make(_namespace_entry_collapse_test_impl)
_namespace_entry_collapse_respects_losers_test = unittest.make(
    _namespace_entry_collapse_respects_losers_test_impl,
)

def virtuals_resolvers_test_suite(name):
    unittest.suite(
        name,
        _single_wheel_test,
        _namespace_merge_test,
        _console_script_collision_test,
        _regular_collision_keeps_fallback_test,
        _entryless_namespace_keeps_fallback_test,
        _data_file_collision_test,
        _data_file_reserved_path_test,
        _data_file_nesting_test,
        _data_file_collapse_test,
        _namespace_entry_collapse_test,
        _namespace_entry_collapse_respects_losers_test,
    )
