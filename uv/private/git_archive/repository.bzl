"""
A repository rule for creating an archive from a remote git repository.
"""

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
            # If we can't resolve it, it's definitely not reproducible
            is_reproducible = False
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

    # Execute the archive command
    repository_ctx.execute(
        [
            "git",
            "archive",
            "--format=tar",
            "--remote=" + remote,
            "--output=file/" + archive_path,
            target_ref,
        ],
    )

    if features.external_deps.extension_metadata_has_reproducible:
        return repository_ctx.repo_metadata(
            reproducible = is_reproducible,
            attrs_for_reproducibility = {"commit": resolved_commit} if not is_reproducible else None,
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
