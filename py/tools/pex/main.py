import sys
import os
from pex.common import safe_mkdtemp
from pex.pex import PEX
from pex.pex_builder import Check, CopyMode, PEXBuilder
from pex.pex_info import PexInfo
from pex.interpreter import PythonInterpreter
from pex.layout import Layout
from pex.dist_metadata import Distribution
from argparse import Action, ArgumentParser

parser = ArgumentParser()

parser.add_argument(
    "-o",
    "--output-file",
    dest="pex_name",
    default=None,
    help="The name of the generated .pex file: Omitting this will run PEX "
    "immediately and not save it to a file.",
)

parser.add_argument(
    "--python-shebang",
    dest="python_shebang",
    default=None,
    help="The exact shebang (#!...) line to add at the top of the PEX file minus the "
    "#!. This overrides the default behavior, which picks an environment Python "
    "interpreter compatible with the one used to build the PEX file.",
)

parser.add_argument(
    "--executable",
    dest="executable",
    default=None,
    metavar="EXECUTABLE",
    help=(
        "Set the entry point to an existing local python script. For example: "
        '"pex --executable bin/my-python-script".'
    ),
)

parser.add_argument(
    "--dependency",
    dest="dependencies",
    default=[],
    action="append",
)

parser.add_argument(
    "--distinfo",
    dest="distinfos",
    default=[],
    action="append",
)

parser.add_argument(
    "--source",
    dest="sources",
    default=[],
    action="append",
)


options = parser.parse_args(args = sys.argv[1:])

pex_builder = PEXBuilder(
    path=safe_mkdtemp(),
    interpreter=PythonInterpreter.get(),
    preamble=None,
    copy_mode=CopyMode.SYMLINK,
)

pex_builder.set_executable(options.executable)
pex_builder.set_shebang(options.python_shebang)


for dep in options.dependencies:
    dist = Distribution.load(dep + "/../")

    # TODO: explain which level of inferno is this!
    dist_hash = pex_builder._add_dist(
        path=dist.location,
        dist_name = dist.key
    )
    pex_builder._pex_info.add_distribution(dist.key, dist_hash)
    pex_builder.add_requirement(dist.as_requirement())

for source in options.sources:
    src, dest = source.split("=", 1)

    pex_builder.add_source(
        src,
        dest
    )

pex_builder.freeze(bytecode_compile=False)
interpreter = pex_builder.interpreter
pex = PEX(
    pex_builder.path(),
    interpreter=interpreter,
    verify_entry_point=False,
)

pex_builder.build(
    options.pex_name,
    bytecode_compile=False,
    deterministic_timestamp=True,
    layout=Layout.ZIPAPP,
    compress=False,
    check=Check.WARN,
)