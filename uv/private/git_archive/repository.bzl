"""A repository rule for creating an archive from a remote git repository."""

load("@bazel_features//:features.bzl", features = "bazel_features")

def _is_sha1(s):
    """Check if a string is a 40-character hex string (SHA-1)."""
    if len(s) != 40:
        return False
    for char in s.elems():
        if char not in "0123456789abcdefABCDEF":
            return False
    return True

def _git_archive_impl(repository_ctx):
    """Fetch a git snapshot and expose it as a tar filegroup.

    The implementation validates the commit hash, resolves symbolic refs via
    `git ls-remote`, runs `git archive`, and reports reproducibility metadata
    when the Bazel version supports it.

    Args:
      repository_ctx: the repository rule context.

    Returns:
      Optional reproducibility metadata returned by `repository_ctx.repo_metadata`.
    """
    remote = repository_ctx.attr.remote
    commit = repository_ctx.attr.commit
    ref = repository_ctx.attr.ref

    if commit and not _is_sha1(commit):
        fail("The 'commit' attribute must be a 40-character hex string. Got: {}".format(commit))

    target_ref = ref or commit
    is_reproducible = True
    resolved_commit = commit

    if ref:
        result = repository_ctx.execute(["git", "ls-remote", remote, ref])
        if result.return_code == 0 and result.stdout:
            resolved_commit = result.stdout.split()[0]
            is_reproducible = False
        else:
            is_reproducible = False
            fail("Unable to resolve remote ref {} {}".format(remote, ref))

    archive_path = "archive.tar"

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

    print(cmd)

    status = repository_ctx.execute(cmd)

    print("Git exited {}".format(status.return_code))
    print(status.stdout)
    print(status.stderr)

    if status.return_code != 0:
        fail("Failed to build the requested git archive!")

    if features.external_deps.extension_metadata_has_reproducible:
        if is_reproducible:
            return repository_ctx.repo_metadata(reproducible = True)
        else:
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
