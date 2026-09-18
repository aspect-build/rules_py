"""Which wheel ABI config_settings match a given interpreter configuration."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_PYTHON_VERSION = str(Label("//py/private/interpreter:python_version"))
_FREETHREADED = str(Label("//py/private/interpreter:freethreaded"))
_PYDEBUG = str(Label("//py/private/interpreter:pydebug"))

# Every ABI tag the fixture probes; the test asserts the exact subset that matches.
_PROBED_ABIS = [
    "cp311",
    "cp312",
    "cp313",
    "cp313d",
    "cp313t",
    "cp319",
    "cp320",
    "abi3",
    "abi3t",
]

_MatchesInfo = provider(fields = ["tags"])

def _matches_impl(ctx):
    return [_MatchesInfo(tags = ctx.attr.tags_matched)]

_matches = rule(
    implementation = _matches_impl,
    attrs = {"tags_matched": attr.string_list()},
)

def _abi_test_impl(ctx):
    env = analysistest.begin(ctx)
    actual = analysistest.target_under_test(env)[_MatchesInfo].tags
    asserts.equals(env, ctx.attr.expected, actual)
    return analysistest.end(env)

def _make(python_version, freethreaded = False, pydebug = False):
    return analysistest.make(
        _abi_test_impl,
        attrs = {"expected": attr.string_list()},
        config_settings = {
            _PYTHON_VERSION: python_version,
            _FREETHREADED: freethreaded,
            _PYDEBUG: pydebug,
        },
    )

_python312_test = _make("3.12")
_python313_test = _make("3.13")
_python313t_test = _make("3.13", freethreaded = True)
_python313d_test = _make("3.13", pydebug = True)
_python320_test = _make("3.20")

_CASES = [
    # (name, test rule, ABIs that must match, in _PROBED_ABIS order)
    ("python312", _python312_test, ["cp312", "abi3"]),
    ("python313", _python313_test, ["cp313", "abi3"]),
    # Free-threaded: the t ABI and the PEP 803 stable ABI, never the GIL ones.
    ("python313t", _python313t_test, ["cp313t", "abi3t"]),
    # Debug builds match only the d ABI; abi3 is independent of pydebug.
    ("python313d", _python313d_test, ["cp313d", "abi3"]),
    # The last minor in MINORS has no upper bound; the one before it still does.
    ("python320", _python320_test, ["cp320", "abi3"]),
]

def abi_test_suite(name):
    """Version-specific CPython ABIs match their interpreter minor only; abi3 stays forward-compatible."""
    tags_matched = []
    for abi in _PROBED_ABIS:
        tags_matched += select({
            "//uv/private/constraints/abi:" + abi: [abi],
            "//conditions:default": [],
        })
    _matches(
        name = name + "_matches",
        tags_matched = tags_matched,
    )
    tests = []
    for case, test_rule, expected in _CASES:
        test_rule(
            name = "{}_{}".format(name, case),
            expected = expected,
            target_under_test = ":" + name + "_matches",
        )
        tests.append("{}_{}".format(name, case))
    native.test_suite(
        name = name,
        tests = tests,
    )
