load("@aspect_bazel_lib//lib:run_binary.bzl", "run_binary")
load("@aspect_bazel_lib//lib:write_source_files.bzl", "write_source_file")

def pip_compile(name, requirements_in, requirements_lock):
    requirements_out = "_{}.out".format(requirements_in)

    # py_venv(name = "_{}.venv".format(name))

    # run_binary(
    #     name = "_{}.create_venv".format(name),
    #     tool = "_{}.venv".format(name),
    #     env = {"BUILD_WORKSPACE_DIRECTORY": "."},
    #     out_dirs = ["._requirements.venv"],
    # )

    # copy_to_directory(
    #     name = "_{}.venv".format(name),
    #     include_external_repositories = ["*"],
    #     srcs = [INTERPRETER_LABELS["python_3_11"]],
    #     #replace_prefixes = {"": "bin/"},
    # )

    run_binary(
        name = "_{}.run_uv".format(name),
        args = [
            "pip",
            "compile",
            "-o",
            requirements_out,
            requirements_in,
        ],
        env = {
            "VIRTUAL_ENV": "._requirements.venv",  #"$(execpath _{}.venv)/bin".format(name),
        },
        outs = [requirements_out],
        srcs = [
            requirements_in,
            #"_{}.venv".format(name),
        ],
        # The tool to run in the action
        tool = "@multitool//tools/uv",
    )

    write_source_file(
        name = name,
        in_file = requirements_out,
        out_file = requirements_lock,
    )
