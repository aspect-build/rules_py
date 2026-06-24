"""Helpers for validating source-build attributes."""

def validate_build_attrs(
        console_scripts,
        resource_set,
        env,
        monitor_memory,
        pre_build_patches,
        pre_build_patch_strip,
        supported,
        toolchains,
        error):
    """Fails when a configured source-build attribute is unsupported.

    Args:
        console_scripts: Additional entry points generated for a source build.
        resource_set: Resource set name, where "default" means unset.
        env: Environment variables for the wheel-build action.
        monitor_memory: Whether to monitor the wheel-build action's memory.
        pre_build_patches: Patches applied before building the wheel.
        pre_build_patch_strip: Strip count for pre-build patches.
        supported: Names of attributes consumed by the selected build path.
        toolchains: Toolchains used by the wheel-build action.
        error: Failure message with one `{}` slot for unsupported names.
    """
    active = []
    if console_scripts:
        active.append("console_scripts")
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
    unsupported = [name for name in active if name not in supported]
    if unsupported:
        fail(error.format(", ".join(unsupported)))
