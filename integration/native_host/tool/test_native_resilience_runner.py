"""Offline runner regressions. No adb, simctl, Flutter or device settings."""

import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest import mock

import run_native_resilience_validation as r


class RecoveryTests(unittest.TestCase):
    def output(self, gates=None):
        return "\n".join(
            "RESILIENCE_GATE_PASS " + gate
            for gate in (r.RECOVER_GATES if gates is None else gates)
        ) + "\nAll tests passed!\n"

    def device(self):
        device = mock.Mock(identifier="synthetic-device")
        device.marker_exists.return_value = False
        return device

    def test_recovery_requires_exact_gates_and_consumed_input(self):
        device = self.device()
        with mock.patch.object(r.h, "captured", return_value=(0, self.output())):
            with mock.patch.object(r, "test_command", return_value=["unused"]):
                result = r.recover_phase(device)
        self.assertEqual(set(result["gates"]), r.RECOVER_GATES)
        device.write_input.assert_called_once_with("recover")
        device.require_input_consumed.assert_called_once_with()
        self.assertNotIn("synthetic-device", json.dumps(result))

    def test_missing_extra_gates_or_failure_exit_never_pass(self):
        cases = [
            (0, self.output(set())),
            (0, self.output(r.RECOVER_GATES | {"unexpected"})),
            (1, self.output()),
            (0, self.output().replace("All tests passed!", "")),
        ]
        for response in cases:
            with self.subTest(response=response):
                with mock.patch.object(r.h, "captured", return_value=response):
                    with mock.patch.object(r, "test_command", return_value=["unused"]):
                        with self.assertRaisesRegex(
                            r.h.ValidationFailure, "recovery_phase_failed",
                        ):
                            r.recover_phase(self.device())

    def test_leftover_marker_refuses_success(self):
        device = self.device()
        device.marker_exists.return_value = True
        with mock.patch.object(r.h, "captured", return_value=(0, self.output())):
            with mock.patch.object(r, "test_command", return_value=["unused"]):
                with self.assertRaisesRegex(
                    r.h.ValidationFailure, "recovery_marker_survived",
                ):
                    r.recover_phase(device)

    def test_unconsumed_runtime_input_refuses_success(self):
        device = self.device()
        device.require_input_consumed.side_effect = r.h.ValidationFailure(
            "runtime_input_survived",
        )
        with mock.patch.object(r.h, "captured", return_value=(0, self.output())):
            with mock.patch.object(r, "test_command", return_value=["unused"]):
                with self.assertRaisesRegex(
                    r.h.ValidationFailure, "runtime_input_survived",
                ):
                    r.recover_phase(device)


class InterruptionTests(unittest.TestCase):
    def test_interruption_stops_actual_child_after_exact_ready_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "marker.json"
            source = (
                "import json,os,pathlib,sys,time; "
                "pathlib.Path(sys.argv[1]).write_text(json.dumps({"
                "'phase':'refresh_held','pid':os.getpid(),"
                "'gates':json.loads(sys.argv[2])})); time.sleep(60)"
            )
            device = mock.Mock()
            device.read_marker.side_effect = lambda: (
                json.loads(marker.read_text()) if marker.exists() else None
            )
            stopped = []

            def stop(*, require_running):
                self.assertTrue(require_running)
                child = json.loads(marker.read_text())["pid"]
                os.kill(child, 0)
                os.kill(child, signal.SIGTERM)
                stopped.append(child)

            device.stop.side_effect = stop
            with mock.patch.object(r.h, "HOST", root):
                with mock.patch.object(r, "test_command", return_value=[
                    sys.executable, "-c", source, str(marker),
                    json.dumps(sorted(r.INTERRUPT_GATES)),
                ]):
                    result = r.interrupt_phase(device)
            self.assertEqual(set(result["gates"]), r.INTERRUPT_GATES)
            self.assertTrue(result["external_app_process_stop"])
            self.assertEqual(len(stopped), 1)
            with self.assertRaises(ProcessLookupError):
                os.kill(stopped[0], 0)
            device.require_input_consumed.assert_called_once_with()


class MarkerTests(unittest.TestCase):
    def test_malformed_marker_is_present_despite_tolerant_polling(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            device = object.__new__(r.Device)
            device.platform = "ios"
            device.ios_cache = lambda: path
            (path / r.MARKER).write_text("{partial")
            self.assertIsNone(device.read_marker())
            self.assertTrue(device.marker_exists())
            (path / r.MARKER).unlink()
            self.assertFalse(device.marker_exists())

    def test_android_presence_check_never_treats_failed_access_as_absence(self):
        device = object.__new__(r.Device)
        device.platform = "android"
        device.prefix = ["unused"]
        with mock.patch.object(r.h, "captured", return_value=(1, "")):
            with self.assertRaisesRegex(r.h.ValidationFailure, "native_command_failed"):
                device.marker_exists()
        for output, expected in [("present", True), ("absent", False)]:
            with mock.patch.object(r.h, "captured", return_value=(0, output)):
                self.assertEqual(device.marker_exists(), expected)


if __name__ == "__main__":
    unittest.main()
