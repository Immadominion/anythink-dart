"""Offline process/runner regressions; never calls adb, simctl or Flutter."""

from contextlib import redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import run_ios_session_validation as ios
import session_validation_support as h


class ProcessTests(unittest.TestCase):
    def test_capture_keeps_payload_off_arguments_and_combines_output(self):
        code, output = h.captured([
            sys.executable, "-c",
            "import sys; data=sys.stdin.buffer.read(); "
            "sys.stdout.buffer.write(data); sys.stdout.flush(); "
            "sys.stderr.write(' stderr')",
        ], payload=b"synthetic-input", timeout=5)
        self.assertEqual(code, 0)
        self.assertEqual(output, "synthetic-input stderr")

    def test_no_payload_uses_closed_stdin(self):
        code, output = h.captured([
            sys.executable, "-c",
            "import sys; print(len(sys.stdin.buffer.read()))",
        ], timeout=5)
        self.assertEqual((code, output), (0, "0\n"))

    def test_timeout_stops_process_group_including_stubborn_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "descendant.pid"
            child_code = (
                "import signal,time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
            )
            parent_code = (
                "import pathlib,signal,subprocess,sys,time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "child=subprocess.Popen([sys.executable,'-c',sys.argv[2]]); "
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                "time.sleep(60)"
            )
            started = time.monotonic()
            with mock.patch.object(h, "_TERMINATE_GRACE_SECONDS", 0.1):
                with self.assertRaisesRegex(h.ValidationFailure, "subprocess_timeout"):
                    h.captured([
                        sys.executable, "-c", parent_code,
                        str(pid_file), child_code,
                    ], timeout=0.8)
            self.assertLess(time.monotonic() - started, 5)
            child_pid = int(pid_file.read_text())
            state = subprocess.run(
                ["ps", "-o", "stat=", "-p", str(child_pid)],
                capture_output=True, text=True, check=False,
            ).stdout.strip()
            # A killed child can briefly remain a zombie until init reaps it.
            if state and not state.startswith("Z"):
                os.kill(child_pid, signal.SIGKILL)
                self.fail("descendant remained alive after timeout")

    def test_keyboard_interrupt_reaps_actual_child_before_propagating(self):
        original_popen = subprocess.Popen
        processes = []

        def launch(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            original_communicate = process.communicate
            first_call = True

            def communicate(*values, **options):
                nonlocal first_call
                if first_call:
                    first_call = False
                    raise KeyboardInterrupt()
                return original_communicate(*values, **options)

            process.communicate = communicate
            processes.append(process)
            return process

        with mock.patch.object(h.subprocess, "Popen", side_effect=launch):
            with self.assertRaises(KeyboardInterrupt):
                h.captured([
                    sys.executable, "-c", "import time; time.sleep(60)",
                ], timeout=5)
        self.assertIsNotNone(processes[0].poll())

    def test_process_exit_race_does_not_mask_cleanup(self):
        with mock.patch.object(h.os, "killpg", side_effect=ProcessLookupError):
            h._signal_process_group(mock.Mock(pid=1), signal.SIGTERM)


class IosRunnerTests(unittest.TestCase):
    def test_runtime_is_derived_and_multiple_devices_are_rejected(self):
        inventory = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-4": [
                {"state": "Booted", "udid": "synthetic-device"},
            ],
        }}
        with mock.patch.object(ios, "must", return_value=json.dumps(inventory)):
            device, runtime, label = ios.booted_ios_device()
        self.assertEqual(device, "synthetic-device")
        self.assertEqual(runtime, "com.apple.CoreSimulator.SimRuntime.iOS-18-4")
        self.assertEqual(label, "iOS 18.4")
        inventory["devices"][runtime].append(
            {"state": "Booted", "udid": "second-synthetic-device"},
        )
        with mock.patch.object(ios, "must", return_value=json.dumps(inventory)):
            with self.assertRaisesRegex(h.ValidationFailure, "exactly_one"):
                ios.booted_ios_device()

    def test_cleanup_refreshes_container_and_preserves_restart_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            old = Path(temporary) / "old"
            new = Path(temporary) / "new"
            old.mkdir()
            new.mkdir()
            known = {old / ios.INPUT_NAME}
            next(iter(known)).write_text("synthetic-input")
            (new / ios.INPUT_NAME).write_text("synthetic-input")
            (new / ios.MARKER_NAME).write_text("restart-evidence")
            with mock.patch.object(ios, "current_cache", return_value=new):
                ios.remove_runtime_inputs("synthetic-device", known)
            self.assertFalse((old / ios.INPUT_NAME).exists())
            self.assertFalse((new / ios.INPUT_NAME).exists())
            self.assertTrue((new / ios.MARKER_NAME).exists())

    def test_lookup_failure_still_removes_previously_known_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / ios.INPUT_NAME
            path.write_text("synthetic-input")
            with mock.patch.object(
                ios, "current_cache",
                side_effect=h.ValidationFailure("ios_command_failed"),
            ):
                with self.assertRaises(h.ValidationFailure):
                    ios.remove_runtime_inputs("synthetic-device", {path})
            self.assertFalse(path.exists())

    def test_success_rechecks_replaced_containers_and_binds_dart_artifact(self):
        report, output = self.run_harness()
        self.assertEqual(len(report["phases"]), 3)
        self.assertEqual(report["runtime"], "iOS 18.4")
        self.assertTrue(report["runtime_input_removed"])
        self.assertTrue(report["restart_marker_removed"])
        self.assertEqual(
            report["dart_kernel_sha256"],
            hashlib.sha256(b"synthetic-dart-kernel").hexdigest(),
        )
        self.assertIn("IOS_VALIDATION_PASS", output)
        self.assertNotIn("synthetic-device", json.dumps(report) + output)
        self.assertNotIn("synthetic-password", json.dumps(report) + output)

    def test_input_left_in_replaced_container_fails_and_is_cleaned(self):
        self.run_harness(leftover_input=True)

    def test_restart_marker_left_after_success_gates_prevents_pass_report(self):
        self.run_harness(leftover_marker=True)

    def run_harness(self, *, leftover_input=False, leftover_marker=False):
        with tempfile.TemporaryDirectory() as temporary:
            host = Path(temporary)
            app = host / "build/ios/iphonesimulator/Runner.app"
            assets = app / "Frameworks/App.framework/flutter_assets"
            assets.mkdir(parents=True)
            (app / "Runner").write_bytes(b"synthetic-runner")
            (assets.parent / "App").write_bytes(b"synthetic-app")
            (assets / "kernel_blob.bin").write_bytes(b"synthetic-dart-kernel")
            config = host / "input.json"
            config.write_text(json.dumps({
                "api_origin": h.ORIGIN,
                "project_id": h.PROJECT,
                "users": [{
                    "email": "synthetic@example.invalid",
                    "password": "synthetic-password",
                }],
            }))
            config.chmod(0o600)
            containers = [host / ("container-" + str(i)) for i in range(4)]
            for container in containers:
                (container / "Library/Caches").mkdir(parents=True)
            current = 0
            phases = iter(h.PHASES.items())
            report_path = host / "build/ios-device-validation-report.json"
            report_path.write_text('{"stale_previous_run": true}')

            def captured(command, **unused):
                nonlocal current
                if command[:3] == ["xcrun", "simctl", "get_app_container"]:
                    return 0, str(containers[current]) + "\n"
                if command[0] != "synthetic-flutter":
                    return 0, ""
                phase, gates = next(phases)
                old_input = containers[current] / "Library/Caches" / ios.INPUT_NAME
                payload = json.loads(old_input.read_text())
                self.assertEqual(payload["phase"], phase)
                self.assertEqual(old_input.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("synthetic-password", " ".join(command))
                current += 1
                new_cache = containers[current] / "Library/Caches"
                new_input = new_cache / ios.INPUT_NAME
                old_input.rename(new_input)
                if not leftover_input:
                    new_input.unlink()
                if leftover_marker and phase == "verify_cleared":
                    (new_cache / ios.MARKER_NAME).write_text("private-test-state")
                return 0, "\n".join(
                    "DEVICE_GATE_PASS " + gate for gate in gates
                ) + "\nAll tests passed!\n"

            output = io.StringIO()
            with (
                mock.patch.object(ios, "HOST", host),
                mock.patch.object(
                    ios.shutil, "which", return_value="synthetic-flutter",
                ),
                mock.patch.object(ios, "booted_ios_device", return_value=(
                    "synthetic-device",
                    "com.apple.CoreSimulator.SimRuntime.iOS-18-4", "iOS 18.4",
                )),
                mock.patch.object(h, "captured", side_effect=captured),
                mock.patch.object(sys, "argv", ["runner", "--config", str(config)]),
                redirect_stdout(output),
            ):
                if leftover_input or leftover_marker:
                    expected = (
                        "ios_runtime_input_survived" if leftover_input
                        else "ios_restart_marker_survived"
                    )
                    with self.assertRaisesRegex(h.ValidationFailure, expected):
                        ios.main()
                    self.assertFalse(report_path.exists())
                    self.assertNotIn("IOS_VALIDATION_PASS", output.getvalue())
                else:
                    ios.main()
            for container in containers:
                self.assertFalse(
                    (container / "Library/Caches" / ios.INPUT_NAME).exists(),
                )
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            return report, output.getvalue()


if __name__ == "__main__":
    unittest.main()
