use std::path::Path;

use miette::{miette, IntoDiagnostic, Result};
use rattler_installs_packages::{
    artifacts::wheel::UnpackWheelOptions, artifacts::Wheel, types::PackageName,
};

use crate::Interpreter;

pub fn unpack_wheel(
    python: &Path,
    version: &str,
    location: &Path,
    pkg_name: &str,
    wheel: &Path,
) -> Result<()> {
    let interpreter = Interpreter::new(python, version)?;
    let python_executable = interpreter.executable()?;
    let install_paths = interpreter.install_paths(false);

    let unpack_options = UnpackWheelOptions {
        installer: Some("Aspect Build rules_py".to_string()),
        // launcher_arch:
        ..UnpackWheelOptions::default()
    };

    let package_name: PackageName = pkg_name.parse().unwrap();
    let wheel = Wheel::from_path(wheel, &package_name.into())
        .map_err(|_| miette!("Failed to create wheel from path"))?;

    wheel
        .unpack(
            &location,
            &install_paths,
            &python_executable,
            &unpack_options,
        )
        .into_diagnostic()?;

    Ok(())
}
