#!/usr/bin/env bash
set -euo pipefail

awk_script="$1"
gawk="$2"

run_case() {
    local name="$1"
    local expected="$2"
    local input="$3"
    local diagnostic="${4:-py_image_layer runfile collision at ./generated_tree/support.py:}"
    local output="$TEST_TMPDIR/$name.out"
    local error="$TEST_TMPDIR/$name.err"

    if "$gawk" -v "outfile=$output" -f "$awk_script" <<<"$input" 2>"$error"; then
        if [[ "$expected" != pass ]]; then
            echo "$name: expected collision failure" >&2
            exit 1
        fi
    elif [[ "$expected" != fail ]]; then
        echo "$name: unexpected failure" >&2
        sed -n '1,80p' "$error" >&2
        exit 1
    fi

    if [[ "$expected" == fail ]] && ! grep -Fq "$diagnostic" "$error"; then
        echo "$name: missing collision diagnostic" >&2
        sed -n '1,80p' "$error" >&2
        exit 1
    fi
}

run_case disjoint pass $'#mtree\n./generated_tree/first.py type=file contents=first\n./generated_tree/second.py type=file contents=second'
run_case ampersand_destination pass $'#mtree\n./assets/nested/../a&b.txt  type=file mode=0644 contents=asset'
grep -Fxq './assets/a&b.txt  type=file mode=0644 contents=asset' "$TEST_TMPDIR/ampersand_destination.out"
run_case identical pass $'#mtree\n./generated_tree/support.py type=file contents=same\n./generated_tree/support.py type=file contents=same'
[[ $(grep -Fc './generated_tree/support.py ' "$TEST_TMPDIR/identical.out") == 1 ]]
run_case conflicting fail $'#mtree\n./generated_tree/support.py type=file contents=first\n./generated_tree/support.py type=file contents=second'
run_case interpreter_identical pass $'#mtree\n./app.runfiles/_main/shared_runtime/bin/python type=file mode=0755 content=bazel-out/cfg/bin/shared_runtime/bin/python\n./app.runfiles/_main/shared_runtime/bin/python type=file mode=0755 content=bazel-out/cfg/bin/shared_runtime/bin/python' 'py_image_layer runfile collision at ./app.runfiles/_main/shared_runtime/bin/python:'
[[ $(grep -Fc './app.runfiles/_main/shared_runtime/bin/python ' "$TEST_TMPDIR/interpreter_identical.out") == 1 ]]
run_case interpreter_conflicting fail $'#mtree\n./app.runfiles/_main/shared_runtime/bin/python type=file mode=0755 content=bazel-out/first/bin/shared_runtime/bin/python\n./app.runfiles/_main/shared_runtime/bin/python type=file mode=0755 content=bazel-out/second/bin/shared_runtime/bin/python' 'py_image_layer runfile collision at ./app.runfiles/_main/shared_runtime/bin/python:'
run_case dot_alias fail $'#mtree\n./generated_tree/./support.py type=file contents=first\n./generated_tree/support.py type=file contents=second'
run_case parent_alias fail $'#mtree\n./generated_tree/nested/../support.py type=file contents=first\n./generated_tree/support.py type=file contents=second'
run_case ancestor_first fail $'#mtree\n./generated_tree/support.py type=file contents=first\n./generated_tree/support.py/data type=file contents=second' 'py_image_layer runfile collision at ./generated_tree/support.py/data:'
run_case descendant_first fail $'#mtree\n./generated_tree/support.py/data type=file contents=first\n./generated_tree/support.py type=file contents=second' 'py_image_layer runfile collision at ./generated_tree/support.py/data:'
run_case above_root fail $'#mtree\n../generated_tree/support.py type=file contents=first' 'py_image_layer image destination escapes its root:'

if "$gawk" -v "outfile=$TEST_TMPDIR/validate_only.out" -v validate_only=1 -f "$awk_script" \
    <<< $'#mtree\n./generated_tree/support.py type=file contents=first\n./generated_tree/support.py type=file contents=second' \
    2>"$TEST_TMPDIR/validate_only.err"; then
    echo 'validate_only: expected collision failure' >&2
    exit 1
fi
grep -Fq 'py_image_layer runfile collision at ./generated_tree/support.py:' "$TEST_TMPDIR/validate_only.err"

"$gawk" -v "outfile=$TEST_TMPDIR/validate_same_source.out" -v validate_only=1 -f "$awk_script" \
    <<< $'#mtree\n./generated_tree/support.py type=file mode=0755 content=same\n./generated_tree/support.py type=file mode=0644 contents=same'
