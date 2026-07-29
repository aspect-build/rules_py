"""Shared assertions for https://github.com/aspect-build/rules_py/issues/1387.

The generated pytest/unittest launchers point TMPDIR at TEST_TMPDIR, a deeply
nested path under the bazel output base. An AF_UNIX socket created there
overflows sun_path (108 bytes on Linux, 104 on macOS), so
`multiprocessing.get_context("spawn").Manager()` -- which binds one via
`connection.arbitrary_address()` -- dies with "OSError: AF_UNIX path too long".
"""

import atexit
import hashlib
import multiprocessing
import os
import socket
import stat
import tempfile

import aspect_rules_py_launcher_env as launcher_env

# multiprocessing.connection.arbitrary_address() builds
# <tmp>/pymp-XXXXXXXX/listener-XXXXXXXX
SOCKET_OVERHEAD = len("/pymp-abcd1234/listener-abcd1234")

# The smaller of the two sun_path limits, so the assertion means the same thing
# on every platform.
SUN_PATH_MAX = 104

# Mirrors the launcher's own guard: it only shortens TMPDIR on POSIX, so the
# sun_path budget and the alias scheme are only asserted there.
IS_UNIX = os.name == "posix"
NOT_UNIX_REASON = "no AF_UNIX"


def check_tmpdir_leaves_room_for_a_socket() -> None:
    tmp = tempfile.gettempdir()
    assert len(tmp) + SOCKET_OVERHEAD < SUN_PATH_MAX, f"temp dir too deep for AF_UNIX: {tmp}"


def check_tmpdir_alias_is_stable() -> None:
    """The alias is named for TEST_TMPDIR, not for the invocation, so a test
    killed by a timeout or a signal -- which runs no exit hook -- leaves at most
    the single entry its next run reuses.
    """
    real = os.path.abspath(os.environ["TEST_TMPDIR"])
    digest = hashlib.sha256(os.fsencode(real)).hexdigest()[:16]
    assert tempfile.gettempdir() == "/tmp/rpy-%d/%s" % (os.getuid(), digest)


def check_alias_handles_non_utf8_path() -> None:
    """A POSIX path may hold any non-NUL bytes, which arrive as surrogate
    escapes; naming the alias with `str.encode()` would raise UnicodeEncodeError
    before the launcher could run a single test.
    """
    real = os.path.join(os.environ["TEST_TMPDIR"], os.fsdecode(b"\xff-1387"))
    alias = launcher_env._short_tmpdir(real)
    assert alias != real, "non-UTF-8 path fell back to the long path"
    assert os.readlink(alias) == real


def check_alias_survives_forked_child_exit() -> None:
    """A fork inherits the creator's atexit callbacks, so a child exiting
    normally would unlink the alias its parent still has in TMPDIR.

    The child runs its inherited callbacks explicitly and then `os._exit`s:
    that is what interpreter shutdown would do, without unwinding SystemExit
    back through the test framework.
    """
    real = os.path.join(os.environ["TEST_TMPDIR"], "fork-1387")
    os.makedirs(real, exist_ok=True)
    alias = launcher_env._short_tmpdir(real)
    assert alias != real, "no alias to test"

    pid = os.fork()
    if pid == 0:
        try:
            atexit._run_exitfuncs()
        finally:
            os._exit(0)
    _, status = os.waitpid(pid, 0)

    assert status == 0, status
    assert os.readlink(alias) == real, "child removed its parent's alias"


def check_alias_dir_rejects_writable_modes() -> None:
    """The directory is the trust boundary: anyone who can write to it can swap
    the aliases inside, so a group/other-writable one is refused. A 0700 dir
    from an earlier version stays usable."""
    alias_dir = os.path.dirname(tempfile.gettempdir())
    mode = stat.S_IMODE(os.lstat(alias_dir).st_mode)
    try:
        for writable in (0o777, 0o733, 0o722):
            os.chmod(alias_dir, writable)
            assert launcher_env._alias_dir() is None, oct(writable)
        os.chmod(alias_dir, 0o700)
        assert launcher_env._alias_dir() == alias_dir, "0700 must stay usable"
    finally:
        os.chmod(alias_dir, mode)


def check_alias_dir_traversable_after_dropping_privileges() -> None:
    """A test that drops privileges must still reach its own TMPDIR: reading
    the alias needs only search permission on the directory."""
    if os.getuid() != 0:
        return  # Not root, so there is nothing to drop.
    import pwd

    nobody = pwd.getpwnam("nobody")
    alias = tempfile.gettempdir()

    pid = os.fork()
    if pid == 0:
        code = 0
        try:
            os.setgid(nobody.pw_gid)
            os.setuid(nobody.pw_uid)
            os.readlink(alias)
        except OSError:
            code = 1
        os._exit(code)
    _, status = os.waitpid(pid, 0)
    assert status == 0, "dropped-privilege child could not reach TMPDIR"


def check_alias_is_removed_on_exit() -> None:
    """A normally exiting process takes its own alias with it."""
    real = os.path.join(os.environ["TEST_TMPDIR"], "exit-1387")
    os.makedirs(real, exist_ok=True)

    pid = os.fork()
    if pid == 0:
        code = 0 if launcher_env._short_tmpdir(real) != real else 1
        try:
            atexit._run_exitfuncs()
        finally:
            os._exit(code)
    _, status = os.waitpid(pid, 0)
    assert status == 0, status

    digest = hashlib.sha256(os.fsencode(real)).hexdigest()[:16]
    alias = os.path.join(os.path.dirname(tempfile.gettempdir()), digest)
    assert not os.path.lexists(alias), alias


def check_reused_alias_survives_reuser_exit() -> None:
    """A second process that finds the alias already there reuses it without
    taking ownership, so its exit leaves the creator's alias alone."""
    real = os.path.join(os.environ["TEST_TMPDIR"], "reuse-1387")
    os.makedirs(real, exist_ok=True)
    alias = launcher_env._short_tmpdir(real)
    assert launcher_env._short_tmpdir(real) == alias

    pid = os.fork()
    if pid == 0:
        # A launcher starting in this process reuses the existing alias; its
        # normal exit must not remove it.
        code = 0 if launcher_env._short_tmpdir(real) == alias else 1
        try:
            atexit._run_exitfuncs()
        finally:
            os._exit(code)
    _, status = os.waitpid(pid, 0)

    assert status == 0, status
    assert os.readlink(alias) == real, "reuser removed the creator's alias"


def check_tmpdir_resolves_into_test_tmpdir() -> None:
    """The short path is an alias, not an escape: files still land in TEST_TMPDIR."""
    real = os.path.realpath(tempfile.gettempdir())
    assert real == os.path.realpath(os.environ["TEST_TMPDIR"]), real


def check_bind_unix_socket_under_tmpdir() -> None:
    addr = os.path.join(tempfile.mkdtemp(prefix="pymp-"), "listener-abcd1234")
    with socket.socket(socket.AF_UNIX) as sock:
        sock.bind(addr)


def check_spawn_sync_manager() -> None:
    with multiprocessing.get_context("spawn").Manager() as mgr:
        d = mgr.dict()
        d["k"] = "v"
        assert d["k"] == "v"
