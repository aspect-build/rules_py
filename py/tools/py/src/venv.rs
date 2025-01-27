use std::{
    fs::{self},
    path::Path,
};

use miette::{Context, IntoDiagnostic};

use crate::{
    pth::{SitePackageOptions, SymlinkCollisionResolutionStrategy},
    PthFile,
};

pub fn create_venv(
    python: &Path,
    location: &Path,
    pth_file: Option<PthFile>,
    collision_strategy: SymlinkCollisionResolutionStrategy,
    venv_name: &str,
) -> miette::Result<()> {
    if location.exists() {
        // With readOnlyRootFilesystem (k8s), we mount a writable volume here with an empty directory.
        // In that case, we cannot delete that directory.
        let is_empty = location.read_dir()?.next().is_none();
        if !is_empty {
            // Clear down the an old venv if there is one present.
            fs::remove_dir_all(location)
                .into_diagnostic()
                .wrap_err("Unable to remove venv_root directory")?;
        }
    }

    // Create all the dirs down to the venv base
    fs::create_dir_all(location)
        .into_diagnostic()
        .wrap_err("Unable to create base venv directory")?;

    let venv_location = fs::canonicalize(location)
        .into_diagnostic()
        .wrap_err("Unable to determine absolute directory to venv directory")?;

    // Need a way of providing our own cache here that drops, we leave the caching up to
    // bazel.
    // The temp dir will be cleaned up when the cache goes out of scope.
    let cache = uv_cache::Cache::temp().into_diagnostic()?;

    let interpreter = uv_python::Interpreter::query(&python, &cache).into_diagnostic()?;

    let venv = uv_virtualenv::create_venv(
        &venv_location,
        interpreter,
        uv_virtualenv::Prompt::Static(venv_name.to_string()),
        false,
        false,
        false,
        false,
    )
    .into_diagnostic()?;

    if let Some(pth) = pth_file {
        let site_package_path = venv
            .site_packages()
            .nth(0)
            .expect("Should have a site-packages directory");

        let site_packages_options = SitePackageOptions {
            dest: venv_location.join(site_package_path),
            collision_strategy,
        };

        pth.set_up_site_packages(site_packages_options)?
    }

    Ok(())
}
