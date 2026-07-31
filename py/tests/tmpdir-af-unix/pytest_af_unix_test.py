"""Issue 1387 under the py_pytest_test launcher (pytest_main.py)."""

import os
from pathlib import Path

import af_unix_probe
import pytest

unix_only = pytest.mark.skipif(
    not af_unix_probe.IS_UNIX, reason=af_unix_probe.NOT_UNIX_REASON
)


@unix_only
def test_tmpdir_leaves_room_for_a_socket() -> None:
    af_unix_probe.check_tmpdir_leaves_room_for_a_socket()


@unix_only
def test_tmpdir_alias_is_stable() -> None:
    af_unix_probe.check_tmpdir_alias_is_stable()


@unix_only
def test_alias_handles_non_utf8_path() -> None:
    af_unix_probe.check_alias_handles_non_utf8_path()


@unix_only
def test_alias_survives_forked_child_exit() -> None:
    af_unix_probe.check_alias_survives_forked_child_exit()


@unix_only
def test_reused_alias_survives_reuser_exit() -> None:
    af_unix_probe.check_reused_alias_survives_reuser_exit()


@unix_only
def test_alias_is_removed_on_exit() -> None:
    af_unix_probe.check_alias_is_removed_on_exit()


@unix_only
def test_alias_dir_rejects_writable_modes() -> None:
    af_unix_probe.check_alias_dir_rejects_writable_modes()


@unix_only
def test_alias_dir_traversable_after_dropping_privileges() -> None:
    af_unix_probe.check_alias_dir_traversable_after_dropping_privileges()


def test_tmpdir_resolves_into_test_tmpdir() -> None:
    af_unix_probe.check_tmpdir_resolves_into_test_tmpdir()


@unix_only
def test_bind_unix_socket_under_tmpdir() -> None:
    af_unix_probe.check_bind_unix_socket_under_tmpdir()


@unix_only
def test_spawn_sync_manager() -> None:
    af_unix_probe.check_spawn_sync_manager()


def test_tmp_path_bypasses_the_short_tmpdir(tmp_path: Path) -> None:
    """Known limitation: the short TMPDIR does not reach pytest's own fixtures.

    `_pytest/tmpdir.py` resolves the temp root unconditionally
    (`Path(from_env or tempfile.gettempdir()).resolve()`), and does the same to
    an explicit `--basetemp`, so `tmp_path` lands on the long TEST_TMPDIR path.
    A socket bound directly under `tmp_path` can therefore still overflow
    sun_path -- unchanged from before the issues/1387 fix, which only covers
    consumers that read TMPDIR without resolving it (`tempfile`,
    `multiprocessing`). Asserted by shape, not by length, so it holds on any
    output base; it turns red if pytest ever stops resolving.
    """
    assert not str(tmp_path).startswith(os.environ["TMPDIR"])
    assert str(tmp_path).startswith(os.path.realpath(os.environ["TEST_TMPDIR"]))
