use std::path::PathBuf;

use clap::Parser;

use miette::{Context, IntoDiagnostic};
use py;

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

    /// Path to the Python interpreter (required when --compile-pyc is set).
    #[arg(long)]
    python: Option<PathBuf>,
}

fn unpack_cmd_handler(args: UnpackArgs) -> miette::Result<()> {
    py::unpack_wheel(args.python_version_major, args.python_version_minor, &args.into, &args.wheel)?;

    // Apply patches if any were provided.
    if !args.patches.is_empty() {
        for patch_file in &args.patches {
            let status = std::process::Command::new(&args.patch_tool)
                .arg(format!("-p{}", args.patch_strip))
                .arg("-d")
                .arg(&args.into)
                .stdin(std::fs::File::open(patch_file).into_diagnostic()?)
                .status()
                .into_diagnostic()
                .wrap_err_with(|| format!("Failed to apply patch {}", patch_file.display()))?;

            if !status.success() {
                return Err(miette::miette!(
                    "patch failed with status {} for {}",
                    status,
                    patch_file.display()
                ));
            }
        }
    }

    // Optionally pre-compile .pyc bytecode.
    if args.compile_pyc {
        let python = args.python.as_deref().ok_or_else(|| {
            miette::miette!("--python is required when --compile-pyc is set")
        })?;

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
                "unchecked-hash",
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

fn main() -> miette::Result<()> {
    let args = UnpackArgs::parse();
    unpack_cmd_handler(args).wrap_err("Unable to run command:")
}
