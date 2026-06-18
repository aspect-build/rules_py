import os
import sysconfig


def test_runtime_imports():
    import azure.core
    import azure.identity
    import azure.core.tracing.ext.opentelemetry_span

    assert azure.core.__file__ is not None
    assert azure.identity.__file__ is not None


def test_sibling_entry_is_concrete_in_site_packages():
    site_packages = sysconfig.get_paths()["purelib"]

    azure_dir = os.path.join(site_packages, "azure")
    assert os.path.isdir(azure_dir), (
        f"site-packages has no concrete azure/ directory at {azure_dir}"
    )
    assert not os.path.exists(os.path.join(azure_dir, "__init__.py")), (
        "azure/ must stay a PEP 420 namespace: no __init__.py"
    )

    identity_dir = os.path.join(azure_dir, "identity")
    assert os.path.isdir(identity_dir), (
        f"site-packages/azure/identity/ is missing — sibling namespace entry "
        f"was omitted from the complete top-level merge. "
        f"azure/ holds: {sorted(os.listdir(azure_dir))}"
    )
    assert os.path.isfile(os.path.join(identity_dir, "__init__.py")), (
        f"azure/identity/__init__.py not found; "
        f"identity/ holds: {sorted(os.listdir(identity_dir))}"
    )


def test_conflicted_root_is_physically_merged():
    site_packages = sysconfig.get_paths()["purelib"]
    core_dir = os.path.join(site_packages, "azure", "core")
    assert os.path.isdir(core_dir), (
        f"site-packages/azure/core/ missing"
    )

    ext_dir = os.path.join(core_dir, "tracing", "ext", "opentelemetry_span")
    assert os.path.isdir(ext_dir), (
        f"azure/core/tracing/ext/opentelemetry_span/ not found — "
        f"PySiteMerge may not have run. "
        f"tracing/ holds: {sorted(os.listdir(os.path.join(core_dir, 'tracing')))}"
    )


if __name__ == "__main__":
    test_runtime_imports()
    test_sibling_entry_is_concrete_in_site_packages()
    test_conflicted_root_is_physically_merged()
    print("PASS")
