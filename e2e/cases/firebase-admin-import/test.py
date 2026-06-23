"""Exercise disjoint `google` namespace projection on a firebase-admin graph."""

import sys


def test_firebase_admin_imports():
    import firebase_admin

    # Reaching here means firebase_admin.__init__ ran to completion,
    # which requires `from google.auth import ...` to have succeeded.
    assert firebase_admin is not None
    assert hasattr(firebase_admin, "__version__"), (
        "firebase_admin module loaded but missing __version__"
    )


def test_google_auth_resolves():
    """Directly verify the namespace-package import path firebase uses."""
    import google.auth

    assert google.auth is not None


def test_google_is_namespace_package():
    """The `google` top-level must be a PEP 420 namespace package.

    If our venv-assembly accidentally put a `google/__init__.py` at the
    projected site-packages root, this would fail — and firebase_admin
    wouldn't be able to see the other `google.*` contributors.
    """
    import google

    assert not hasattr(google, "__file__") or google.__file__ is None, (
        "google should be a namespace package but has __file__={!r}".format(
            google.__file__,
        )
    )


if __name__ == "__main__":
    test_firebase_admin_imports()
    test_google_auth_resolves()
    test_google_is_namespace_package()
    print("PASS: firebase_admin and google.auth import correctly")
    sys.exit(0)
