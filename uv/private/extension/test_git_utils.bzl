load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":git_utils.bzl", "ensure_ref", "locked_git_requirement_urls", "parse_git_url", "try_git_to_http_archive")

def _ensure_ref_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, ensure_ref(None))
    asserts.equals(env, "refs/heads/main", ensure_ref("heads/main"))
    asserts.equals(env, "refs/pull/64/head", ensure_ref("pull/64/head"))

    # An already fully-qualified ref must not be prefixed again.
    asserts.equals(env, "refs/pull/64/head", ensure_ref("refs/pull/64/head"))
    asserts.equals(env, "refs/tags/v1.0.0", ensure_ref("refs/tags/v1.0.0"))
    return unittest.end(env)

ensure_ref_test = unittest.make(_ensure_ref_test_impl)

def _parse_git_url_fragment_commit_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_git_url("https://github.com/user/repo.git#c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1")
    asserts.equals(env, {
        "remote": "https://github.com/user/repo.git",
        "commit": "c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1",
    }, result)
    return unittest.end(env)

parse_git_url_fragment_commit_test = unittest.make(_parse_git_url_fragment_commit_test_impl)

def _parse_git_url_query_commit_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_git_url("https://github.com/user/repo.git?commit=c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1")
    asserts.equals(env, {
        "remote": "https://github.com/user/repo.git",
        "commit": "c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1",
    }, result)
    return unittest.end(env)

parse_git_url_query_commit_test = unittest.make(_parse_git_url_query_commit_test_impl)

def _parse_git_url_query_ref_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_git_url("https://github.com/user/repo.git?ref=refs%2Fpull%2F64%2Fhead")
    asserts.equals(env, {
        "remote": "https://github.com/user/repo.git",
        "ref": "refs/pull/64/head",
    }, result)
    return unittest.end(env)

parse_git_url_query_ref_test = unittest.make(_parse_git_url_query_ref_test_impl)

def _parse_git_url_fragment_wins_over_query_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_git_url("https://github.com/user/repo.git?ref=refs%2Fheads%2Fmain#c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1")
    asserts.equals(env, {
        "remote": "https://github.com/user/repo.git",
        "commit": "c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1",
    }, result)
    return unittest.end(env)

parse_git_url_fragment_wins_over_query_test = unittest.make(_parse_git_url_fragment_wins_over_query_test_impl)

def _parse_git_url_bare_remote_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_git_url("https://github.com/user/repo.git")
    asserts.equals(env, {"remote": "https://github.com/user/repo.git"}, result)
    return unittest.end(env)

parse_git_url_bare_remote_test = unittest.make(_parse_git_url_bare_remote_test_impl)

def _locked_git_requirement_urls_test_impl(ctx):
    env = unittest.begin(ctx)
    result = locked_git_requirement_urls("https://github.com/benjaminp/six?tag=1.17.0#ebd9b3af90247b8858d415a05e96e9ee61e48d07")
    asserts.equals(env, [
        "git+https://github.com/benjaminp/six",
        "git+https://github.com/benjaminp/six@ebd9b3af90247b8858d415a05e96e9ee61e48d07",
        "git+https://github.com/benjaminp/six@1.17.0",
    ], result)

    result = locked_git_requirement_urls("git+https://github.com/example/project?branch=release%2F1.x&subdirectory=python%2Fpkg#abc123")
    asserts.equals(env, [
        "git+https://github.com/example/project#subdirectory=python/pkg",
        "git+https://github.com/example/project@abc123#subdirectory=python/pkg",
        "git+https://github.com/example/project@release/1.x#subdirectory=python/pkg",
    ], result)
    return unittest.end(env)

locked_git_requirement_urls_test = unittest.make(_locked_git_requirement_urls_test_impl)

def _git_to_http_archive_commit_test_impl(ctx):
    env = unittest.begin(ctx)
    result = try_git_to_http_archive({
        "remote": "git+https://github.com/user/repo.git",
        "commit": "c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1",
    })
    asserts.equals(env, {
        "url": "https://github.com/user/repo/archive/c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1.tar.gz",
    }, result)
    return unittest.end(env)

git_to_http_archive_commit_test = unittest.make(_git_to_http_archive_commit_test_impl)

def _git_to_http_archive_ref_test_impl(ctx):
    env = unittest.begin(ctx)

    # Regression test: this branch used to read git_cfg["tag"], a key
    # parse_git_url never produces.
    result = try_git_to_http_archive({
        "remote": "https://github.com/user/repo",
        "ref": "refs/pull/64/head",
    })
    asserts.equals(env, {
        "url": "https://github.com/user/repo/archive/refs/pull/64/head.tar.gz",
    }, result)
    return unittest.end(env)

git_to_http_archive_ref_test = unittest.make(_git_to_http_archive_ref_test_impl)

def _git_to_http_archive_parsed_ref_url_test_impl(ctx):
    env = unittest.begin(ctx)
    result = try_git_to_http_archive(parse_git_url("git+https://github.com/user/repo.git?ref=refs%2Ftags%2Fv1.0.0"))
    asserts.equals(env, {
        "url": "https://github.com/user/repo/archive/refs/tags/v1.0.0.tar.gz",
    }, result)
    return unittest.end(env)

git_to_http_archive_parsed_ref_url_test = unittest.make(_git_to_http_archive_parsed_ref_url_test_impl)

def _git_to_http_archive_non_github_test_impl(ctx):
    env = unittest.begin(ctx)
    result = try_git_to_http_archive({
        "remote": "https://gitlab.com/user/repo.git",
        "commit": "c7076a0c6e34d7b2fa4e0ecd7ba4b8e9d3d9e0f1",
    })
    asserts.equals(env, None, result)
    return unittest.end(env)

git_to_http_archive_non_github_test = unittest.make(_git_to_http_archive_non_github_test_impl)

def _git_to_http_archive_no_rev_test_impl(ctx):
    env = unittest.begin(ctx)
    result = try_git_to_http_archive({"remote": "https://github.com/user/repo.git"})
    asserts.equals(env, None, result)
    return unittest.end(env)

git_to_http_archive_no_rev_test = unittest.make(_git_to_http_archive_no_rev_test_impl)

def git_utils_test_suite():
    unittest.suite(
        "git_utils_tests",
        ensure_ref_test,
        parse_git_url_fragment_commit_test,
        parse_git_url_query_commit_test,
        parse_git_url_query_ref_test,
        parse_git_url_fragment_wins_over_query_test,
        parse_git_url_bare_remote_test,
        locked_git_requirement_urls_test,
        git_to_http_archive_commit_test,
        git_to_http_archive_ref_test,
        git_to_http_archive_parsed_ref_url_test,
        git_to_http_archive_non_github_test,
        git_to_http_archive_no_rev_test,
    )
