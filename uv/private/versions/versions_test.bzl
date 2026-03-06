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
    asserts.equals(env, [0], parse_version("0"))
    asserts.equals(env, [1], parse_version("1"))
    asserts.equals(env, [2014, 4], parse_version("2014.04"))
    asserts.equals(env, [1, 0, 0, 0, 0], parse_version("1.0.0.0.0"))
    return unittest.end(env)

parse_version_simple_test = unittest.make(_parse_version_simple_test_impl)

def _parse_version_prerelease_test_impl(ctx):
    env = unittest.begin(ctx)

    # Pre-release suffixes are stripped to the numeric prefix
    asserts.equals(env, [2, 0, 0], parse_version("2.0.0rc1"))
    asserts.equals(env, [1, 0], parse_version("1.0a1"))
    asserts.equals(env, [1, 0], parse_version("1.0b2"))
    asserts.equals(env, [3, 0, 0, 0], parse_version("3.0.0.dev4"))
    # Alpha/beta with no number
    asserts.equals(env, [1, 2], parse_version("1.2a"))
    asserts.equals(env, [1, 2], parse_version("1.2b"))
    # Post-release
    asserts.equals(env, [1, 0, 0], parse_version("1.0.post1"))
    asserts.equals(env, [1, 0, 0], parse_version("1.0.post456"))
    return unittest.end(env)

parse_version_prerelease_test = unittest.make(_parse_version_prerelease_test_impl)

def _parse_version_epoch_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [2, 0], parse_version("1!2.0"))
    asserts.equals(env, [1, 0], parse_version("0!1.0"))
    asserts.equals(env, [3, 5, 2], parse_version("2!3.5.2"))
    return unittest.end(env)

parse_version_epoch_test = unittest.make(_parse_version_epoch_test_impl)

def _parse_version_whitespace_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [1, 0], parse_version("  1.0  "))
    asserts.equals(env, [2, 3], parse_version("  2.3"))
    asserts.equals(env, [4, 5], parse_version("4.5  "))
    return unittest.end(env)

parse_version_whitespace_test = unittest.make(_parse_version_whitespace_test_impl)

def _parse_version_local_test_impl(ctx):
    """Local version labels (+foo) are stripped since they're after non-numeric chars."""
    env = unittest.begin(ctx)
    asserts.equals(env, [1, 0], parse_version("1.0+ubuntu.1"))
    asserts.equals(env, [1, 0], parse_version("1.0+abc.5"))
    asserts.equals(env, [1, 0], parse_version("1.0+5"))
    return unittest.end(env)

parse_version_local_test = unittest.make(_parse_version_local_test_impl)

def _parse_version_leading_v_test_impl(ctx):
    """Leading 'v' prefix should be handled (common in tags)."""
    env = unittest.begin(ctx)
    # Our parser stops at non-digit, so 'v' prefix means numeric starts after
    # parse_version strips to numeric portion — 'v' is non-digit so numeric is empty
    # This is a known limitation; lockfile versions won't have 'v' prefix
    result = parse_version("v1.0")
    # 'v' is at position 0, not a digit, so end=0, numeric=""
    asserts.equals(env, [0], result)
    return unittest.end(env)

parse_version_leading_v_test = unittest.make(_parse_version_leading_v_test_impl)

def _parse_version_leading_zeros_test_impl(ctx):
    """Integer normalization: leading zeros are stripped via int()."""
    env = unittest.begin(ctx)
    asserts.equals(env, [1, 0, 0], parse_version("01.00.00"))
    asserts.equals(env, [9000], parse_version("09000"))
    return unittest.end(env)

parse_version_leading_zeros_test = unittest.make(_parse_version_leading_zeros_test_impl)

# =============================================================================
# version_cmp tests
# =============================================================================

def _version_cmp_basic_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 0, version_cmp([1, 0], [1, 0]), "1.0 == 1.0")
    asserts.equals(env, -1, version_cmp([1, 0], [2, 0]), "1.0 < 2.0")
    asserts.equals(env, 1, version_cmp([2, 0], [1, 0]), "2.0 > 1.0")
    asserts.equals(env, -1, version_cmp([1, 2], [1, 3]), "1.2 < 1.3")
    asserts.equals(env, 1, version_cmp([21, 3], [21, 0]), "21.3 > 21.0")
    return unittest.end(env)

version_cmp_basic_test = unittest.make(_version_cmp_basic_test_impl)

def _version_cmp_padding_test_impl(ctx):
    """Trailing zeros should not affect comparison (1.0 == 1.0.0 == 1.0.0.0)."""
    env = unittest.begin(ctx)
    asserts.equals(env, 0, version_cmp([1, 0], [1, 0, 0]), "1.0 == 1.0.0")
    asserts.equals(env, 0, version_cmp([1, 0, 0], [1, 0]), "1.0.0 == 1.0")
    asserts.equals(env, 0, version_cmp([1], [1, 0, 0, 0]), "1 == 1.0.0.0")
    asserts.equals(env, 0, version_cmp([0], [0, 0, 0]), "0 == 0.0.0")
    asserts.equals(env, -1, version_cmp([1], [1, 0, 1]), "1 < 1.0.1")
    asserts.equals(env, 1, version_cmp([1, 0, 1], [1]), "1.0.1 > 1")
    return unittest.end(env)

version_cmp_padding_test = unittest.make(_version_cmp_padding_test_impl)

