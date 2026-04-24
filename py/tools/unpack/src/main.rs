//! Installs a single wheel into `<into>/lib/python<M>.<m>/site-packages/`
//! (and `bin/`, `lib/include/` per PEP 427's `<dist>.data/` routing),
//! then optionally applies patches and pre-compiles `.pyc` bytecode.

use std::{
    fs,
    path::{Path, PathBuf},
    str::FromStr,
};

use clap::Parser;
use itertools::Itertools;
use miette::{miette, Context, IntoDiagnostic, Result};
use percent_encoding::percent_decode_str;

/// Shebang stamped on any `<dist>.data/scripts/` file whose original
/// shebang starts with `#!python`. Resolves `bin/python` via
/// `realpath(argv[0])` so the script finds its sibling interpreter
/// regardless of where the venv ends up on disk.
const RELOCATABLE_SHEBANG: &'static str = r#"/bin/sh
'''exec' "$(dirname -- "$(realpath -- "$0")")"/'python3' "$0" "$@"
' '''
"#;

fn unpack_wheel(
    version_major: u8,
    version_minor: u8,
    location: &Path,
    wheel: &Path,
) -> Result<()> {
    // `wheel` may be a direct .whl file or a directory containing
    // exactly one .whl (the shape http_file produces).
    let wheel = if wheel.is_file() {
        wheel.to_owned()
    } else {
        fs::read_dir(wheel)
            .into_diagnostic()?
            .filter_map(|res| res.ok())
            .map(|dir_entry| dir_entry.path())
            .filter_map(|path| {
                if path.extension().map_or(false, |ext| ext == "whl") {
                    Some(path)
                } else {
                    None
                }
            })
            .exactly_one()
            .into_diagnostic()
            .wrap_err_with(|| "Didn't find exactly one wheel file to install!")?
    };
    let wheel_file_reader = fs::File::open(&wheel).into_diagnostic()?;

    let temp = tempfile::tempdir().into_diagnostic()?;

    let _ = uv_extract::unzip(wheel_file_reader, temp.path()).into_diagnostic()?;

    let site_packages_dir = location
        .join("lib")
        .join(format!("python{}.{}", version_major, version_minor))
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
        sys_executable: PathBuf::from(RELOCATABLE_SHEBANG),
        python_version: (version_major, version_minor),
        // Don't stamp in the path to the interpreter into the generated
        // bins — we don't want an absolute path here.
        os_name: "".to_string(),
        scheme,
    };

    let filename = wheel
        .file_name()
        .and_then(|f| f.to_str())
        .expect("Expected to get filename from wheel path");
    let filename = percent_decode_str(filename).decode_utf8_lossy();
    let wheel_file_name =
        uv_distribution_filename::WheelFilename::from_str(&filename).into_diagnostic()?;

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

#[derive(Debug, Parser)]
struct UnpackArgs {
    /// The directory into which the wheel should be unpacked.
    #[arg(long)]
    into: PathBuf,

    /// The wheel file to unpack.
    #[arg(long)]
    wheel: PathBuf,

    /// Python version, eg 3.8.12 => major = 3, minor = 8
    #[arg(long)]
    python_version_major: u8,
    #[arg(long)]
    python_version_minor: u8,

    /// Patch files to apply after unpacking, in order.
    #[arg(long = "patch")]
    patches: Vec<PathBuf>,

    /// Strip count for patch files (-p flag).
    #[arg(long, default_value_t = 0)]
    patch_strip: u32,

    /// Path to the patch tool binary (defaults to "patch" on PATH).
    #[arg(long, default_value = "patch")]
    patch_tool: PathBuf,

    /// Pre-compile .pyc bytecode after unpacking (and patching).
    #[arg(long, default_value_t = false)]
    compile_pyc: bool,

    /// PEP 552 invalidation mode for .pyc files.
    /// One of: checked-hash, unchecked-hash, timestamp.
    #[arg(long, default_value = "checked-hash")]
    pyc_invalidation_mode: String,

    /// Path to the Python interpreter (required when --compile-pyc is set).
    #[arg(long)]
    python: Option<PathBuf>,
}

fn unpack_cmd_handler(args: UnpackArgs) -> Result<()> {
    unpack_wheel(
        args.python_version_major,
        args.python_version_minor,
        &args.into,
        &args.wheel,
    )?;

    // Apply patches if any were provided.
    if !args.patches.is_empty() {
        for patch_file in &args.patches {
            let status = std::process::Command::new(&args.patch_tool)
                .arg(format!("-p{}", args.patch_strip))
                .arg("-d")
                .arg(&args.into)
                .stdin(fs::File::open(patch_file).into_diagnostic()?)
                .status()
                .into_diagnostic()
                .wrap_err_with(|| format!("Failed to apply patch {}", patch_file.display()))?;

            if !status.success() {
                return Err(miette!(
                    "patch failed with status {} for {}",
                    status,
                    patch_file.display()
                ));
            }
        }
    }

    // Optionally pre-compile .pyc bytecode.
    if args.compile_pyc {
        let python = args
            .python
            .as_deref()
            .ok_or_else(|| miette!("--python is required when --compile-pyc is set"))?;

        let site_packages = args
            .into
            .join("lib")
            .join(format!(
                "python{}.{}",
                args.python_version_major, args.python_version_minor
            ))
            .join("site-packages");

        let status = std::process::Command::new(python)
            .args([
                "-m",
                "compileall",
                "-q",
                "--invalidation-mode",
                &args.pyc_invalidation_mode,
            ])
            .arg(&site_packages)
            .status()
            .into_diagnostic()
            .wrap_err("Failed to launch compileall")?;

        if !status.success() {
            eprintln!(
                "WARNING: compileall exited with status {} for {} (non-fatal)",
                status,
                site_packages.display()
            );
        }
    }

    Ok(())
}

fn main() -> Result<()> {
    let args = UnpackArgs::parse();
    unpack_cmd_handler(args).wrap_err("Unable to run command:")
}
