"""Shared private-input and process helpers for native session validation."""

import os
from pathlib import Path
import signal
import subprocess

HOST = Path(__file__).resolve().parents[1]
ORIGIN = "https://api.uk01-lon.anythink.cloud"
PROJECT = "19006800"
PHASES = {
    "establish": {
        "password_sign_in",
        "server_identity_and_role",
        "native_secure_persistence",
    },
    "restore_refresh_logout": {
        "restore_after_process_restart",
        "real_refresh_rotation_and_identity",
        "local_logout_and_revoke_response",
    },
    "verify_cleared": {"logout_durable_after_process_restart"},
}


_TERMINATE_GRACE_SECONDS = 10


class ValidationFailure(Exception):
    """An exclusively fixed, non-sensitive outcome label."""


def _signal_process_group(process, requested_signal):
    try:
        os.killpg(process.pid, requested_signal)
    except ProcessLookupError:
        # The process may finish between communicate() and group termination.
        pass


def _stop_process_group(process):
    _signal_process_group(process, signal.SIGTERM)
    try:
        process.communicate(timeout=_TERMINATE_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        # A descendant can retain the output pipe after the group leader exits.
        _signal_process_group(process, signal.SIGKILL)
        process.communicate()


def captured(command, *, payload=None, timeout=30):
    """Capture private child output; stop its entire group on timeout/interrupt."""
    process = subprocess.Popen(
        command,
        cwd=HOST,
        stdin=subprocess.PIPE if payload is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(payload, timeout=timeout)
    except subprocess.TimeoutExpired:
        _stop_process_group(process)
        raise ValidationFailure("subprocess_timeout") from None
    except BaseException:
        # KeyboardInterrupt/SystemExit also release child processes before the
        # platform runner removes its one-use input in its own finally block.
        _stop_process_group(process)
        raise
    return process.returncode, output.decode("utf-8", errors="replace")
