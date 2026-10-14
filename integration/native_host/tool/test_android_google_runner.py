"""Private-handoff cleanup boundaries, without a provider/device substitute."""

import unittest
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

import run_android_google_validation as runner


class AndroidGoogleRunnerTests(unittest.TestCase):
    def check_failure_cleanup(self, mode, launch_error):
        calls = []

        class Device:
            identifier = "test-device"

            def stop(self):
                calls.append("stop")

            def must(self, command, **kwargs):
                calls.append(command)
                if "stat" in command:
                    return mode
                return ""

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(runner, "Device", return_value=Device()),
            patch.object(runner, "private_json", return_value={
                "native_validation_identity": "test@example.invalid",
                "server_client_id": "test-client.invalid",
            }),
            patch.object(runner.shutil, "which", return_value="/test/flutter"),
            patch.object(runner.subprocess, "Popen", side_effect=launch_error) as start,
        ):
            host = Path(directory) / "integration/native_host"
            (host / "evidence").mkdir(parents=True)
            evidence = host / "evidence/android-google-exchange-20261014.json"
            evidence.write_text(json.dumps({"success": True}))
            with patch.object(runner.h, "HOST", host):
                with self.assertRaises((runner.h.ValidationFailure, OSError)):
                    runner.main()
            self.assertFalse(json.loads(evidence.read_text())["success"])
        self.assertIn([
            "shell", "run-as", runner.ANDROID_PACKAGE, "rm", "-f", runner.INPUT,
        ], calls)
        self.assertEqual(calls[-1], [
            "shell", "run-as", runner.ANDROID_PACKAGE, "test", "!", "-e", runner.INPUT,
        ])
        return start.call_count

    def test_mode_failure_removes_and_verifies_private_input(self):
        self.assertEqual(self.check_failure_cleanup("644", OSError("unused")), 0)

    def test_process_launch_failure_removes_and_verifies_private_input(self):
        self.assertEqual(self.check_failure_cleanup("600", OSError("unavailable")), 1)


if __name__ == "__main__":
    unittest.main()
