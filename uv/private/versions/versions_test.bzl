load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":versions.bzl", "find_matching_version", "parse_version", "version_cmp", "version_satisfies")

# =============================================================================
# parse_version tests
# =============================================================================

def _parse_version_simple_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [1, 2, 3], parse_version("1.2.3"))
    asserts.equals(env, [21, 3], parse_version("21.3"))
    asserts.equals(env, [0, 0, 1], parse_version("0.0.1"))
    asserts.equals(env, [24, 0], parse_version("24.0"))
    return unittest.end(env)

parse_version_simple_test = unittest.make(_parse_version_simple_test_impl)

def _parse_version_prerelease_test_impl(ctx):
    env = unittest.begin(ctx)
    # Pre-release suffixes are stripped to the numeric prefix
    asserts.equals(env, [2, 0, 0], parse_version("2.0.0rc1"))
    asserts.equals(env, [1, 0], parse_version("1.0a1"))
    asserts.equals(env, [3, 0, 0, 0], parse_version("3.0.0.dev4"))
    return unittest.end(env)

parse_version_prerelease_test = unittest.make(_parse_version_prerelease_test_impl)

def _parse_version_epoch_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [2, 0], parse_version("1!2.0"))
    return unittest.end(env)

parse_version_epoch_test = unittest.make(_parse_version_epoch_test_impl)

def _parse_version_whitespace_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [1, 0], parse_version("  1.0  "))
    return unittest.end(env)

parse_version_whitespace_test = unittest.make(_parse_version_whitespace_test_impl)

# =============================================================================
# version_cmp tests
# =============================================================================

def _version_cmp_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 0, version_cmp([1, 0], [1, 0]), "1.0 == 1.0")
    asserts.equals(env, 0, version_cmp([1, 0], [1, 0, 0]), "1.0 == 1.0.0 (trailing zeros)")
    asserts.equals(env, -1, version_cmp([1, 0], [2, 0]), "1.0 < 2.0")
    asserts.equals(env, 1, version_cmp([2, 0], [1, 0]), "2.0 > 1.0")
    asserts.equals(env, -1, version_cmp([1, 2], [1, 3]), "1.2 < 1.3")
    asserts.equals(env, 1, version_cmp([21, 3], [21, 0]), "21.3 > 21.0")
    asserts.equals(env, -1, version_cmp([1], [1, 0, 1]), "1 < 1.0.1")
    return unittest.end(env)

version_cmp_test = unittest.make(_version_cmp_test_impl)

# =============================================================================
# version_satisfies tests — operators
# =============================================================================

def _satisfies_eq_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("24.0", "==24.0"), "24.0 == 24.0")
    asserts.false(env, version_satisfies("21.3", "==24.0"), "21.3 != 24.0")
    asserts.true(env, version_satisfies("1.0.0", "==1.0"), "1.0.0 == 1.0 (trailing zeros)")
    return unittest.end(env)

satisfies_eq_test = unittest.make(_satisfies_eq_test_impl)

def _satisfies_neq_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("21.3", "!=24.0"), "21.3 != 24.0")
    asserts.false(env, version_satisfies("24.0", "!=24.0"), "24.0 == 24.0")
    return unittest.end(env)

satisfies_neq_test = unittest.make(_satisfies_neq_test_impl)

def _satisfies_gte_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("24.0", ">=21.0"), "24.0 >= 21.0")
    asserts.true(env, version_satisfies("21.0", ">=21.0"), "21.0 >= 21.0")
    asserts.false(env, version_satisfies("20.0", ">=21.0"), "20.0 < 21.0")
    return unittest.end(env)

satisfies_gte_test = unittest.make(_satisfies_gte_test_impl)

def _satisfies_lte_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("21.0", "<=24.0"), "21.0 <= 24.0")
    asserts.true(env, version_satisfies("24.0", "<=24.0"), "24.0 <= 24.0")
    asserts.false(env, version_satisfies("25.0", "<=24.0"), "25.0 > 24.0")
    return unittest.end(env)

satisfies_lte_test = unittest.make(_satisfies_lte_test_impl)

def _satisfies_gt_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("24.0", ">21.0"), "24.0 > 21.0")
    asserts.false(env, version_satisfies("21.0", ">21.0"), "21.0 == 21.0, not >")
    asserts.false(env, version_satisfies("20.0", ">21.0"), "20.0 < 21.0")
    return unittest.end(env)

satisfies_gt_test = unittest.make(_satisfies_gt_test_impl)

def _satisfies_lt_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("20.0", "<21.0"), "20.0 < 21.0")
    asserts.false(env, version_satisfies("21.0", "<21.0"), "21.0 == 21.0, not <")
    asserts.false(env, version_satisfies("22.0", "<21.0"), "22.0 > 21.0")
    return unittest.end(env)

satisfies_lt_test = unittest.make(_satisfies_lt_test_impl)

def _satisfies_compatible_test_impl(ctx):
    env = unittest.begin(ctx)
    # ~=2.1 means >=2.1,<3.0
    asserts.true(env, version_satisfies("2.1", "~=2.1"), "2.1 ~= 2.1")
    asserts.true(env, version_satisfies("2.5", "~=2.1"), "2.5 ~= 2.1")
    asserts.true(env, version_satisfies("2.99", "~=2.1"), "2.99 ~= 2.1")
    asserts.false(env, version_satisfies("3.0", "~=2.1"), "3.0 not ~= 2.1")
    asserts.false(env, version_satisfies("2.0", "~=2.1"), "2.0 not ~= 2.1")

    # ~=1.4.2 means >=1.4.2,<1.5.0
    asserts.true(env, version_satisfies("1.4.2", "~=1.4.2"), "1.4.2 ~= 1.4.2")
    asserts.true(env, version_satisfies("1.4.5", "~=1.4.2"), "1.4.5 ~= 1.4.2")
    asserts.false(env, version_satisfies("1.5.0", "~=1.4.2"), "1.5.0 not ~= 1.4.2")
    asserts.false(env, version_satisfies("1.4.1", "~=1.4.2"), "1.4.1 not ~= 1.4.2")
    return unittest.end(env)

