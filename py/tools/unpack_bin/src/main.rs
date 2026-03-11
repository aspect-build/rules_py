use std::path::PathBuf;

use clap::Parser;

use miette::Context;
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

    /// Glob patterns for installed source files to remove after unpacking.
    #[arg(long = "srcs-exclude-glob")]
    srcs_exclude_glob: Vec<String>,

    /// Glob patterns for installed data files to remove after unpacking.
    #[arg(long = "data-exclude-glob")]
    data_exclude_glob: Vec<String>,
}

fn unpack_cmd_handler(args: UnpackArgs) -> miette::Result<()> {
    py::unpack_wheel(
        args.python_version_major,
        args.python_version_minor,
        &args.into,
        &args.wheel,
        &args.srcs_exclude_glob,
        &args.data_exclude_glob,
    )
}

fn main() -> miette::Result<()> {
    let args = UnpackArgs::parse();
    unpack_cmd_handler(args).wrap_err("Unable to run command:")
}
