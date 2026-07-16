#!/bin/sh
case $0 in
    */*) script_dir=${0%/*} ;;
    *) script_dir=. ;;
esac
exec "${script_dir}/python" -c 'import sys; from importlib import import_module; from operator import attrgetter; sys.argv[0] = "{{name}}"; sys.exit(attrgetter("{{func}}")(import_module("{{module}}"))())' "$@"
