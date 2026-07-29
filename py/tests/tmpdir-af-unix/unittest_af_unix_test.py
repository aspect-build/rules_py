"""Issue 1387 under the py_unittest_test launcher (unittest_main.py)."""

import unittest

import af_unix_probe

unix_only = unittest.skipIf(not af_unix_probe.IS_UNIX, af_unix_probe.NOT_UNIX_REASON)


class AfUnixTmpdirTest(unittest.TestCase):
    @unix_only
    def test_tmpdir_leaves_room_for_a_socket(self) -> None:
        af_unix_probe.check_tmpdir_leaves_room_for_a_socket()

    @unix_only
    def test_tmpdir_alias_is_stable(self) -> None:
        af_unix_probe.check_tmpdir_alias_is_stable()

    @unix_only
    def test_alias_handles_non_utf8_path(self) -> None:
        af_unix_probe.check_alias_handles_non_utf8_path()

    @unix_only
    def test_alias_survives_forked_child_exit(self) -> None:
        af_unix_probe.check_alias_survives_forked_child_exit()

    @unix_only
    def test_reused_alias_survives_reuser_exit(self) -> None:
        af_unix_probe.check_reused_alias_survives_reuser_exit()

    @unix_only
    def test_alias_is_removed_on_exit(self) -> None:
        af_unix_probe.check_alias_is_removed_on_exit()

    @unix_only
    def test_alias_dir_rejects_writable_modes(self) -> None:
        af_unix_probe.check_alias_dir_rejects_writable_modes()

    @unix_only
    def test_alias_dir_traversable_after_dropping_privileges(self) -> None:
        af_unix_probe.check_alias_dir_traversable_after_dropping_privileges()

    def test_tmpdir_resolves_into_test_tmpdir(self) -> None:
        af_unix_probe.check_tmpdir_resolves_into_test_tmpdir()

    @unix_only
    def test_bind_unix_socket_under_tmpdir(self) -> None:
        af_unix_probe.check_bind_unix_socket_under_tmpdir()

    @unix_only
    def test_spawn_sync_manager(self) -> None:
        af_unix_probe.check_spawn_sync_manager()
