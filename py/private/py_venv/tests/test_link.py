#!/usr/bin/env python3

from link import munge_venv_name

assert munge_venv_name("", ".foo_venv") == ".foo_venv"
assert munge_venv_name("bar", ".foo_venv") == ".bar+foo_venv"
assert munge_venv_name("bar/baz", ".foo_venv") == ".bar+baz+foo_venv"
