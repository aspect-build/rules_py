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

    /// Python version, eg 3.8.12
    /// Must be separated by dots.
    #[arg(long)]
    python_version: String,
}

fn unpack_cmd_handler(args: UnpackArgs) -> miette::Result<()> {
    py::unpack_wheel(&args.python_version, &args.into, &args.wheel)
}

fn main() -> miette::Result<()> {
    let args = UnpackArgs::parse();
    unpack_cmd_handler(args).wrap_err("Unable to run command:")
}
