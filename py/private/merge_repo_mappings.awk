# Merge Bazel's three-column repository mappings without silently choosing one
# target for an apparent repository name.
BEGIN {
    FS = ","
}

NF != 3 {
    printf "invalid repository mapping at %s:%d: expected 3 columns, got %d\n", FILENAME, FNR, NF > "/dev/stderr"
    failed = 1
    exit 1
}

{
    key = $1 SUBSEP $2
    if (key in mappings && mappings[key] != $3) {
        printf "conflicting repository mapping for %s,%s: %s and %s\n", $1, $2, mappings[key], $3 > "/dev/stderr"
        failed = 1
        exit 1
    }
    mappings[key] = $3
    rows[$0] = 1
}

END {
    if (failed) {
        exit 1
    }
    printf "" > output
    count = asorti(rows, sorted)
    for (i = 1; i <= count; i++) {
        print sorted[i] >> output
    }
    close(output)
}
