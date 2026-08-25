import docopt
import setuptools

assert docopt.__version__ == "0.6.2", docopt.__version__

# The 3.11 interpreter must select the python_full_version < '3.12' fork.
assert setuptools.__version__ == "75.8.2", setuptools.__version__