satisfies_compatible_test = unittest.make(_satisfies_compatible_test_impl)

# =============================================================================
# version_satisfies tests — compound specifiers
# =============================================================================

def _satisfies_compound_test_impl(ctx):
    env = unittest.begin(ctx)
    # >=21.0,<25.0
    asserts.true(env, version_satisfies("24.0", ">=21.0,<25.0"), "24.0 in [21,25)")
    asserts.true(env, version_satisfies("21.0", ">=21.0,<25.0"), "21.0 in [21,25)")
    asserts.false(env, version_satisfies("25.0", ">=21.0,<25.0"), "25.0 not in [21,25)")
    asserts.false(env, version_satisfies("20.0", ">=21.0,<25.0"), "20.0 not in [21,25)")

    # >=2.0,!=2.1
    asserts.true(env, version_satisfies("2.0", ">=2.0,!=2.1"), "2.0 >= 2.0 and != 2.1")
    asserts.false(env, version_satisfies("2.1", ">=2.0,!=2.1"), "2.1 excluded")
    asserts.true(env, version_satisfies("2.2", ">=2.0,!=2.1"), "2.2 ok")
    return unittest.end(env)

satisfies_compound_test = unittest.make(_satisfies_compound_test_impl)

# =============================================================================
# version_satisfies tests — wildcards
# =============================================================================

def _satisfies_wildcard_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("1.0.0", "==1.0.*"), "1.0.0 matches 1.0.*")
    asserts.true(env, version_satisfies("1.0.99", "==1.0.*"), "1.0.99 matches 1.0.*")
    asserts.false(env, version_satisfies("1.1.0", "==1.0.*"), "1.1.0 doesn't match 1.0.*")
    asserts.false(env, version_satisfies("2.0.0", "==1.0.*"), "2.0.0 doesn't match 1.0.*")

    asserts.true(env, version_satisfies("1.1.0", "!=1.0.*"), "1.1.0 != 1.0.*")
    asserts.false(env, version_satisfies("1.0.5", "!=1.0.*"), "1.0.5 matches 1.0.*")
    return unittest.end(env)

satisfies_wildcard_test = unittest.make(_satisfies_wildcard_test_impl)

# =============================================================================
# find_matching_version tests
# =============================================================================

def _find_matching_version_test_impl(ctx):
    env = unittest.begin(ctx)

    candidates = {
        "21.3": ("proj", "packaging", "21.3", "__base__"),
        "24.0": ("proj", "packaging", "24.0", "__base__"),
    }

    # Exact pin
    asserts.equals(
        env,
        ("proj", "packaging", "24.0", "__base__"),
        find_matching_version("==24.0", candidates),
        "==24.0 finds 24.0",
    )
    asserts.equals(
        env,
        ("proj", "packaging", "21.3", "__base__"),
        find_matching_version("==21.3", candidates),
        "==21.3 finds 21.3",
    )

    # Range match — >=22.0 should match 24.0 (only version >= 22)
    asserts.equals(
        env,
        ("proj", "packaging", "24.0", "__base__"),
        find_matching_version(">=22.0", candidates),
        ">=22.0 finds 24.0",
    )

    # Range match — <22.0 should match 21.3
    asserts.equals(
        env,
        ("proj", "packaging", "21.3", "__base__"),
        find_matching_version("<22.0", candidates),
        "<22.0 finds 21.3",
    )

    # No match
    asserts.equals(
        env,
        None,
        find_matching_version(">=25.0", candidates),
        ">=25.0 finds nothing",
    )

    # Compatible release
    asserts.equals(
        env,
        ("proj", "packaging", "21.3", "__base__"),
        find_matching_version("~=21.0", candidates),
        "~=21.0 finds 21.3",
    )

    return unittest.end(env)

find_matching_version_test = unittest.make(_find_matching_version_test_impl)

def _find_matching_version_gte_test_impl(ctx):
    """Simulates the client's reported issue: >=X.Y bounds in dependency groups."""
    env = unittest.begin(ctx)

    candidates = {
        "2.0.0": ("proj", "numpy", "2.0.0", "__base__"),
        "2.1.2": ("proj", "numpy", "2.1.2", "__base__"),
    }

    # >=2.1 should match 2.1.2 (only candidate >= 2.1)
    asserts.equals(
        env,
        ("proj", "numpy", "2.1.2", "__base__"),
        find_matching_version(">=2.1", candidates),
        ">=2.1 finds 2.1.2",
    )

    # >=2.0 matches the first candidate it finds that satisfies; both match
    result = find_matching_version(">=2.0", candidates)
    asserts.true(env, result != None, ">=2.0 finds at least one")

    return unittest.end(env)

find_matching_version_gte_test = unittest.make(_find_matching_version_gte_test_impl)

# =============================================================================
# Test suite
# =============================================================================

def versions_test_suite():
    unittest.suite(
        "versions_test",
        parse_version_simple_test,
        parse_version_prerelease_test,
        parse_version_epoch_test,
        parse_version_whitespace_test,
        version_cmp_test,
        satisfies_eq_test,
        satisfies_neq_test,
        satisfies_gte_test,
        satisfies_lte_test,
        satisfies_gt_test,
        satisfies_lt_test,
        satisfies_compatible_test,
        satisfies_compound_test,
        satisfies_wildcard_test,
        find_matching_version_test,
        find_matching_version_gte_test,
    )
