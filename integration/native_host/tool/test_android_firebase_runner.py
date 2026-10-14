"""Check cleanup on failures before the native provider test starts."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_android_firebase_validation as runner


class FirebaseRunnerTests(unittest.TestCase):
    def check_failure(self, *, mode="600", preexisting=False):
        device = Mock(identifier="test-device")

        def command(arguments, **kwargs):
            if preexisting and "test" in arguments:
                raise runner.h.ValidationFailure("existing_input")
            return mode if "stat" in arguments else ""

        device.must.side_effect = command
        config = {
            "api_origin": runner.h.ORIGIN, "project_id": runner.h.PROJECT,
            "users": [{"email": "test@example.invalid", "password": "fixture"}],
        }
        firebase = {
            "project_info": {"project_id": "aura-the-app", "project_number": "fixture"},
            "client": [{
                "client_info": {
                    "android_client_info": {"package_name": runner.ANDROID_PACKAGE},
                    "mobilesdk_app_id": "fixture",
                },
                "api_key": [{"current_key": "fixture"}],
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            host = Path(directory) / "integration/native_host"
            report = host / "evidence/android-firebase-rotation-20261014.json"
            report.parent.mkdir(parents=True)
            report.write_text('{"success":true}')
            with (
                patch.object(runner.h, "HOST", host),
                patch.object(runner, "Device", return_value=device),
                patch.object(runner, "private_json", side_effect=[config, firebase]),
                patch.object(runner.shutil, "which", return_value="flutter"),
                patch.object(runner.subprocess, "Popen", side_effect=OSError("launch")),
                patch("sys.argv", ["runner", "--mode", "rotation"]),
            ):
                with self.assertRaises((runner.h.ValidationFailure, OSError)):
                    runner.main()
            self.assertFalse(json.loads(report.read_text())["success"])
        return [call.args[0] for call in device.must.call_args_list]

    def test_launch_failure_removes_private_runtime_files(self):
        calls = self.check_failure()
        for path in (runner.INPUT, runner.READY):
            self.assertIn(["shell", "run-as", runner.ANDROID_PACKAGE, "rm", "-f", path], calls)
        self.assertEqual(calls[-1][-4:], ["test", "!", "-e", runner.READY])

    def test_invalid_permissions_also_clean_up(self):
        calls = self.check_failure(mode="644")
        self.assertTrue(any("rm" in call for call in calls))

    def test_preexisting_input_is_never_removed(self):
        calls = self.check_failure(preexisting=True)
        self.assertFalse(any("rm" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
