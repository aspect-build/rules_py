"""One compile action emits both bytecode layouts of a source."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//py/private:pyc.bzl", "PycInfo")

def _pyc_layout_actions_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    producers = {}
    for action in analysistest.target_actions(env):
        for out in action.outputs.to_list():
            producers[out.short_path] = action

    asserts.false(
        env,
        "CopyFile" in [action.mnemonic for action in producers.values()],
        "colocated bytecode must not be copied through the coreutils toolchain",
    )

    entries = target[PycInfo].direct_entries
    asserts.true(env, len(entries) > 0, "target declares bytecode entries")
    for entry in entries:
        pycache_action = producers.get(entry.pycache.short_path)
        pyc_action = producers.get(entry.pyc.short_path)
        asserts.equals(
            env,
            "PyCompile",
            pycache_action.mnemonic if pycache_action else None,
            "__pycache__ producer for " + entry.source.short_path,
        )
        asserts.equals(
            env,
            "PyCompile",
            pyc_action.mnemonic if pyc_action else None,
            "colocated .pyc producer for " + entry.source.short_path,
        )
        asserts.true(
            env,
            pycache_action != None and pycache_action == pyc_action,
            "both layouts come from one action for " + entry.source.short_path,
        )
    return analysistest.end(env)

pyc_layout_actions_test = analysistest.make(_pyc_layout_actions_test_impl)
