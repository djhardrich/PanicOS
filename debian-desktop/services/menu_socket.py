"""Tiny shared helper for the PanicOS menu-event datagram socket.

Production uses the Linux abstract unix-socket namespace (path starts
with NUL byte) so there is no filesystem object — no directory to
create, no perms to manage, root daemon and user agent can talk freely.

The system daemon (gamepad-mouse.py) calls send_event(). The per-user
session agent (panicos-session-agent.py) calls bind_server() and recvfrom().

Tests pass an explicit filesystem path so they can exercise stale-socket
cleanup behavior; that path is chmod 0666. Abstract paths skip chmod.
"""
import os
import socket

# Leading NUL → Linux abstract namespace (no filesystem entry).
SOCK_PATH = "\0panicos-menu"
VALID_EVENTS = ("short", "long")
SOCK_MODE = 0o666


def _is_abstract(path: str) -> bool:
    return path.startswith("\0")


def bind_server(path: str = SOCK_PATH) -> socket.socket:
    """Bind the receiving end. For filesystem paths, replace any stale file."""
    if not _is_abstract(path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.bind(path)
    if not _is_abstract(path):
        os.chmod(path, SOCK_MODE)
    return s


def send_event(event: str, path: str = SOCK_PATH) -> None:
    """Send one event; silently no-op if no one is listening."""
    if event not in VALID_EVENTS:
        raise ValueError(f"invalid event {event!r}; expected one of {VALID_EVENTS}")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        s.sendto(f"{event}\n".encode("ascii"), path)
    except (ConnectionRefusedError, FileNotFoundError):
        pass
    finally:
        s.close()
