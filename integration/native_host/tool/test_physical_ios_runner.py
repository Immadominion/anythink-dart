"""Local negative checks for the physical runner's file/privacy boundaries."""

from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch

import run_physical_ios_session_validation as runner


class PhysicalIosRunnerTest(unittest.TestCase):
    def test_retried_launch_cannot_certify_a_phase(self):
        output = "DEVICE_GATE_PASS password_sign_in\nAll tests passed.\n"
        required = {"password_sign_in"}
        self.assertTrue(runner.phase_passed(0, output, required))
        self.assertFalse(runner.phase_passed(0, "Application failed to start on attempt: 1\n" + output, required))

    def test_drive_keeps_app_installed_for_process_restart_proof(self):
        command = runner.drive_command("flutter", Path("signed.ipa"), "profile", "synthetic-device")
        self.assertIn("--keep-app-running", command)
        self.assertNotIn("--no-keep-app-running", command)
        self.assertIn("--use-application-binary=signed.ipa", command)

    def test_early_setup_failure_replaces_stale_success_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            host = Path(temp)
            (host / "evidence").mkdir()
            report = host / "evidence/ios-physical-session-20261014.json"
            report.write_text('{"success": true}')
            with patch.object(runner.h, "HOST", host), patch.object(
                runner, "read_config", side_effect=runner.h.ValidationFailure("invalid_config"),
            ), patch("sys.argv", [
                "runner", "--config", "unused", "--app", "unused", "--ipa", "unused",
            ]):
                with self.assertRaises(runner.h.ValidationFailure):
                    runner.main()
            observed = json.loads(report.read_text())
            self.assertFalse(observed["success"])
            self.assertEqual(observed["status"], "setup_started")

    def test_refuses_file_listing_paths(self):
        with self.assertRaises(runner.h.ValidationFailure):
            runner.file_names({"files": [{"name": "../outside"}]})

    def test_requires_private_regular_runtime_input(self):
        row = {
            "name": runner.INPUT_NAME,
            "metadata": {"permissions": 0o600},
            "resources": {"isDirectory": False, "isSymbolicLink": False},
        }
        runner.require_private_input({"files": [row]})
        for invalid in (0o644, 0o666, None):
            row["metadata"]["permissions"] = invalid
            with self.assertRaises(runner.h.ValidationFailure):
                runner.require_private_input({"files": [row]})

    def test_refuses_symlink_runtime_input(self):
        with self.assertRaises(runner.h.ValidationFailure):
            runner.require_private_input({"files": [{
                "name": runner.INPUT_NAME,
                "metadata": {"permissions": 0o600},
                "resources": {"isDirectory": False, "isSymbolicLink": True},
            }]})

    def test_empty_copy_error_requires_independent_absence_evidence(self):
        phone = runner.Phone("synthetic-device")
        with tempfile.TemporaryDirectory() as temp, patch.object(
            phone, "copy_directory", side_effect=runner.h.ValidationFailure("copy_failed"),
        ), patch.object(phone, "files", return_value={"files": []}) as read:
            phone.clear_owned_directory(Path(temp))
            read.assert_called_once_with("Library/Caches")

    def test_copy_success_does_not_hide_surviving_input(self):
        phone = runner.Phone("synthetic-device")
        with tempfile.TemporaryDirectory() as temp, patch.object(
            phone, "copy_directory",
        ), patch.object(phone, "files", side_effect=[
            {"files": [{"name": runner.SUBDIRECTORY}]},
            {"files": [{"name": runner.INPUT_NAME}]},
        ]):
            with self.assertRaises(runner.h.ValidationFailure):
                phone.clear_owned_directory(Path(temp))

    def test_rejects_unapproved_device_file_path_before_command(self):
        phone = runner.Phone("synthetic-device")
        with patch.object(phone, "command") as command:
            with self.assertRaises(runner.h.ValidationFailure):
                phone.files("Documents")
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