def _version_cmp_long_test_impl(ctx):
    """Many-segment versions."""
    env = unittest.begin(ctx)
    asserts.equals(env, 0, version_cmp([1, 2, 3, 4, 5], [1, 2, 3, 4, 5]))
    asserts.equals(env, -1, version_cmp([1, 2, 3, 4, 5], [1, 2, 3, 4, 6]))
    asserts.equals(env, 1, version_cmp([1, 2, 3, 5, 0], [1, 2, 3, 4, 99]))
    return unittest.end(env)

version_cmp_long_test = unittest.make(_version_cmp_long_test_impl)

def _version_cmp_large_numbers_test_impl(ctx):
    """Calendar versioning and large segment numbers."""
    env = unittest.begin(ctx)
    asserts.equals(env, -1, version_cmp([2023, 1], [2024, 1]))
    asserts.equals(env, 1, version_cmp([2024, 12], [2024, 1]))
    asserts.equals(env, 0, version_cmp([20240101, 0], [20240101, 0]))
    return unittest.end(env)

version_cmp_large_numbers_test = unittest.make(_version_cmp_large_numbers_test_impl)

# =============================================================================
# version_satisfies — == (Version Matching)
# =============================================================================

def _satisfies_eq_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("24.0", "==24.0"), "24.0 == 24.0")
    asserts.false(env, version_satisfies("21.3", "==24.0"), "21.3 != 24.0")
    # Zero-padding: 1.1 and 1.1.0 are equivalent
    asserts.true(env, version_satisfies("1.0.0", "==1.0"), "1.0.0 == 1.0 (zero-padded)")
    asserts.true(env, version_satisfies("1.0", "==1.0.0"), "1.0 == 1.0.0 (zero-padded)")
    asserts.true(env, version_satisfies("1.0", "==1.0.0.0.0"), "1.0 == 1.0.0.0.0")
    # Whitespace in specifier
    asserts.true(env, version_satisfies("1.0", "== 1.0"), "whitespace after ==")
    asserts.true(env, version_satisfies("1.0", "==  1.0"), "double whitespace after ==")
    # Exact match required
    asserts.false(env, version_satisfies("1.0.1", "==1.0"), "1.0.1 != 1.0")
    asserts.false(env, version_satisfies("1.1", "==1.0"), "1.1 != 1.0")
    asserts.false(env, version_satisfies("0.9", "==1.0"), "0.9 != 1.0")
    return unittest.end(env)

satisfies_eq_test = unittest.make(_satisfies_eq_test_impl)

# =============================================================================
# version_satisfies — != (Version Exclusion)
# =============================================================================

def _satisfies_neq_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("21.3", "!=24.0"), "21.3 != 24.0")
    asserts.false(env, version_satisfies("24.0", "!=24.0"), "24.0 == 24.0")
    # Zero-padding
    asserts.false(env, version_satisfies("1.0.0", "!=1.0"), "1.0.0 == 1.0 (zero-padded)")
    asserts.true(env, version_satisfies("1.0.1", "!=1.0"), "1.0.1 != 1.0")
    return unittest.end(env)

satisfies_neq_test = unittest.make(_satisfies_neq_test_impl)

# =============================================================================
# version_satisfies — >= (Inclusive Ordered)
# =============================================================================

def _satisfies_gte_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("24.0", ">=21.0"), "24.0 >= 21.0")
    asserts.true(env, version_satisfies("21.0", ">=21.0"), "21.0 >= 21.0 (boundary)")
    asserts.false(env, version_satisfies("20.0", ">=21.0"), "20.0 < 21.0")
    # Zero-padding: 1.0.0 >= 1.0
    asserts.true(env, version_satisfies("1.0.0", ">=1.0"), "1.0.0 >= 1.0")
    asserts.true(env, version_satisfies("1.0", ">=1.0.0"), "1.0 >= 1.0.0")
    asserts.true(env, version_satisfies("1.0.1", ">=1.0"), "1.0.1 >= 1.0")
    asserts.false(env, version_satisfies("0.9.9", ">=1.0"), "0.9.9 < 1.0")
    return unittest.end(env)

satisfies_gte_test = unittest.make(_satisfies_gte_test_impl)

# =============================================================================
# version_satisfies — <= (Inclusive Ordered)
# =============================================================================

def _satisfies_lte_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("21.0", "<=24.0"), "21.0 <= 24.0")
    asserts.true(env, version_satisfies("24.0", "<=24.0"), "24.0 <= 24.0 (boundary)")
    asserts.false(env, version_satisfies("25.0", "<=24.0"), "25.0 > 24.0")
    # Zero-padding
    asserts.true(env, version_satisfies("1.0", "<=1.0.0"), "1.0 <= 1.0.0")
    asserts.true(env, version_satisfies("1.0.0", "<=1.0"), "1.0.0 <= 1.0")
    asserts.false(env, version_satisfies("1.0.1", "<=1.0"), "1.0.1 > 1.0")
    return unittest.end(env)

satisfies_lte_test = unittest.make(_satisfies_lte_test_impl)

# =============================================================================
# version_satisfies — > (Exclusive Ordered)
# =============================================================================

