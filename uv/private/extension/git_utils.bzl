"""Utilities for parsing git URLs and converting them to http_archive configs.

This module provides helpers to extract remote URLs, commits and refs from
git URLs commonly found in Python lockfiles, and to translate those into
`http_archive` downloads for well-known git hosting providers.
"""

def ensure_ref(maybe_ref):
    """Ensures a git ref starts with the "ref/" prefix.

    Args:
        maybe_ref: The git ref string, or `None`.

    Returns:
        The git ref prefixed with "ref/" when applicable, or `None` if the
        input was `None`.
    """
    if maybe_ref == None:
        return None

    if not maybe_ref.startswith("ref/"):
        return "ref/" + maybe_ref

    return maybe_ref

def parse_git_url(url):
    """Parses a git URL into a dictionary of `git_repository` arguments.

    Supports URLs with fragment identifiers (`#commit`) and query parameters
    (`?rev=refs/pull/64/head`). The fragment takes precedence over the query
    string when determining the revision.

    Args:
        url: The git URL to parse.

    Returns:
        A dictionary of `git_repository` arguments containing at least a
        `"remote"` key, and optionally `"commit"` or `"ref"`.
    """
    remote_and_query, hash_sep, fragment = url.partition("#")
    remote_base, query_sep, query_string = remote_and_query.partition("?")

    kwargs = {"remote": remote_base}
    rev = ""
    ref = ""

    if fragment:
        rev = fragment
    elif query_string:
        params = {}
        pairs = query_string.split("&")
        for pair in pairs:
            k, v = pair.split("=", 1)
            params[k] = v.replace("%2F", "/").replace("%2f", "/")

        if "ref" in params:
            ref = params["ref"]

        if "commit" in params:
            rev = params["commit"]

    if rev:
        kwargs["commit"] = rev
    elif ref:
        kwargs["ref"] = ensure_ref(ref)

    return kwargs

def try_git_to_http_archive(git_cfg):
    """Attempts to convert a `git_repository` config into an `http_archive` config.

    For well-known hosting services such as GitHub, downloading a tarball over
    HTTP is generally faster than cloning the full git history. This function
    performs that translation when possible.

    Args:
        git_cfg: A dictionary of `git_repository` arguments.

    Returns:
        A dictionary of `http_archive` arguments, or `None` if the conversion
        is not supported for the given remote host.
    """
    if "https://github.com/" in git_cfg["remote"]:
        url = git_cfg["remote"].replace("git+", "").replace(".git", "").rstrip("/")
        if "commit" in git_cfg:
            url = "{}/archive/{}.tar.gz".format(url, git_cfg["commit"])
            return {"url": url}
        elif "ref" in git_cfg:
            url = "{}/archive/{}.tar.gz".format(url, git_cfg["tag"])
            return {"url": url}

    return None

