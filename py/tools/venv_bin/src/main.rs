use std::path::PathBuf;

use clap::Parser;
use miette::miette;
use miette::Context;
use py;

#[derive(clap::ValueEnum, Clone, Debug, Default)]
enum SymlinkCollisionStrategy {
    #[default]
    Error,
    Warning,
    Ignore,
}

impl Into<py::SymlinkCollisionResolutionStrategy> for SymlinkCollisionStrategy {
    fn into(self) -> py::SymlinkCollisionResolutionStrategy {
        match self {
            SymlinkCollisionStrategy::Error => py::SymlinkCollisionResolutionStrategy::Error,
            SymlinkCollisionStrategy::Warning => {
                py::SymlinkCollisionResolutionStrategy::LastWins(true)
            }
            SymlinkCollisionStrategy::Ignore => {
                py::SymlinkCollisionResolutionStrategy::LastWins(false)
            }
        }
    }
}

#[derive(clap::ValueEnum, Clone, Default, Debug)]
enum VenvMode {
    #[default]
    DynamicSymlink,
    StaticCopy,
    StaticPth,
}

#[derive(Parser, Debug)]
struct VenvArgs {
    /// Source Python interpreter path to symlink into the venv.
    #[arg(long)]
    python: PathBuf,

    /// A shim we may want to use in place of the interpreter
    #[arg(long)]
    venv_shim: Option<PathBuf>,

    /// Destination path of the venv.
    #[arg(long)]
    location: PathBuf,

    /// Path to a .pth file to add to the site-packages of the generated venv.
    #[arg(long)]
    pth_file: PathBuf,

    #[arg(long)]
    env_file: Option<PathBuf>,

    /// Prefix to append to each .pth path entry.
    /// FIXME: Get rid of this
    #[arg(long)]
    pth_entry_prefix: Option<String>,

    #[arg(long)]
    bin_dir: Option<PathBuf>,

    /// The collision strategy to use when multiple packages providing the same file are
    /// encountered when creating the venv.
    /// If none is given, an error will be thrown.
    #[arg(long)]
    collision_strategy: Option<SymlinkCollisionStrategy>,

    /// Name to apply to the venv in the terminal when using
    /// activate scripts.
    #[arg(long)]
    venv_name: String,

    /// The mechanism to use in building a virtualenv. Could be static, could be
    /// dynamic. Allows us to use the same tool statically as dynamically, which
    /// may or may not be a feature.
    #[arg(long)]
    #[clap(default_value = "dynamic-symlink")]
    mode: VenvMode,

    /// The interpreter version. Must be supplied because there are parts of the
    /// venv whose path depend on the precise interpreter version. To be sourced from
    /// PyRuntimeInfo.
    #[arg(long)]
    version: Option<String>,

    #[arg(long, default_value_t = false)]
    debug: bool,
}

fn venv_cmd_handler(args: VenvArgs) -> miette::Result<()> {
    let pth_file = py::PthFile::new(&args.pth_file, args.pth_entry_prefix);
    match args.mode {
        VenvMode::DynamicSymlink => py::create_venv(
            &args.python,
            &args.location,
            Some(pth_file),
            args.collision_strategy.unwrap_or_default().into(),
            &args.venv_name,
        ),

        VenvMode::StaticCopy => {
            let Some(version) = args.version else {
                return Err(miette!("Version must be provided for static venv modes"));
            };

            let venv = py::venv::create_empty_venv(
                &args.python,
                py::venv::PythonVersionInfo::from_str(&version)?,
                &args.location,
                &args.env_file,
                &args.venv_shim,
                args.debug,
            )?;

            py::venv::populate_venv_with_copies(
                venv,
                pth_file,
                args.bin_dir.unwrap(),
                args.collision_strategy.unwrap_or_default().into(),
            )?;

            Ok(())
        }

        VenvMode::StaticPth => {
            let Some(version) = args.version else {
                return Err(miette!("Version must be provided for static venv modes"));
            };

            let venv = py::venv::create_empty_venv(
                &args.python,
                py::venv::PythonVersionInfo::from_str(&version)?,
                &args.location,
                &args.env_file,
                &args.venv_shim,
                args.debug,
            )?;

            py::venv::populate_venv_with_pth(
                venv,
                pth_file,
                args.bin_dir.unwrap(),
                args.collision_strategy.unwrap_or_default().into(),
            )?;

            Ok(())
        }
    }
}

fn main() -> miette::Result<()> {
    let args = VenvArgs::parse();
    venv_cmd_handler(args).wrap_err("Unable to run command:")
}
