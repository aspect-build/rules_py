use std::{
    fs,
    path::{Path, PathBuf},
};

use miette::{Context, IntoDiagnostic};
use rattler_installs_packages::{
    artifacts::wheel::InstallPaths,
    python_env::{PythonInterpreterVersion, PythonLocation},
};

pub struct Interpreter {
    pub location: PythonLocation,
    pub version: PythonInterpreterVersion,
}

impl Interpreter {
    pub fn new(l: &Path, v: &str) -> miette::Result<Interpreter> {
        let location_abs_path = fs::canonicalize(l)
            .into_diagnostic()
            .wrap_err("Unable to determine absolute python interpreter path")?;

        let location = PythonLocation::Custom(location_abs_path);

        let python = format!("Python {}", v);
        let version = PythonInterpreterVersion::from_python_output(&python)
            .into_diagnostic()
            .wrap_err("Failed to determine Python interpreter version")?;

        Ok(Self { location, version })
    }

    pub fn executable(&self) -> miette::Result<PathBuf> {
        self.location
            .executable()
            .into_diagnostic()
            .wrap_err("Unable to find Python interpreter at given path")
    }

    pub fn install_paths(&self, windows: bool) -> InstallPaths {
        InstallPaths::for_venv(self.version.clone(), windows)
    }
}
