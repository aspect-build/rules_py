"""Action-level PBS venv regression target."""

load("@aspect_rules_py//py:defs.bzl", "py_binary")

def pbs_action_probe(name, python_version):
    """Run a PBS-backed binary from a non-runfiles action cwd."""
    py_binary(
        name = name,
        srcs = ["test_pbs_prefix.py"],
        expose_venv = True,
        main = "test_pbs_prefix.py",
        python_version = python_version,
    )

    commands = [
        "root=$$(pwd)",
        "mkdir -p $(@D)/cwd",
        "cd $(@D)/cwd",
        (
            "\"$$root/$(execpath :{name})\" " +
            "--expected-cwd \"$$PWD\" --test-children"
        ).format(name = name),
        (
            "\"$$root/$(execpath :{name}.venv)\" " +
            "\"$$root/$(location test_pbs_prefix.py)\" " +
            "--expected-cwd \"$$PWD\""
        ).format(name = name),
        "touch \"$$root/$@\"",
    ]

    native.genrule(
        name = name + "_output",
        srcs = ["test_pbs_prefix.py"],
        outs = [name + ".stamp"],
        cmd = "\n".join(commands),
        tools = [
            ":" + name,
            ":" + name + ".venv",
        ],
    )

def pbs_pyvenv_cfg_snapshot(name, venv):
    """Copy a PBS-backed py_venv's generated pyvenv.cfg from its runfiles."""
    native.genrule(
        name = name,
        testonly = True,
        outs = [name],
        cmd = """
            launcher=$(execpath {venv})
            runfiles="$$launcher".runfiles
            pkg=$$(dirname "$$launcher" | sed 's|^bazel-out/[^/]*/bin/||')
            vname=$$(basename "$$launcher")
            cfg="$$runfiles/_main/$$pkg/.$$vname/pyvenv.cfg"
            if [ ! -f "$$cfg" ]; then
                echo "expected pyvenv.cfg at $$cfg, not found" >&2
                ls -la "$$runfiles/_main/$$pkg/" 2>&1 >&2
                exit 1
            fi
            # PBS interpreter repository names include the host OS and CPU.
            # Keep the `home` line while removing only that volatile value.
            sed -E 's|^home = .+|home = <PBS_INTERPRETER_HOME>|' "$$cfg" > $@
        """.format(venv = venv),
        tools = [venv],
        visibility = ["//:__pkg__"],
    )
