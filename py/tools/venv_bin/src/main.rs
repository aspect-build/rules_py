use std::path::PathBuf;

use clap::Parser;
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

#[derive(Parser, Debug)]
struct VenvArgs {
    /// Source Python interpreter path to symlink into the venv.
    #[arg(long)]
    python: PathBuf,

    /// Destination path of the venv.
    #[arg(long)]
    location: PathBuf,

    /// Path to a .pth file to add to the site-packages of the generated venv.
    #[arg(long)]
    pth_file: PathBuf,

    /// Prefix to append to each .pth path entry.
    #[arg(long)]
    pth_entry_prefix: Option<String>,

    /// The collision strategy to use when multiple packages providing the same file are
    /// encountered when creating the venv.
    /// If none is given, an error will be thrown.
    #[arg(long)]
    collision_strategy: Option<SymlinkCollisionStrategy>,

    /// Name to apply to the venv in the terminal when using
    /// activate scripts.
    #[arg(long)]
    venv_name: String,
}

fn venv_cmd_handler(args: VenvArgs) -> miette::Result<()> {
    let pth_file = py::PthFile::new(&args.pth_file, args.pth_entry_prefix);
    py::create_venv(
        &args.python,
        &args.location,
        Some(pth_file),
        args.collision_strategy.unwrap_or_default().into(),
        &args.venv_name,
    )
}

fn main() -> miette::Result<()> {
    let args = VenvArgs::parse();
    venv_cmd_handler(args).wrap_err("Unable to run command:")
}
