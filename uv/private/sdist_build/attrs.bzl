"""Helpers for classifying source-build attributes."""

def unsupported_build_attrs(
        build_tool_env,
        build_tools,
        resource_set,
        env,
        monitor_memory,
        path_env,
        pre_build_patches,
        pre_build_patch_strip,
        supported):
    """Returns configured source-build attributes absent from `supported`.

    Args:
        build_tool_env: Direct build-tool environment assignments.
        build_tools: Build-tool targets used by the wheel-build action.
        resource_set: Resource set name, where "default" means unset.
        env: Environment variables for the wheel-build action.
        monitor_memory: Whether to monitor the wheel-build action's memory.
        path_env: Path-valued environment variables for the wheel-build action.
        pre_build_patches: Patches applied before building the wheel.
        pre_build_patch_strip: Strip count for pre-build patches.
        supported: Names of attributes consumed by the selected build path.

    Returns:
        A list of configured attribute names absent from `supported`.
    """
    active = []
    if build_tool_env:
        active.append("build_tool_env")
    if build_tools:
        active.append("build_tools")
    if resource_set != "default":
        active.append("resource_set")
    if env:
        active.append("env")
    if monitor_memory:
        active.append("monitor_memory")
    if path_env:
        active.append("path_env")
    if pre_build_patches:
        active.append("pre_build_patches")
    if pre_build_patch_strip:
        active.append("pre_build_patch_strip")
    return [name for name in active if name not in supported]
