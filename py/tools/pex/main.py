import sys
from pex.common import Chroot
from pex.pex_builder import Check, CopyMode, PEXBuilder
from pex.interpreter import PythonInterpreter
from pex.layout import Layout
from pex.dist_metadata import Distribution
from argparse import Action, ArgumentParser

class InjectEnvAction(Action):
    def __call__(self, parser, namespace, value, option_str=None):
        components = value.split("=", 1)
        if len(components) != 2:
            raise ArgumentError(
                self,
                "Environment variable values must be of the form `name=value`. "
                "Given: {value}".format(value=value),
            )
        self.default.append(tuple(components))

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
    "--python",
    dest="python",
    required=True
)

parser.add_argument(
    "--python-shebang",
    dest="python_shebang",
    default=None,
    required=True,
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

parser.add_argument(
    "--inject-env",
    dest="inject_env",
    default=[],
    action=InjectEnvAction,
)

parser.add_argument(
    "--sys-path",
    dest="sys_path",
    default=[],
    action="append",
)

options = parser.parse_args(args = sys.argv[1:])

# Monkey patch bootstrap template to inject some templated environment variables.
# Unfortunately we can't use `preamble` feature because it runs before any initialization code.
import pex.pex_builder
BE=pex.pex_builder.BOOTSTRAP_ENVIRONMENT 

INJECT_TEMPLATE=["os.environ['RUNFILES_DIR'] = __entry_point__"]

for path in options.sys_path:
    INJECT_TEMPLATE.append("sys.path.append(os.path.abspath(os.path.join(__entry_point__, '%s')))" % path)

import_idx =  BE.index("from pex.pex_bootstrapper import bootstrap_pex")
# This is here to catch potential future bugs where pex package is updated here but the boostrap 
# script was not checked again to see if we are still injecting values in the right place.
assert import_idx == 3703, "Check bootstrap template monkey patching."

pex.pex_builder.BOOTSTRAP_ENVIRONMENT = BE[:import_idx] + "\n".join(INJECT_TEMPLATE) + "\n" + BE[import_idx:]


pex_builder = PEXBuilder(
    interpreter=PythonInterpreter.from_binary(options.python),
)


MAGIC_COMMENT = "# __PEX_PY_BINARY_ENTRYPOINT__ "
executable = None
executable_was_set = False
# set the entrypoint by looking at the generated launcher.
with open(options.executable, "r") as contents:
    line = contents.readline()
    while line:
        if line.startswith(MAGIC_COMMENT):
            executable = line[len(MAGIC_COMMENT):].rstrip()
        if executable:
            break
        line = contents.readline()

    if not executable:
        print("Could not determine the `main` file for the binary. Did run.tmpl.sh change?")
        sys.exit(1)
    
pex_builder.set_shebang(options.python_shebang)

pex_info = pex_builder.info
pex_info.inject_env = options.inject_env

for dep in options.dependencies:
    dist = Distribution.load(dep + "/../")

    # TODO: explain which level of inferno is this!
    dist_hash = pex_builder._add_dist(
        path=dist.location,
        dist_name = dist.key
    )
    pex_info.add_distribution(dist.key, dist_hash)
    pex_builder.add_requirement(dist.as_requirement())

for source in options.sources:
    src, dest = source.split("=", 1)

    # if destination path matches the entrypoint script, then also set the executable.
    if dest == executable:
        pex_builder.set_executable(src)
        executable_was_set = True

    pex_builder.add_source(
        src,
        dest
    )

if not executable_was_set:
    print("Have not seen the source that corresponds to %s in the runfiles. Please file an issue." % executable)
    sys.exit(1)

pex_builder.freeze(bytecode_compile=False)

pex_builder.build(
    options.pex_name,
    deterministic_timestamp=True,
    layout=Layout.ZIPAPP,
    check=Check.WARN,
)

