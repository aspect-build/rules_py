# Django application with rules_py

This is a minimal example of using Django with rules_py. It relies on the hermetic Python 3.9 interpreter
from rules_python and uses `pip_parse` to fetch PyPi dependencies.

This demo shows the interaction of external wheels, as well as the ability to create a simple Python virtual environment
for running locally from the command line or from with an IDE.

To start the interactive shell, at the root of this workspace:

```bash
$ bazel run django
```

A Python virtual environment can be created that is suitable for IDE consumption. IDEs such as VSCode and PyCharm can be
configured to use this local venv, therefore using the bazel managed interpreter, pip and fetched PyPi packages.

To create the venv, run the following:

```bash
$ bazel run django.venv
```

This will create a venv at the root of the workspace ready for IDE configuration.
