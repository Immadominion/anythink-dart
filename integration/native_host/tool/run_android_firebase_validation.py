#!/usr/bin/env python3
"""Real FCM test on the dedicated host, with private one-use runtime input.

The user handles the notification prompt. The Firebase console sends one test
notification to the privately captured token. No server key, real app data,
device setting changes, UI automation or compiled credentials are used.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
import time

import session_validation_support as h
from run_native_resilience_validation import Device, ANDROID_PACKAGE

INPUT = "cache/anythink-firebase-input.json"
READY = "cache/anythink-firebase-ready.json"
EXPECTED = {
    "real_firebase_initialization_and_token",
    "signed_out_sync_suppressed",
    "ordinary_backend_identity",
    "real_fcm_token_registered_with_backend",
    "duplicate_registration_coalesced",
    "awaiting_console_foreground_message",
    "real_foreground_message_received_via_adapter",
    "explicit_stop_and_backend_logout",
    "test_token_retired_and_private_handoff_removed",
}
OPTIONAL = {"awaiting_user_notification_permission"}


def private_json(path):
    if path.is_symlink() or not path.is_file():
        raise h.ValidationFailure("private_regular_config_required")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise h.ValidationFailure("private_config_mode_required")
    return json.loads(path.read_text())


def main():
    secret_dir = h.HOST.parents[1] / ".secrets"
    config = private_json(secret_dir / "live-contract.json")
    firebase = private_json(secret_dir / "firebase-sdk/google-services.json")
    if config.get("api_origin") != h.ORIGIN or str(config.get("project_id")) != h.PROJECT:
        raise h.ValidationFailure("dedicated_backend_required")
    if firebase["project_info"]["project_id"] != "aura-the-app":
        raise h.ValidationFailure("authorized_firebase_project_required")
    clients = firebase["client"]
    if len(clients) != 1 or clients[0]["client_info"]["android_client_info"]["package_name"] != ANDROID_PACKAGE:
        raise h.ValidationFailure("dedicated_firebase_app_required")
    user = config["users"][0]
    payload = {
        "api_origin": h.ORIGIN,
        "project_id": h.PROJECT,
        "email": user["email"],
        "password": user["password"],
        "firebase": {
            "apiKey": clients[0]["api_key"][0]["current_key"],
            "appId": clients[0]["client_info"]["mobilesdk_app_id"],
            "projectId": firebase["project_info"]["project_id"],
            "messagingSenderId": firebase["project_info"]["project_number"],
        },
    }
    device = Device("android")
    device.stop()
    device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", READY])
    device.must([
        "shell", "run-as", ANDROID_PACKAGE, "sh", "-c",
        shlex.quote("umask 077; cat > " + INPUT),
    ], payload=json.dumps(payload).encode())
    if device.must([
        "shell", "run-as", ANDROID_PACKAGE, "stat", "-c", "%a", INPUT,
    ]).strip() != "600":
        raise h.ValidationFailure("runtime_input_mode_invalid")
    payload.clear()
    config.clear()
    firebase.clear()
    flutter = shutil.which("flutter")
    if not flutter:
        raise h.ValidationFailure("flutter_missing")
    command = [
        flutter, "test", "integration_test/firebase_device_test.dart",
        "--no-pub", "--no-uninstall", "--reporter=expanded", "-d", device.identifier,
    ]
    token_path = secret_dir / "firebase-sdk/device-test-token.json"
    started = time.monotonic()
    report = {
        "platform": "Android", "device": "Seeker", "real_firebase": True,
        "real_anythink_backend": True,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    with tempfile.TemporaryFile() as output_file:
        process = subprocess.Popen(
            command, cwd=h.HOST, stdin=subprocess.DEVNULL, stdout=output_file,
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        announced = False
        observed_gates = set()
        try:
            while process.poll() is None:
                if time.monotonic() - started > 900:
                    raise h.ValidationFailure("firebase_validation_timeout")
                # pread leaves the child writer's shared file offset untouched.
                current_output = os.pread(output_file.fileno(), 32 * 1024 * 1024, 0).decode("utf-8", errors="replace")
                for gate in set(re.findall(r"FIREBASE_GATE_PASS ([a-z_]+)", current_output)) - observed_gates:
                    if gate in EXPECTED | OPTIONAL:
                        print("FIREBASE_GATE_PASS " + gate, flush=True)
                        observed_gates.add(gate)
                if not announced:
                    code, ready = h.captured(device.prefix + [
                        "shell", "run-as", ANDROID_PACKAGE, "cat", READY,
                    ])
                    if not code:
                        try:
                            decoded = json.loads(ready)
                        except json.JSONDecodeError:
                            decoded = None
                        if isinstance(decoded, dict) and decoded.get("stage") == "foreground_ready" and isinstance(decoded.get("token"), str):
                            fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                            with os.fdopen(fd, "w") as stream:
                                json.dump(decoded, stream)
                            os.chmod(token_path, 0o600)
                            report["backend_device_id"] = decoded.get("backend_device_id")
                            announced = True
                            print("FIREBASE_READY private single-device token available for console test", flush=True)
                time.sleep(1)
            output = os.pread(output_file.fileno(), 32 * 1024 * 1024, 0).decode("utf-8", errors="replace")
            gates = set(re.findall(r"FIREBASE_GATE_PASS ([a-z_]+)", output))
            failures = set(re.findall(r"FIREBASE_GATE_FAILED ([a-z_0-9]+)", output))
            report.update({
                "gates": sorted(gates & (EXPECTED | OPTIONAL)),
                "failures": sorted(failures),
                "success": process.returncode == 0 and EXPECTED <= gates and gates <= EXPECTED | OPTIONAL and "All tests passed!" in output,
                "seconds": round(time.monotonic() - started, 1),
            })
            report_path = h.HOST / "evidence/android-firebase-20261014.json"
            report_path.parent.mkdir(parents=True, exist_ok=True)
            if not report["success"]:
                report_path.write_text(json.dumps(report, indent=2) + "\n")
                for failure in sorted(failures):
                    print("FIREBASE_GATE_FAILED " + failure, flush=True)
                raise h.ValidationFailure("firebase_live_validation_failed")
            try:
                device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", INPUT])
                device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", READY])
            except h.ValidationFailure:
                report["success"] = False
                report["failures"] = ["private_handoff_survived"]
                report_path.write_text(json.dumps(report, indent=2) + "\n")
                raise
            apk = h.HOST / "build/app/outputs/flutter-apk/app-debug.apk"
            report["integration_apk_sha256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
            report_path.write_text(json.dumps(report, indent=2) + "\n")
            print("FIREBASE_VALIDATION_PASS real token, registration and foreground delivery", flush=True)
        finally:
            if process.poll() is None:
                h._stop_process_group(process)
            device.stop()
            device.must(["shell", "run-as", ANDROID_PACKAGE, "rm", "-f", INPUT])
            token_path.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except h.ValidationFailure as error:
        print("FIREBASE_VALIDATION_FAILED " + str(error), flush=True)
        raise SystemExit(1) from None
    except Exception:
        print("FIREBASE_VALIDATION_FAILED unexpected_redacted", flush=True)
        raise SystemExit(1) from None
