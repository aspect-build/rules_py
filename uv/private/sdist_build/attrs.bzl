"""Helpers for classifying source-build attributes."""

def unsupported_build_attrs(
        resource_set,
        env,
        monitor_memory,
        pre_build_patches,
        pre_build_patch_strip,
        supported,
        toolchains):
    """Returns configured source-build attributes absent from `supported`.

    Args:
        resource_set: Resource set name, where "default" means unset.
        env: Environment variables for the wheel-build action.
        monitor_memory: Whether to monitor the wheel-build action's memory.
        pre_build_patches: Patches applied before building the wheel.
        pre_build_patch_strip: Strip count for pre-build patches.
        supported: Names of attributes consumed by the selected build path.
        toolchains: Toolchains used by the wheel-build action.

    Returns:
        A list of configured attribute names absent from `supported`.
    """
    active = []
    if resource_set != "default":
        active.append("resource_set")
    if env:
        active.append("env")
    if monitor_memory:
        active.append("monitor_memory")
    if pre_build_patches:
        active.append("pre_build_patches")
    if pre_build_patch_strip:
        active.append("pre_build_patch_strip")
    if toolchains:
        active.append("toolchains")
    return [name for name in active if name not in supported]