def _satisfies_gt_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("24.0", ">21.0"), "24.0 > 21.0")
    asserts.false(env, version_satisfies("21.0", ">21.0"), "21.0 == 21.0, not >")
    asserts.false(env, version_satisfies("20.0", ">21.0"), "20.0 < 21.0")
    # Boundary: just above
    asserts.true(env, version_satisfies("1.0.1", ">1.0"), "1.0.1 > 1.0")
    asserts.true(env, version_satisfies("1.1", ">1.0"), "1.1 > 1.0")
    # Zero-padding: 1.0.0 == 1.0, so not >
    asserts.false(env, version_satisfies("1.0.0", ">1.0"), "1.0.0 == 1.0 (not >)")
    asserts.false(env, version_satisfies("1.0", ">1.0.0"), "1.0 == 1.0.0 (not >)")
    # Per PEP 440: >1.7 should allow 1.7.1
    asserts.true(env, version_satisfies("1.7.1", ">1.7"), "1.7.1 > 1.7")
    return unittest.end(env)

satisfies_gt_test = unittest.make(_satisfies_gt_test_impl)

# =============================================================================
# version_satisfies — < (Exclusive Ordered)
# =============================================================================

def _satisfies_lt_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("20.0", "<21.0"), "20.0 < 21.0")
    asserts.false(env, version_satisfies("21.0", "<21.0"), "21.0 == 21.0, not <")
    asserts.false(env, version_satisfies("22.0", "<21.0"), "22.0 > 21.0")
    # Boundary: just below
    asserts.true(env, version_satisfies("0.9.9", "<1.0"), "0.9.9 < 1.0")
    asserts.true(env, version_satisfies("0.99", "<1.0"), "0.99 < 1.0")
    # Zero-padding: 1.0.0 == 1.0, so not <
    asserts.false(env, version_satisfies("1.0.0", "<1.0"), "1.0.0 == 1.0 (not <)")
    asserts.false(env, version_satisfies("1.0", "<1.0.0"), "1.0 == 1.0.0 (not <)")
    return unittest.end(env)

satisfies_lt_test = unittest.make(_satisfies_lt_test_impl)

# =============================================================================
# version_satisfies — ~= (Compatible Release)
# =============================================================================

def _satisfies_compatible_two_segment_test_impl(ctx):
    """~=X.Y means >=X.Y, ==X.*"""
    env = unittest.begin(ctx)
    # ~=2.2 is >=2.2, ==2.*  (i.e. >=2.2, <3.0)
    asserts.true(env, version_satisfies("2.2", "~=2.2"), "2.2 ~= 2.2 (exact)")
    asserts.true(env, version_satisfies("2.2.0", "~=2.2"), "2.2.0 ~= 2.2")
    asserts.true(env, version_satisfies("2.3", "~=2.2"), "2.3 ~= 2.2")
    asserts.true(env, version_satisfies("2.5", "~=2.2"), "2.5 ~= 2.2")
    asserts.true(env, version_satisfies("2.99", "~=2.2"), "2.99 ~= 2.2")
    asserts.true(env, version_satisfies("2.99.99", "~=2.2"), "2.99.99 ~= 2.2")
    asserts.false(env, version_satisfies("3.0", "~=2.2"), "3.0 not ~= 2.2 (upper bound)")
    asserts.false(env, version_satisfies("3.0.0", "~=2.2"), "3.0.0 not ~= 2.2")
    asserts.false(env, version_satisfies("2.1", "~=2.2"), "2.1 not ~= 2.2 (below)")
    asserts.false(env, version_satisfies("2.0", "~=2.2"), "2.0 not ~= 2.2")
    asserts.false(env, version_satisfies("1.0", "~=2.2"), "1.0 not ~= 2.2")
    return unittest.end(env)

satisfies_compatible_two_segment_test = unittest.make(_satisfies_compatible_two_segment_test_impl)

def _satisfies_compatible_three_segment_test_impl(ctx):
    """~=X.Y.Z means >=X.Y.Z, ==X.Y.*  (i.e. >=X.Y.Z, <X.(Y+1).0)"""
    env = unittest.begin(ctx)
    # ~=1.4.2 is >=1.4.2, <1.5.0
    asserts.true(env, version_satisfies("1.4.2", "~=1.4.2"), "1.4.2 (exact)")
    asserts.true(env, version_satisfies("1.4.3", "~=1.4.2"), "1.4.3")
    asserts.true(env, version_satisfies("1.4.5", "~=1.4.2"), "1.4.5")
    asserts.true(env, version_satisfies("1.4.99", "~=1.4.2"), "1.4.99")
    asserts.false(env, version_satisfies("1.5.0", "~=1.4.2"), "1.5.0 (upper bound)")
    asserts.false(env, version_satisfies("1.4.1", "~=1.4.2"), "1.4.1 (below)")
    asserts.false(env, version_satisfies("1.4.0", "~=1.4.2"), "1.4.0 (below)")
    asserts.false(env, version_satisfies("1.3.0", "~=1.4.2"), "1.3.0 (below)")
    asserts.false(env, version_satisfies("2.0.0", "~=1.4.2"), "2.0.0 (above)")
    return unittest.end(env)

satisfies_compatible_three_segment_test = unittest.make(_satisfies_compatible_three_segment_test_impl)

