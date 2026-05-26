#!/usr/bin/env python3
"""Stand-alone test for the gamepad-mouse / session-agent socket protocol.

The daemon writes one line per gesture to a unix DGRAM socket. The agent
reads lines and dispatches. This test asserts the agreed protocol shape
without booting either real component.

Protocol:
- Transport: AF_UNIX, SOCK_DGRAM
- Production path: abstract namespace "\0panicos-menu" (no filesystem)
- Test path: any filesystem path (verifies stale-socket cleanup + 0666 perm)
- Payloads: ASCII bytes, exactly one of b"short\n" or b"long\n"
- Any other payload MUST be ignored by the agent.
"""
import os, sys, socket, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import menu_socket


class MenuSocketTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.sock_path = os.path.join(self.tmpdir, "menu.sock")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_send_short_filesystem(self):
        srv = menu_socket.bind_server(self.sock_path)
        menu_socket.send_event("short", self.sock_path)
        data, _ = srv.recvfrom(64)
        self.assertEqual(data, b"short\n")
        srv.close()

    def test_send_long_filesystem(self):
        srv = menu_socket.bind_server(self.sock_path)
        menu_socket.send_event("long", self.sock_path)
        data, _ = srv.recvfrom(64)
        self.assertEqual(data, b"long\n")
        srv.close()

    def test_send_short_abstract(self):
        # Use a unique abstract name per test to avoid collisions
        abs_path = f"\0menu-socket-test-{os.getpid()}"
        srv = menu_socket.bind_server(abs_path)
        menu_socket.send_event("short", abs_path)
        data, _ = srv.recvfrom(64)
        self.assertEqual(data, b"short\n")
        srv.close()

    def test_reject_unknown_event(self):
        with self.assertRaises(ValueError):
            menu_socket.send_event("bogus", self.sock_path)

    def test_filesystem_socket_mode_is_0666(self):
        srv = menu_socket.bind_server(self.sock_path)
        mode = os.stat(self.sock_path).st_mode & 0o777
        self.assertEqual(mode, 0o666)
        srv.close()

    def test_send_before_server_bound_does_not_raise(self):
        # Daemon may write before agent is up; should silently no-op
        menu_socket.send_event("short", self.sock_path)

    def test_stale_socket_file_is_replaced(self):
        # Pre-create a regular file at the target path; bind_server must
        # remove it before binding (only for filesystem paths).
        with open(self.sock_path, "w") as f:
            f.write("stale")
        srv = menu_socket.bind_server(self.sock_path)
        # If bind succeeded, the file is now a socket
        import stat
        self.assertTrue(stat.S_ISSOCK(os.stat(self.sock_path).st_mode))
        srv.close()


if __name__ == "__main__":
    unittest.main()
