"""
Utilities for parsing git URLs and converting them to http_archive.
"""

def ensure_ref(maybe_ref):
    """Ensures a git ref starts with "ref/".

    Args:
        maybe_ref: The git ref string.

    Returns:
        The git ref string, prefixed with "ref/" if it is not already.
    """
    if maybe_ref == None:
        return None

    if not maybe_ref.startswith("ref/"):
        return "ref/" + maybe_ref

    return maybe_ref

def parse_git_url(url):
    """Parses a git URL into a dictionary of `git_repository` arguments.

    This function is a simplified parser for git URLs that can extract a remote
    URL, a commit hash, or a ref. It supports URLs with fragments and query

    Args:
        url: The git URL to parse.

    Returns:
        A dictionary of `git_repository` arguments.
    """

    # 1. Handle Fragment (anything after #)
    # URL: https://github.com/user/repo.git#c7076a0...
    remote_and_query, hash_sep, fragment = url.partition("#")

    # 2. Handle Query Parameters (anything after ?)
    # URL: https://github.com/user/repo.git?rev=refs/pull/64/head
    remote_base, query_sep, query_string = remote_and_query.partition("?")

    kwargs = {"remote": remote_base}
    rev = ""
    ref = ""

    # 3. Extract revision from Fragment
    if fragment:
        rev = fragment

        # 4. Extract revision from Query String (if fragment wasn't present)
    elif query_string:
        params = {}

        # Manually parse query string for 'rev=' or 'ref='
        pairs = query_string.split("&")
        for pair in pairs:
            k, v = pair.split("=", 1)

            # FIXME: Better urldecode
            params[k] = v.replace("%2F", "/").replace("%2f", "/")

        if "ref" in params:
            ref = params["ref"]

        if "commit" in params:
            rev = params["commit"]

    # 5. Determine if the revision is a commit, tag, or branch
    if rev:
        kwargs["commit"] = rev
    elif ref:
        kwargs["ref"] = ensure_ref(ref)  # Use the public ensure_ref

    return kwargs

def try_git_to_http_archive(git_cfg):
    """Tries to convert a `git_repository` configuration to an `http_archive`.

    This function attempts to convert a `git_repository` configuration to an
    `http_archive` configuration for well-known git hosting services like
    GitHub. This is useful for performance, as downloading a tarball over HTTP
    is generally faster than cloning a git repository.

    Args:
        git_cfg: A dictionary of `git_repository` arguments.

    Returns:
        A dictionary of `http_archive` arguments, or `None` if the conversion
        is not possible.
    """

    if "https://github.com/" in git_cfg["remote"]:
        url = git_cfg["remote"].replace("git+", "").replace(".git", "").rstrip("/")
        if "commit" in git_cfg:
            url = "{}/archive/{}.tar.gz".format(url, git_cfg["commit"])
            return {
                "url": url,
            }
        elif "ref" in git_cfg:
            url = "{}/archive/{}.tar.gz".format(url, git_cfg["tag"])
            return {
                "url": url,
            }

    # FIXME: Support gitlab, other hosts?
