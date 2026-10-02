"""Analysis tests for the type-check validation action."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

# Resolved here so the label is canonical by the time skylib's transition,
# defined in another repo, receives it.
_TYPE_CHECK = str(Label("//py/private/type_check:type_check"))

def _type_check_actions(env):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == "PyTypeCheck"]

def _checked_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = _type_check_actions(env)
    asserts.equals(env, 1, len(actions), "expected one PyTypeCheck action")
    if actions:
        argv = actions[0].argv
        for expected in ctx.attr.argv:
            asserts.true(env, expected in argv, "{} is missing from {}".format(expected, argv))
        for fragment in ctx.attr.argv_fragments:
            asserts.true(
                env,
                any([fragment in arg for arg in argv]),
                "no argument contains {}: {}".format(fragment, argv),
            )

        # Bazel merges the deps' validation outputs into the target's own.
        validation = target[OutputGroupInfo]._validation.to_list()
        for log in actions[0].outputs.to_list():
            asserts.true(env, log in validation, "{} is missing from _validation".format(log))
    return analysistest.end(env)

_CHECKED_ATTRS = {
    "argv": attr.string_list(doc = "Arguments the action must contain."),
    "argv_fragments": attr.string_list(doc = "Substrings some argument must contain."),
}

def _make_checked_test(config_settings = {}):
    return analysistest.make(
        _checked_test_impl,
        attrs = _CHECKED_ATTRS,
        config_settings = dict({_TYPE_CHECK: True}, **config_settings),
    )

checked_test = _make_checked_test()

# Swaps in the fake checker toolchain, which passes search paths through MYPYPATH.
env_checker_test = _make_checked_test({
    "//command_line_option:extra_toolchains": [str(Label("//py/tests/type-check:env_checker"))],
})

def _unchecked_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _type_check_actions(env), "expected no PyTypeCheck action")
    return analysistest.end(env)

unchecked_test = analysistest.make(
    _unchecked_test_impl,
    config_settings = {_TYPE_CHECK: True},
)

flag_off_test = analysistest.make(
    _unchecked_test_impl,
    config_settings = {_TYPE_CHECK: False},
)
