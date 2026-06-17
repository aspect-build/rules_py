#!/bin/sh
set -eu

if [ "${PYTHONHOME+x}" = x ] || [ "${PYTHONPLATLIBDIR+x}" = x ]; then
    echo "host Python path environment reached the build tool" >&2
    exit 1
fi
if [ "$1" = absent ]; then
    if [ "${PYTHONPATH+x}" = x ]; then
        echo "host PYTHONPATH reached the build tool" >&2
        exit 1
    fi
elif [ "${PYTHONPATH-}" != "$1" ]; then
    echo "explicit PYTHONPATH did not replace the host value" >&2
    exit 1
fi
if [ "${PYTHONSAFEPATH-}" != 1 ]; then
    echo "PYTHONSAFEPATH was unexpectedly removed" >&2
    exit 1
fi

# Native builds may insert compiler-driver flags before the two action paths;
# the wheel output directory remains the final argument.
for output_dir in "$@"; do :; done
mkdir -p "${output_dir}"
touch "${output_dir}/observed"
