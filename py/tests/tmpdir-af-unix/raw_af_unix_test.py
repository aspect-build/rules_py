"""Issue 1387 under a plain py_test with its own main.

No generated launcher runs here, so TMPDIR keeps its system value and the
socket path stays short. This target guards that: it fails if the TMPDIR
override ever reaches the native launcher.
"""

import af_unix_probe

if __name__ == "__main__":
    if af_unix_probe.IS_UNIX:
        af_unix_probe.check_tmpdir_leaves_room_for_a_socket()
        af_unix_probe.check_bind_unix_socket_under_tmpdir()
        af_unix_probe.check_spawn_sync_manager()
