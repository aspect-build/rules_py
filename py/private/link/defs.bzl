load("@bazel_skylib//lib:sets.bzl", "sets")

def py_link_venv(
    binary_rule,
    name,
    srcs,
    args = [],
    venv_name = None,
    venv_dest = None,
    **kwargs):
    """
    Build a Python virtual environment and produce a script to link it into the
    user's directory of choice.

    Args:
        binary_rule (rule): A py_binary-alike rule to employ. Must build a "venv".
    
        venv_name (str): A name to use for venv's link.
    
        venv_dest (str): A path (relative to the repo
            root/$BUILD_WORKING_DIRECTORY) where the link will be created.

        srcs (list): srcs for the underlying binary.

        args (list): args for the underlying binary.

        **kwargs (dict): Delegate args for the underlying binary rule.

    """

    # Note that the binary is already wrapped with debug
    link_script = str(Label("//py/private/link:link.py"))

    if venv_name != None:
        args = ["--name=" + venv_name] + args

    if venv_dest != None:
        args = ["--dest=" + venv_dest] + args
    
    binary_rule(
        name = name,
        args = args,
        main = link_script,
        srcs = sets.to_list(sets.make(srcs + [link_script])),
        **kwargs
    )
