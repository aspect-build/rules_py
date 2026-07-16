"""
A repository rule for creating an archive from a remote git repository.
"""

def _is_sha1(s):
    """Check if a string is a 40-character hex string (SHA-1)."""
    if len(s) != 40:
        return False
    for char in s.elems():
        if char not in "0123456789abcdefABCDEF":
            return False
    return True

def _git_archive_impl(repository_ctx):
    remote = repository_ctx.attr.remote
    commit = repository_ctx.attr.commit
    ref = repository_ctx.attr.ref

    if commit and not _is_sha1(commit):
        fail("The 'commit' attribute must be a 40-character hex string. Got: {}".format(commit))

    target_ref = ref or commit
    is_reproducible = True
    resolved_commit = commit

    if ref:
        # Use git ls-remote to find the commit associated with the ref
        result = repository_ctx.execute(["git", "ls-remote", remote, ref])
        if result.return_code == 0 and result.stdout:
            # ls-remote output is: "<commit>\t<ref>"
            resolved_commit = result.stdout.split()[0]
            is_reproducible = False
        else:
            fail("Unable to resolve remote ref {} {}".format(remote, ref))

    archive_path = "archive.tar"

    # Note that this implies a mkdir the execute relies on
    repository_ctx.file("file/BUILD.bazel", """
package(default_visibility = ["//visibility:public"])
filegroup(
    name = "file",
    srcs = ["{}"],
)
""".format(archive_path))

    cmd = [
        "git",
        "archive",
        "--format=tar",
        "--remote=" + remote,
        "--output=file/" + archive_path,
        target_ref,
    ]

    if repository_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
        print(cmd)

    # Execute the archive command
    status = repository_ctx.execute(
        cmd,
    )

    if status.return_code != 0:
        fail("Failed to build the requested git archive! Git exited {}\n\nstdout: {}\n\nstderr: {}".format(
            status.return_code,
            status.stdout,
            status.stderr,
        ))

    if repository_ctx.getenv("RULES_PY_UV_VERBOSE", ""):
        print(status.stdout)
        print(status.stderr)

    if is_reproducible:
        return repository_ctx.repo_metadata(reproducible = True)
    return repository_ctx.repo_metadata(
        reproducible = False,
        attrs_for_reproducibility = {"commit": resolved_commit},
    )

git_archive = repository_rule(
    implementation = _git_archive_impl,
    attrs = {
        "remote": attr.string(
            doc = "The URL of the remote git repository.",
            mandatory = True,
        ),
        "ref": attr.string(
            doc = "The git ref to archive.",
            mandatory = False,
        ),
        "commit": attr.string(
            doc = "The git commit to archive.",
            mandatory = False,
        ),
    },
)