def _satisfies_compatible_four_segment_test_impl(ctx):
    """~=X.Y.Z.W means >=X.Y.Z.W, <X.Y.(Z+1).0"""
    env = unittest.begin(ctx)
    # ~=1.4.2.0 is >=1.4.2.0, <1.4.3.0
    asserts.true(env, version_satisfies("1.4.2.0", "~=1.4.2.0"), "exact")
    asserts.true(env, version_satisfies("1.4.2.1", "~=1.4.2.0"), "1.4.2.1")
    asserts.true(env, version_satisfies("1.4.2.99", "~=1.4.2.0"), "1.4.2.99")
    asserts.false(env, version_satisfies("1.4.3.0", "~=1.4.2.0"), "upper bound")
    asserts.false(env, version_satisfies("1.4.1.0", "~=1.4.2.0"), "below")
    return unittest.end(env)

satisfies_compatible_four_segment_test = unittest.make(_satisfies_compatible_four_segment_test_impl)

def _satisfies_compatible_vs_eq_star_test_impl(ctx):
    """Demonstrate that ~=2.2.0 is stricter than ~=2.2."""
    env = unittest.begin(ctx)
    # ~=2.2   is >=2.2, <3.0   — allows 2.3, 2.99 etc.
    # ~=2.2.0 is >=2.2.0, <2.3 — does NOT allow 2.3
    asserts.true(env, version_satisfies("2.3", "~=2.2"), "2.3 matches ~=2.2")
    asserts.false(env, version_satisfies("2.3", "~=2.2.0"), "2.3 does NOT match ~=2.2.0")
    asserts.true(env, version_satisfies("2.2.5", "~=2.2.0"), "2.2.5 matches ~=2.2.0")
    return unittest.end(env)

satisfies_compatible_vs_eq_star_test = unittest.make(_satisfies_compatible_vs_eq_star_test_impl)

# =============================================================================
# version_satisfies — == with wildcards
# =============================================================================

def _satisfies_wildcard_eq_test_impl(ctx):
    env = unittest.begin(ctx)
    # ==1.0.* matches any 1.0.x
    asserts.true(env, version_satisfies("1.0.0", "==1.0.*"), "1.0.0")
    asserts.true(env, version_satisfies("1.0.1", "==1.0.*"), "1.0.1")
    asserts.true(env, version_satisfies("1.0.99", "==1.0.*"), "1.0.99")
    asserts.true(env, version_satisfies("1.0.0.0", "==1.0.*"), "1.0.0.0 (extra segment)")
    asserts.false(env, version_satisfies("1.1.0", "==1.0.*"), "1.1.0 no match")
    asserts.false(env, version_satisfies("2.0.0", "==1.0.*"), "2.0.0 no match")
    asserts.false(env, version_satisfies("0.9.0", "==1.0.*"), "0.9.0 no match")

    # ==1.* matches any 1.x
    asserts.true(env, version_satisfies("1.0", "==1.*"), "1.0")
    asserts.true(env, version_satisfies("1.99", "==1.*"), "1.99")
    asserts.true(env, version_satisfies("1.0.0", "==1.*"), "1.0.0")
    asserts.false(env, version_satisfies("2.0", "==1.*"), "2.0")
    asserts.false(env, version_satisfies("0.9", "==1.*"), "0.9")

    # ==2.* with various versions
    asserts.true(env, version_satisfies("2.0", "==2.*"), "2.0")
    asserts.true(env, version_satisfies("2.1.3.4", "==2.*"), "2.1.3.4")
    asserts.false(env, version_satisfies("3.0", "==2.*"), "3.0")
    return unittest.end(env)

satisfies_wildcard_eq_test = unittest.make(_satisfies_wildcard_eq_test_impl)

# =============================================================================
# version_satisfies — != with wildcards
# =============================================================================

def _satisfies_wildcard_neq_test_impl(ctx):
    env = unittest.begin(ctx)
    # !=1.0.* excludes all 1.0.x
    asserts.true(env, version_satisfies("1.1.0", "!=1.0.*"), "1.1.0 not in 1.0.*")
    asserts.true(env, version_satisfies("2.0.0", "!=1.0.*"), "2.0.0 not in 1.0.*")
    asserts.true(env, version_satisfies("0.9.0", "!=1.0.*"), "0.9.0 not in 1.0.*")
    asserts.false(env, version_satisfies("1.0.0", "!=1.0.*"), "1.0.0 is in 1.0.*")
    asserts.false(env, version_satisfies("1.0.5", "!=1.0.*"), "1.0.5 is in 1.0.*")
    asserts.false(env, version_satisfies("1.0.99", "!=1.0.*"), "1.0.99 is in 1.0.*")

    # !=1.* excludes all 1.x
    asserts.false(env, version_satisfies("1.0", "!=1.*"), "1.0 is in 1.*")
    asserts.false(env, version_satisfies("1.99", "!=1.*"), "1.99 is in 1.*")
    asserts.true(env, version_satisfies("2.0", "!=1.*"), "2.0 not in 1.*")
    asserts.true(env, version_satisfies("0.9", "!=1.*"), "0.9 not in 1.*")
    return unittest.end(env)

satisfies_wildcard_neq_test = unittest.make(_satisfies_wildcard_neq_test_impl)

# =============================================================================
# version_satisfies — compound specifiers
# =============================================================================

