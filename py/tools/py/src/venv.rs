use std::{
    fs::{self},
    path::Path,
};

use miette::{Context, IntoDiagnostic};
use rattler_installs_packages::python_env::VEnv;

use crate::{Interpreter, PthFile};

pub fn create_venv(
    python: &Path,
    version: &str,
    location: &Path,
    pth_file: Option<PthFile>,
) -> miette::Result<()> {
    // Parse and find the interpreter to use.
    // Do this first so that incase we can't find or parse the version, we don't
    // remove an existing venv.
    let interpreter = Interpreter::new(python, version)?;

    if location.exists() {
        // Clear down the an old venv if there is one present.
        fs::remove_dir_all(location)
            .into_diagnostic()
            .wrap_err("Unable to remove venv_root directory")?;
    }

    // Create all the dirs down to the venv base
    fs::create_dir_all(location)
        .into_diagnostic()
        .wrap_err("Unable to create base venv directory")?;

    let venv_location = fs::canonicalize(location)
        .into_diagnostic()
        .wrap_err("Unable to determine absolute directory to venv directory")?;

    let install_paths = interpreter.install_paths(false);

    VEnv::create_install_paths(&venv_location, &install_paths)
        .into_diagnostic()
        .wrap_err("Unable to remove create install paths")?;

    let python_path = interpreter.executable()?;
    let python_exe_file_name = python_path.file_name().expect("file should have a name");
    let venv_exe_path = venv_location.join(install_paths.scripts().join(python_exe_file_name));

    VEnv::create_pyvenv(&venv_location, &python_path, interpreter.version.clone())
        .into_diagnostic()?;
    VEnv::setup_python(&venv_exe_path, &python_path, interpreter.version.clone())
        .into_diagnostic()?;

    if let Some(pth) = pth_file {
        pth.set_up_site_packages(&venv_location.join(install_paths.platlib()))?
    }

    Ok(())
}
