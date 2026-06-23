"""Analysis test for the action shape of a target."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _action_mnemonic_count_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == ctx.attr.mnemonic
    ]
    asserts.equals(
        env,
        ctx.attr.expected_count,
        len(actions),
        "expected {} {} actions, got {}".format(
            ctx.attr.expected_count,
            ctx.attr.mnemonic,
            len(actions),
        ),
    )
    return analysistest.end(env)

action_mnemonic_count_test = analysistest.make(
    _action_mnemonic_count_test_impl,
    attrs = {
        "expected_count": attr.int(mandatory = True),
        "mnemonic": attr.string(mandatory = True),
    },
)
