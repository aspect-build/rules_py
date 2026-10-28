# Python version project scoping

A Python binding and its build tools need the selected interpreter version; a
C++ or Rust library underneath the binding usually does not. Bazel's project
scope lets the root module name the packages that own the
`@aspect_rules_py//py:python_version` flag. Targets outside them see the version
given on the command line, so binaries transitioned to different Python versions
share one configuration of their Python-independent native dependencies.

Project scope is off by default, and only the root module can enable it. Tags in
dependency modules are ignored, so a library can use it in its own builds
without imposing a policy on its consumers. The setting is independent of
interpreter provisioning, so it also works with interpreters from other
rulesets.

```starlark
# MODULE.bazel
python_config = use_extension("@aspect_rules_py//py:config.bzl", "python_config")
python_config.python_version_scope(scope = "project")
```

`scope` accepts:

- `"project"`: the root module's `//:PROJECT.scl` decides which targets keep the
  version.
- `"universal"`: the version reaches every target, including exec tools.

Without the tag, the flag keeps Bazel's default scope. On Bazel 10, which
enables `--incompatible_exclude_starlark_flags_from_exec_config` by default,
that resets the version in exec configurations.

Project scope requires Bazel 9.2 or later. Older releases drop project-scoped
flags on exec transitions, so even owned exec tools would lose the version
([bazelbuild/bazel#28320](https://github.com/bazelbuild/bazel/issues/28320)).
The extension fails on older versions.

## Ownership

Under project scope, the version flag is an alias to a flag in rules_py's
generated configuration repository. That repository's `PROJECT.scl` forwards to
the root module's `//:PROJECT.scl` with Bazel's `actual` field, which may itself
redirect with `actual`. Without the tag nothing forwards there, so other builds
don't need a root `PROJECT.scl`. List every package that must see the selected
version in `active_directories`:

```starlark
# PROJECT.scl
project = {
    "active_directories": {
        "default": [
            "//bindings",
            "@@aspect_rules_py+",
            "@@rules_python+",
        ],
    },
}
```

Repositories are listed by canonical name. `bazel mod dump_repo_mapping ""`
prints the canonical names visible to the root module.

The example owns only `//bindings` and the two Python rulesets. A real project
must also own every other Python-sensitive target: interpreter and header
repositories, toolchains, version-sensitive generators, and any alias or
wrapper in between. Every dependency path from a transitioned target must stay
inside the owned packages until it reaches Python-independent code. Owned exec
tools keep the selected version. Bazel does not infer ownership from
dependencies and cannot detect an omitted consumer: such a target sees the
command-line version and can select the wrong interpreter.

## rules_python's version flag

rules_py terminals also set
`@rules_python//python/config_settings:python_version`. Unless that flag is
project-scoped as well, native dependencies still get one configuration per
Python version. If your rules_python version supports
`config.python_version_scope`, set it to `"project"` too; both flags then use
the same root `PROJECT.scl`.

## Command-line baseline

Pass a fixed `--@aspect_rules_py//py:python_version=<version>` and set
`python_version` on the binaries. Outside the owned packages, Bazel restores
that command-line value, not the flag's declared default. Invocations with
different command-line versions therefore still build native dependencies in
different configurations.

## Limitations

Only the Python version flag and rules_py's internal record of the version a
terminal inherited are scoped. ABI, platform, free-threading, build-script
environment, and other settings are unaffected.

See Bazel's
[project-scoped flags example](https://github.com/gregestren/snippets/tree/master/project_scoped_flags)
and the [configurability roadmap](https://bazel.build/about/roadmap#configurability).
