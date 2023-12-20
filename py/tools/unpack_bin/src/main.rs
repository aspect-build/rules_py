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

    /// The package name of the wheel to unpack.
    #[arg(long)]
    package_name: String,

    /// Python interpreter to do something with.
    #[arg(long)]
    python: PathBuf,

    /// Python version, eg 3.8.12
    /// Must be seperated by dots.
    #[arg(long)]
    python_version: String,
}

fn unpack_cmd_handler(args: UnpackArgs) -> miette::Result<()> {
    py::unpack_wheel(
        &args.python,
        &args.python_version,
        &args.into,
        &args.package_name,
        &args.wheel,
    )
}

fn main() -> miette::Result<()> {
    let args = UnpackArgs::parse();
    unpack_cmd_handler(args).wrap_err("Unable to run command:")
}
