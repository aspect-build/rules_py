use std::path::PathBuf;

use clap::ArgAction;
use clap::Parser;
use miette::miette;
use miette::Context;
use py;

#[derive(clap::ValueEnum, Clone, Debug, Default)]
enum CollisionStrategy {
    #[default]
    Error,
    Warning,
    Ignore,
}

impl Into<py::CollisionResolutionStrategy> for CollisionStrategy {
    fn into(self) -> py::CollisionResolutionStrategy {
        match self {
            CollisionStrategy::Error => py::CollisionResolutionStrategy::Error,
            CollisionStrategy::Warning => py::CollisionResolutionStrategy::LastWins(true),
            CollisionStrategy::Ignore => py::CollisionResolutionStrategy::LastWins(false),
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
    /// The current workspace name
    #[arg(long)]
    repo: Option<String>,

    /// Source Bazel target of the Python interpreter.
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
    collision_strategy: Option<CollisionStrategy>,

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

    #[clap(
        long,
        default_missing_value("false"),
        default_value("false"),
        num_args(0..=1),
        require_equals(true),
        action = ArgAction::Set,
    )]
    include_system_site_packages: bool,

    #[clap(
        long,
        default_missing_value("false"),
        default_value("false"),
        num_args(0..=1),
        require_equals(true),
        action = ArgAction::Set,
    )]
    include_user_site_packages: bool,
}

fn venv_cmd_handler(args: VenvArgs) -> miette::Result<()> {
    let pth_file = py::PthFile::new(&args.pth_file, args.pth_entry_prefix);
    match args.mode {
        // FIXME: Does this need to care about the repo?
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

            let repo = args
                .repo
                .as_deref()
                .expect("The --repo argument is required for static venvs!");

            let venv = py::venv::create_empty_venv(
                repo,
                &args.python,
                py::venv::PythonVersionInfo::from_str(&version)?,
                &args.location,
                args.env_file.as_deref(),
                args.venv_shim.as_deref(),
                args.debug,
                args.include_system_site_packages,
                args.include_user_site_packages,
            )?;

            py::venv::populate_venv_with_copies(
                repo,
                venv,
                pth_file,
                args.bin_dir.unwrap(),
                args.collision_strategy.unwrap_or_default().into(),
            )?;

            Ok(())
        }

        // FIXME: Not fully implemented yet
        VenvMode::StaticPth => {
            let Some(version) = args.version else {
                return Err(miette!("Version must be provided for static venv modes"));
            };

            let repo = args
                .repo
                .as_deref()
                .expect("The --repo argument is required for static venvs!");

            let venv = py::venv::create_empty_venv(
                repo,
                &args.python,
                py::venv::PythonVersionInfo::from_str(&version)?,
                &args.location,
                args.env_file.as_deref(),
                args.venv_shim.as_deref(),
                args.debug,
                args.include_system_site_packages,
                args.include_user_site_packages,
            )?;

            py::venv::populate_venv_with_pth(
                repo,
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
