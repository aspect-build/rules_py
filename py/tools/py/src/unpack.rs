use std::{
    fs,
    path::{Path, PathBuf},
    str::FromStr,
};

use miette::{miette, IntoDiagnostic, Result};

pub fn unpack_wheel(version: &str, location: &Path, wheel: &Path) -> Result<()> {
    let python_version: uv_python::PythonVersion = version
        .parse()
        .map_err(|_| miette!("Failed to parse Python version"))?;

    let wheel_file_reader = fs::File::open(wheel).into_diagnostic()?;

    let temp = tempfile::tempdir().into_diagnostic()?;

    let _ = uv_extract::unzip(wheel_file_reader, temp.path()).into_diagnostic()?;

    let site_packages_dir = location
        .join("lib")
        .join(format!(
            "python{}.{}",
            python_version.major(),
            python_version.minor()
        ))
        .join("site-packages");

    let scheme = uv_pypi_types::Scheme {
        purelib: site_packages_dir.to_path_buf(),
        platlib: site_packages_dir.to_path_buf(),
        // No windows support.
        scripts: location.join("bin"),
        data: site_packages_dir.to_path_buf(),
        include: location.join("lib").join("include"),
    };

    let layout = uv_install_wheel::Layout {
        sys_executable: PathBuf::new(),
        python_version: (python_version.major(), python_version.minor()),
        // Don't stamp in the path to the interpreter into the generated bins
        // as we don't want an absolute path here.
        // Perhaps this should be set to just "python" so it picks up the one in the venv path?
        os_name: "/bin/false".to_string(),
        scheme,
    };

    let filename = wheel
        .file_name()
        .and_then(|f| f.to_str())
        .expect("Exepected to get filename from wheel path");
    let wheel_file_name =
        uv_distribution_filename::WheelFilename::from_str(filename).into_diagnostic()?;

    uv_install_wheel::linker::install_wheel(
        &layout,
        false,
        temp.path(),
        &wheel_file_name,
        None,
        None,
        Some("aspect_rule_py"),
        uv_install_wheel::linker::LinkMode::Copy,
        &uv_install_wheel::linker::Locks::default(),
    )
    .into_diagnostic()?;

    Ok(())
}