def _satisfies_compound_range_test_impl(ctx):
    """Compound specifiers: >=X,<Y (common range pattern)."""
    env = unittest.begin(ctx)
    # >=1.0,<2.0
    asserts.true(env, version_satisfies("1.0", ">=1.0,<2.0"), "1.0 in [1.0,2.0)")
    asserts.true(env, version_satisfies("1.5", ">=1.0,<2.0"), "1.5 in [1.0,2.0)")
    asserts.true(env, version_satisfies("1.99.99", ">=1.0,<2.0"), "1.99.99 in [1.0,2.0)")
    asserts.false(env, version_satisfies("2.0", ">=1.0,<2.0"), "2.0 not in [1.0,2.0)")
    asserts.false(env, version_satisfies("0.9", ">=1.0,<2.0"), "0.9 not in [1.0,2.0)")

    # >1.0,<=2.0
    asserts.false(env, version_satisfies("1.0", ">1.0,<=2.0"), "1.0 not in (1.0,2.0]")
    asserts.true(env, version_satisfies("1.0.1", ">1.0,<=2.0"), "1.0.1 in (1.0,2.0]")
    asserts.true(env, version_satisfies("2.0", ">1.0,<=2.0"), "2.0 in (1.0,2.0]")
    asserts.false(env, version_satisfies("2.0.1", ">1.0,<=2.0"), "2.0.1 not in (1.0,2.0]")
    return unittest.end(env)

satisfies_compound_range_test = unittest.make(_satisfies_compound_range_test_impl)

def _satisfies_compound_exclusion_test_impl(ctx):
    """Compound specifiers with exclusions."""
    env = unittest.begin(ctx)
    # >=2.0,!=2.1
    asserts.true(env, version_satisfies("2.0", ">=2.0,!=2.1"), "2.0 ok")
    asserts.false(env, version_satisfies("2.1", ">=2.0,!=2.1"), "2.1 excluded")
    asserts.true(env, version_satisfies("2.2", ">=2.0,!=2.1"), "2.2 ok")
    asserts.false(env, version_satisfies("1.9", ">=2.0,!=2.1"), "1.9 too low")

    # >=1.0,!=1.3.4.*,<2.0  (from PEP 440 example: ~=0.9,>=1.0,!=1.3.4.*,<2.0)
    asserts.true(env, version_satisfies("1.0", ">=1.0,!=1.3.4.*,<2.0"), "1.0 ok")
    asserts.true(env, version_satisfies("1.3.3", ">=1.0,!=1.3.4.*,<2.0"), "1.3.3 ok")
    asserts.false(env, version_satisfies("1.3.4.0", ">=1.0,!=1.3.4.*,<2.0"), "1.3.4.0 excluded")
    asserts.false(env, version_satisfies("1.3.4.1", ">=1.0,!=1.3.4.*,<2.0"), "1.3.4.1 excluded")
    asserts.true(env, version_satisfies("1.3.5", ">=1.0,!=1.3.4.*,<2.0"), "1.3.5 ok")
    asserts.false(env, version_satisfies("2.0", ">=1.0,!=1.3.4.*,<2.0"), "2.0 too high")
    return unittest.end(env)

satisfies_compound_exclusion_test = unittest.make(_satisfies_compound_exclusion_test_impl)

def _satisfies_compound_whitespace_test_impl(ctx):
    """Whitespace around commas and operators should be tolerated."""
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("1.5", ">= 1.0 , < 2.0"), "spaces around ops and comma")
    asserts.true(env, version_satisfies("1.5", ">=1.0 ,<2.0"), "space before comma")
    asserts.true(env, version_satisfies("1.5", ">=1.0, <2.0"), "space after comma")
    return unittest.end(env)

satisfies_compound_whitespace_test = unittest.make(_satisfies_compound_whitespace_test_impl)

