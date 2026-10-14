"""Reject incomplete evidence and clean one-use provider input on launch failure."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_ios_firebase_validation as firebase
import run_ios_native_auth_validation as native


class ProviderRunnerTests(unittest.TestCase):
    def test_firebase_requires_every_gate_and_clean_exit(self):
        expected = firebase.EXPECTED | {"real_apns_token_available"}
        output = "\n".join("FIREBASE_GATE_PASS " + gate for gate in expected)
        output += "\nAll tests passed.\n"
        self.assertTrue(firebase.test_passed(0, output, expected))
        self.assertFalse(firebase.test_passed(1, output, expected))
        self.assertFalse(firebase.test_passed(0, output.replace("All tests passed.", ""), expected))
        for suffix in ("FIREBASE_GATE_FAILED failure", "Application failed to start on attempt: 1",
                       "FIREBASE_GATE_PASS unrecognized"):
            self.assertFalse(firebase.test_passed(0, output + suffix, expected))
        for gate in expected:
            self.assertFalse(firebase.test_passed(0, output.replace("FIREBASE_GATE_PASS " + gate, ""), expected))

    def check_launch_failure(self, runner, *, preexisting=False):
        phone = Mock()
        phone.files.return_value = {"files": []}
        if preexisting:
            phone.files.return_value = {"files": [{"name": runner.SUBDIRECTORY}]}
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            host = root / "integration/native_host"
            host.mkdir(parents=True)
            secret = root / ".secrets/firebase-sdk"
            secret.mkdir(parents=True)
            args = ["runner", "--app", str(root / "app"), "--ipa", str(root / "app.ipa"),
                    "--flutter", "flutter", "--workspace", str(root)]
            if runner is native:
                args += ["--provider", "apple", "--phase", "cancel"]
                config_patch = patch.object(native, "private_json", return_value={
                    "native_validation_identity": "ordinary@example.invalid",
                    "server_client_id": "fixture", "ios_client_id": "fixture",
                })
                report_name = "ios-apple-cancel.json"
            else:
                config_patch = patch.object(firebase, "runtime_input", return_value={"test": "fixture"})
                report_name = "ios-firebase-delivery.json"
            with (
                patch.object(runner.h, "HOST", host),
                patch.object(runner, "verify_signed_artifact"),
                patch.object(runner, "physical_phone", return_value=("device", {"hardwareProperties": {"udid": "device"}})),
                patch.object(runner, "Phone", return_value=phone),
                patch.object(runner, "require_private_input"),
                patch.object(runner.subprocess, "Popen", side_effect=OSError("launch failed")),
                config_patch,
                patch("sys.argv", args),
            ):
                with self.assertRaises((OSError, runner.h.ValidationFailure)):
                    runner.main()
            self.assertFalse(json.loads((host / "evidence" / report_name).read_text())["success"])
            self.assertFalse((secret / "ios-device-test-token.json").exists())
        if preexisting:
            phone.clear_owned_directory.assert_not_called()
        else:
            phone.clear_owned_directory.assert_called_once()
            self.assertEqual(phone.stop_test_app.call_count, 2)

    def test_launch_failure_cleans_both_runners(self):
        for runner in (native, firebase):
            with self.subTest(runner=runner.__name__):
                self.check_launch_failure(runner)

    def test_preexisting_private_state_is_not_deleted(self):
        for runner in (native, firebase):
            with self.subTest(runner=runner.__name__):
                self.check_launch_failure(runner, preexisting=True)


if __name__ == "__main__":
    unittest.main()