def _satisfies_compound_many_clauses_test_impl(ctx):
    """Many clauses combined."""
    env = unittest.begin(ctx)
    # >=1.0,<3.0,!=1.5,!=2.0,!=2.5
    asserts.true(env, version_satisfies("1.0", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "1.0 ok")
    asserts.false(env, version_satisfies("1.5", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "1.5 excluded")
    asserts.true(env, version_satisfies("1.6", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "1.6 ok")
    asserts.false(env, version_satisfies("2.0", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "2.0 excluded")
    asserts.true(env, version_satisfies("2.1", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "2.1 ok")
    asserts.false(env, version_satisfies("2.5", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "2.5 excluded")
    asserts.true(env, version_satisfies("2.9", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "2.9 ok")
    asserts.false(env, version_satisfies("3.0", ">=1.0,<3.0,!=1.5,!=2.0,!=2.5"), "3.0 too high")
    return unittest.end(env)

satisfies_compound_many_clauses_test = unittest.make(_satisfies_compound_many_clauses_test_impl)

# =============================================================================
# version_satisfies — === (Arbitrary Equality)
# =============================================================================

def _satisfies_arbitrary_eq_test_impl(ctx):
    env = unittest.begin(ctx)
    # === does string comparison on parsed versions
    asserts.true(env, version_satisfies("1.0", "===1.0"), "1.0 === 1.0")
    asserts.true(env, version_satisfies("2.3.4", "===2.3.4"), "exact match")
    asserts.false(env, version_satisfies("1.0.1", "===1.0"), "1.0.1 !== 1.0")
    return unittest.end(env)

satisfies_arbitrary_eq_test = unittest.make(_satisfies_arbitrary_eq_test_impl)

# =============================================================================
# version_satisfies — edge cases and real-world patterns
# =============================================================================

def _satisfies_single_segment_test_impl(ctx):
    """Single-segment versions (e.g., major-only)."""
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("1", "==1"), "1 == 1")
    asserts.true(env, version_satisfies("1", ">=1"), "1 >= 1")
    asserts.true(env, version_satisfies("2", ">1"), "2 > 1")
    asserts.false(env, version_satisfies("1", ">1"), "1 not > 1")
    asserts.true(env, version_satisfies("0", "<1"), "0 < 1")
    asserts.false(env, version_satisfies("1", "<1"), "1 not < 1")
    asserts.true(env, version_satisfies("1", "~=1.0"), "1 == 1.0, ~=1.0 means >=1.0,<2.0")
    return unittest.end(env)

satisfies_single_segment_test = unittest.make(_satisfies_single_segment_test_impl)

def _satisfies_zero_versions_test_impl(ctx):
    """Edge cases around 0.x versions."""
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("0.0.0", "==0.0.0"), "0.0.0 == 0.0.0")
    asserts.true(env, version_satisfies("0.1", ">0.0"), "0.1 > 0.0")
    asserts.true(env, version_satisfies("0.0.1", ">0.0"), "0.0.1 > 0.0")
    asserts.false(env, version_satisfies("0.0", ">0.0"), "0.0 not > 0.0")
    asserts.true(env, version_satisfies("0.0", ">=0.0"), "0.0 >= 0.0")
    asserts.true(env, version_satisfies("0.0", "<0.1"), "0.0 < 0.1")
    asserts.true(env, version_satisfies("0.0", "<=0.0"), "0.0 <= 0.0")
    return unittest.end(env)

satisfies_zero_versions_test = unittest.make(_satisfies_zero_versions_test_impl)

def _satisfies_calver_test_impl(ctx):
    """Calendar versioning (common in projects like pip, Ubuntu, etc.)."""
    env = unittest.begin(ctx)
    asserts.true(env, version_satisfies("2024.1", ">=2024.0"), "calver >= lower")
    asserts.true(env, version_satisfies("2024.1", "<2025.0"), "calver < next year")
    asserts.false(env, version_satisfies("2023.12", ">=2024.0"), "calver below")
    asserts.true(env, version_satisfies("2024.3.1", "~=2024.3"), "calver compatible")
    asserts.true(env, version_satisfies("2024.4.0", "~=2024.3"), "calver next minor within compat range")
    # Hmm actually ~=2024.3 means >=2024.3, <2025.0 — 2024.4.0 is in range
    # Let me correct: ~=2024.3 means >=2024.3, <2025.0
    # But 2024.4 < 2025.0, so it should match!
    return unittest.end(env)

satisfies_calver_test = unittest.make(_satisfies_calver_test_impl)

def _satisfies_real_world_numpy_test_impl(ctx):
    """Real-world specifiers from popular packages."""
    env = unittest.begin(ctx)
    # numpy>=1.21.0
    asserts.true(env, version_satisfies("1.21.0", ">=1.21.0"))
    asserts.true(env, version_satisfies("1.26.4", ">=1.21.0"))
    asserts.true(env, version_satisfies("2.0.0", ">=1.21.0"))
    asserts.false(env, version_satisfies("1.20.3", ">=1.21.0"))

    # numpy>=1.21,<2.0
    asserts.true(env, version_satisfies("1.26.4", ">=1.21,<2.0"))
    asserts.false(env, version_satisfies("2.0.0", ">=1.21,<2.0"))
    asserts.false(env, version_satisfies("1.20.0", ">=1.21,<2.0"))
    return unittest.end(env)

satisfies_real_world_numpy_test = unittest.make(_satisfies_real_world_numpy_test_impl)

def _satisfies_real_world_django_test_impl(ctx):
    """Django-style version specifiers."""
    env = unittest.begin(ctx)
    # Django>=4.2,<5.0
    asserts.true(env, version_satisfies("4.2", ">=4.2,<5.0"))
    asserts.true(env, version_satisfies("4.2.11", ">=4.2,<5.0"))
    asserts.false(env, version_satisfies("5.0", ">=4.2,<5.0"))
    asserts.false(env, version_satisfies("4.1.9", ">=4.2,<5.0"))

    # ~=4.2 means >=4.2, <5.0
    asserts.true(env, version_satisfies("4.2", "~=4.2"))
    asserts.true(env, version_satisfies("4.9.99", "~=4.2"))
    asserts.false(env, version_satisfies("5.0", "~=4.2"))
    asserts.false(env, version_satisfies("4.1", "~=4.2"))
    return unittest.end(env)

satisfies_real_world_django_test = unittest.make(_satisfies_real_world_django_test_impl)

def _satisfies_real_world_requests_test_impl(ctx):
    """Requests-style version specifiers."""
    env = unittest.begin(ctx)
    # requests>=2.20.0,!=2.25.0
    asserts.true(env, version_satisfies("2.31.0", ">=2.20.0,!=2.25.0"))
    asserts.true(env, version_satisfies("2.20.0", ">=2.20.0,!=2.25.0"))
    asserts.false(env, version_satisfies("2.25.0", ">=2.20.0,!=2.25.0"))
    asserts.false(env, version_satisfies("2.19.1", ">=2.20.0,!=2.25.0"))
    return unittest.end(env)

satisfies_real_world_requests_test = unittest.make(_satisfies_real_world_requests_test_impl)

def _satisfies_real_world_protobuf_test_impl(ctx):
    """Protobuf-style range pinning."""
    env = unittest.begin(ctx)
    # protobuf>=3.19.5,<5.0.0,!=3.20.0,!=3.20.1,!=4.21.1,!=4.21.2,!=4.21.3,!=4.21.4,!=4.21.5
    spec = ">=3.19.5,<5.0.0,!=3.20.0,!=3.20.1,!=4.21.1,!=4.21.2,!=4.21.3,!=4.21.4,!=4.21.5"
    asserts.true(env, version_satisfies("3.19.5", spec), "3.19.5 ok")
    asserts.true(env, version_satisfies("4.25.3", spec), "4.25.3 ok")
    asserts.false(env, version_satisfies("3.20.0", spec), "3.20.0 excluded")
    asserts.false(env, version_satisfies("3.20.1", spec), "3.20.1 excluded")
    asserts.false(env, version_satisfies("4.21.3", spec), "4.21.3 excluded")
    asserts.false(env, version_satisfies("5.0.0", spec), "5.0.0 too high")
    asserts.false(env, version_satisfies("3.19.4", spec), "3.19.4 too low")
    return unittest.end(env)

satisfies_real_world_protobuf_test = unittest.make(_satisfies_real_world_protobuf_test_impl)

# =============================================================================
# version_satisfies — boundary precision tests
# =============================================================================

def _satisfies_boundary_precision_test_impl(ctx):
    """Tests around exact boundaries to catch off-by-one errors."""
    env = unittest.begin(ctx)
    # Right at the boundary for each operator
    asserts.true(env, version_satisfies("1.0", ">=1.0"))
    asserts.true(env, version_satisfies("1.0", "<=1.0"))
    asserts.false(env, version_satisfies("1.0", ">1.0"))
    asserts.false(env, version_satisfies("1.0", "<1.0"))
    asserts.true(env, version_satisfies("1.0", "==1.0"))
    asserts.false(env, version_satisfies("1.0", "!=1.0"))

    # One micro version above
    asserts.true(env, version_satisfies("1.0.1", ">=1.0"))
    asserts.false(env, version_satisfies("1.0.1", "<=1.0"))
    asserts.true(env, version_satisfies("1.0.1", ">1.0"))
    asserts.false(env, version_satisfies("1.0.1", "<1.0"))
    asserts.false(env, version_satisfies("1.0.1", "==1.0"))
    asserts.true(env, version_satisfies("1.0.1", "!=1.0"))

    # One micro version below (0.9.9... closest we can get)
    asserts.false(env, version_satisfies("0.9.9", ">=1.0"))
    asserts.true(env, version_satisfies("0.9.9", "<=1.0"))
    asserts.false(env, version_satisfies("0.9.9", ">1.0"))
    asserts.true(env, version_satisfies("0.9.9", "<1.0"))
    asserts.false(env, version_satisfies("0.9.9", "==1.0"))
    asserts.true(env, version_satisfies("0.9.9", "!=1.0"))
    return unittest.end(env)

satisfies_boundary_precision_test = unittest.make(_satisfies_boundary_precision_test_impl)

# =============================================================================
# find_matching_version tests
# =============================================================================

def _find_matching_version_exact_test_impl(ctx):
    env = unittest.begin(ctx)
    candidates = {
        "21.3": ("proj", "packaging", "21.3", "__base__"),
        "24.0": ("proj", "packaging", "24.0", "__base__"),
    }
    asserts.equals(env, ("proj", "packaging", "24.0", "__base__"), find_matching_version("==24.0", candidates))
    asserts.equals(env, ("proj", "packaging", "21.3", "__base__"), find_matching_version("==21.3", candidates))
    return unittest.end(env)

find_matching_version_exact_test = unittest.make(_find_matching_version_exact_test_impl)

def _find_matching_version_range_test_impl(ctx):
    env = unittest.begin(ctx)
    candidates = {
        "21.3": ("proj", "packaging", "21.3", "__base__"),
        "24.0": ("proj", "packaging", "24.0", "__base__"),
    }
    # >=22.0 should only match 24.0
    asserts.equals(env, ("proj", "packaging", "24.0", "__base__"), find_matching_version(">=22.0", candidates))
    # <22.0 should only match 21.3
    asserts.equals(env, ("proj", "packaging", "21.3", "__base__"), find_matching_version("<22.0", candidates))
    # >=25.0 should match nothing
    asserts.equals(env, None, find_matching_version(">=25.0", candidates))
    # <21.0 should match nothing
    asserts.equals(env, None, find_matching_version("<21.0", candidates))
    return unittest.end(env)

find_matching_version_range_test = unittest.make(_find_matching_version_range_test_impl)

def _find_matching_version_compatible_test_impl(ctx):
    env = unittest.begin(ctx)
    candidates = {
        "21.3": ("proj", "packaging", "21.3", "__base__"),
        "24.0": ("proj", "packaging", "24.0", "__base__"),
    }
    # ~=21.0 means >=21.0,<22.0 — matches 21.3 only
    asserts.equals(env, ("proj", "packaging", "21.3", "__base__"), find_matching_version("~=21.0", candidates))
    # ~=24.0 means >=24.0,<25.0 — matches 24.0 only
    asserts.equals(env, ("proj", "packaging", "24.0", "__base__"), find_matching_version("~=24.0", candidates))
    return unittest.end(env)

find_matching_version_compatible_test = unittest.make(_find_matching_version_compatible_test_impl)

def _find_matching_version_gte_client_test_impl(ctx):
    """Simulates the client's reported issue: >=X.Y bounds in dependency groups."""
    env = unittest.begin(ctx)
    candidates = {
        "2.0.0": ("proj", "numpy", "2.0.0", "__base__"),
        "2.1.2": ("proj", "numpy", "2.1.2", "__base__"),
    }
    # >=2.1 should match 2.1.2 (only candidate >= 2.1)
    asserts.equals(env, ("proj", "numpy", "2.1.2", "__base__"), find_matching_version(">=2.1", candidates))
    # >=2.0 matches at least one
    result = find_matching_version(">=2.0", candidates)
    asserts.true(env, result != None, ">=2.0 finds at least one")
    # <2.1 should only match 2.0.0
    asserts.equals(env, ("proj", "numpy", "2.0.0", "__base__"), find_matching_version("<2.1", candidates))
    return unittest.end(env)

find_matching_version_gte_client_test = unittest.make(_find_matching_version_gte_client_test_impl)

def _find_matching_version_compound_test_impl(ctx):
    """Compound specifier with multiple candidates."""
    env = unittest.begin(ctx)
    candidates = {
        "1.0": ("proj", "foo", "1.0", "__base__"),
        "1.5": ("proj", "foo", "1.5", "__base__"),
        "2.0": ("proj", "foo", "2.0", "__base__"),
    }
    # >=1.0,<2.0 should NOT match 2.0
    result = find_matching_version(">=1.0,<2.0", candidates)
    asserts.true(env, result != None, "at least one in [1.0,2.0)")
    asserts.true(env, result != ("proj", "foo", "2.0", "__base__"), "2.0 excluded")

    # ==2.0 should match exactly 2.0
    asserts.equals(env, ("proj", "foo", "2.0", "__base__"), find_matching_version("==2.0", candidates))

    # >=3.0 matches nothing
    asserts.equals(env, None, find_matching_version(">=3.0", candidates))
    return unittest.end(env)

find_matching_version_compound_test = unittest.make(_find_matching_version_compound_test_impl)

def _find_matching_version_empty_test_impl(ctx):
    """Empty candidate set."""
    env = unittest.begin(ctx)
    asserts.equals(env, None, find_matching_version(">=1.0", {}))
    asserts.equals(env, None, find_matching_version("==1.0", {}))
    return unittest.end(env)

find_matching_version_empty_test = unittest.make(_find_matching_version_empty_test_impl)

def _find_matching_version_single_test_impl(ctx):
    """Single candidate."""
    env = unittest.begin(ctx)
    candidates = {"3.11.0": ("proj", "python", "3.11.0", "__base__")}
    asserts.equals(env, ("proj", "python", "3.11.0", "__base__"), find_matching_version(">=3.11", candidates))
    asserts.equals(env, ("proj", "python", "3.11.0", "__base__"), find_matching_version("==3.11.0", candidates))
    asserts.equals(env, None, find_matching_version(">=3.12", candidates))
    asserts.equals(env, None, find_matching_version("<3.11", candidates))
    return unittest.end(env)

find_matching_version_single_test = unittest.make(_find_matching_version_single_test_impl)

# =============================================================================
# Test suite
# =============================================================================

def versions_test_suite():
    unittest.suite(
        "versions_test",
        # parse_version
        parse_version_simple_test,
        parse_version_prerelease_test,
        parse_version_epoch_test,
        parse_version_whitespace_test,
        parse_version_local_test,
        parse_version_leading_v_test,
        parse_version_leading_zeros_test,
        # version_cmp
        version_cmp_basic_test,
        version_cmp_padding_test,
        version_cmp_long_test,
        version_cmp_large_numbers_test,
        # == operator
        satisfies_eq_test,
        # != operator
        satisfies_neq_test,
        # >= operator
        satisfies_gte_test,
        # <= operator
        satisfies_lte_test,
        # > operator
        satisfies_gt_test,
        # < operator
        satisfies_lt_test,
        # ~= operator (2-segment)
        satisfies_compatible_two_segment_test,
        # ~= operator (3-segment)
        satisfies_compatible_three_segment_test,
        # ~= operator (4-segment)
        satisfies_compatible_four_segment_test,
        # ~= strictness comparison
        satisfies_compatible_vs_eq_star_test,
        # == with wildcards
        satisfies_wildcard_eq_test,
        # != with wildcards
        satisfies_wildcard_neq_test,
        # Compound: range
        satisfies_compound_range_test,
        # Compound: exclusion
        satisfies_compound_exclusion_test,
        # Compound: whitespace
        satisfies_compound_whitespace_test,
        # Compound: many clauses
        satisfies_compound_many_clauses_test,
        # === operator
        satisfies_arbitrary_eq_test,
        # Edge: single segment
        satisfies_single_segment_test,
        # Edge: zero versions
        satisfies_zero_versions_test,
        # Edge: calver
        satisfies_calver_test,
        # Real-world: numpy
        satisfies_real_world_numpy_test,
        # Real-world: django
        satisfies_real_world_django_test,
        # Real-world: requests
        satisfies_real_world_requests_test,
        # Real-world: protobuf (many exclusions)
        satisfies_real_world_protobuf_test,
        # Boundary precision
        satisfies_boundary_precision_test,
        # find_matching_version
        find_matching_version_exact_test,
        find_matching_version_range_test,
        find_matching_version_compatible_test,
        find_matching_version_gte_client_test,
        find_matching_version_compound_test,
        find_matching_version_empty_test,
        find_matching_version_single_test,
    )
