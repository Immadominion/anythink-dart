#!/usr/bin/env python3
"""Validate real Firebase push on the dedicated, signed sandbox iOS host.

Delivery mode exposes one token in a private local file for the Firebase console.
Rotation mode needs no console message. No private input is compiled into the app.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time

import session_validation_support as h
from run_android_firebase_validation import EXPECTED, OPTIONAL, ROTATION_EXPECTED, private_json
from ios_provider_validation_support import verify_signed_artifact
from run_physical_ios_session_validation import (
    BUNDLE, INPUT_NAME, REMOTE_CACHE, SUBDIRECTORY, Phone, file_names,
    physical_phone, require_private_input, write_private,
)

READY_NAME = "anythink-firebase-ready.json"


def test_passed(code, output, expected):
    gates = set(re.findall(r"FIREBASE_GATE_PASS ([a-z_]+)", output))
    return (
        code == 0 and expected <= gates and gates <= expected | OPTIONAL
        and "FIREBASE_GATE_FAILED " not in output
        and "All tests passed." in output
        and "Application failed to start on attempt:" not in output
    )


def runtime_input(secret_dir, mode):
    config = private_json(secret_dir / "live-contract.json")
    firebase = plistlib.loads((secret_dir / "firebase-sdk/GoogleService-Info.plist").read_bytes())
    if config.get("api_origin") != h.ORIGIN or str(config.get("project_id")) != h.PROJECT:
        raise h.ValidationFailure("dedicated_backend_required")
    if firebase.get("PROJECT_ID") != "aura-the-app" or firebase.get("BUNDLE_ID") != BUNDLE:
        raise h.ValidationFailure("dedicated_firebase_app_required")
    user = config["users"][0]
    return {
        "mode": mode, "api_origin": h.ORIGIN, "project_id": h.PROJECT,
        "email": user["email"], "password": user["password"],
        "firebase": {
            "apiKey": firebase["API_KEY"], "appId": firebase["GOOGLE_APP_ID"],
            "projectId": firebase["PROJECT_ID"],
            "messagingSenderId": firebase["GCM_SENDER_ID"], "iosBundleId": BUNDLE,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("delivery", "rotation"), default="delivery")
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--flutter", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    expected = (EXPECTED if args.mode == "delivery" else ROTATION_EXPECTED) | {"real_apns_token_available"}
    report_path = h.HOST / ("evidence/ios-firebase-" + args.mode + ".json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"success": False, "mode": args.mode, "physical_device": True}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    app, ipa = args.app.resolve(), args.ipa.resolve()
    verify_signed_artifact(app, ipa)
    secret_dir = h.HOST.parents[1] / ".secrets"
    token_path = secret_dir / "firebase-sdk/ios-device-test-token.json"
    if token_path.exists() or token_path.is_symlink():
        raise h.ValidationFailure("preexisting_private_token_handoff")
    payload = runtime_input(secret_dir, args.mode)
    identifier, details = physical_phone()
    phone = Phone(identifier)
    phone.stop_test_app()
    phone.command(["install", "app", str(app)], timeout=180)
    if SUBDIRECTORY in file_names(phone.files("Library/Caches")) and file_names(phone.files(REMOTE_CACHE)):
        raise h.ValidationFailure("preexisting_provider_input")
    with tempfile.TemporaryDirectory(prefix="anythink-ios-firebase-") as temp:
        source, empty = Path(temp) / "input", Path(temp) / "empty"
        source.mkdir(mode=0o700)
        empty.mkdir(mode=0o700)
        write_private(source / INPUT_NAME, payload)
        payload.clear()
        try:
            phone.copy_directory(source)
            require_private_input(phone.files(REMOTE_CACHE))
            command = [args.flutter, "drive", "--no-pub", "--profile",
                       "--driver=test_driver/provider_driver.dart",
                       "--target=integration_test/firebase_device_test.dart",
                       "--use-application-binary=" + str(ipa), "--keep-app-running",
                       "--timeout=600", "-d", details["hardwareProperties"]["udid"]]
            with tempfile.TemporaryFile() as output:
                process = subprocess.Popen(command, cwd=args.workspace / "integration/native_host",
                                           stdin=subprocess.DEVNULL, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                start, observed, announced = time.monotonic(), set(), False
                try:
                    while process.poll() is None:
                        if time.monotonic() - start > 660:
                            raise h.ValidationFailure("firebase_validation_timeout")
                        captured = os.pread(output.fileno(), 32 * 1024 * 1024, 0).decode(errors="replace")
                        for gate in re.findall(r"FIREBASE_GATE_PASS ([a-z_]+)", captured):
                            if gate in expected | OPTIONAL and gate not in observed:
                                print("FIREBASE_GATE_PASS " + gate, flush=True)
                                observed.add(gate)
                        if not announced and "awaiting_console_foreground_message" in observed:
                            local = Path(temp) / READY_NAME
                            phone.command(["copy", "from", "--source", REMOTE_CACHE + "/" + READY_NAME,
                                           "--destination", str(local), "--domain-type", "appDataContainer",
                                           "--domain-identifier", BUNDLE])
                            os.chmod(local, 0o600)
                            ready = json.loads(local.read_text())
                            if ready.get("stage") != "foreground_ready" or not isinstance(ready.get("token"), str) or not ready["token"]:
                                raise h.ValidationFailure("invalid_token_handoff")
                            write_private(token_path, ready)
                            local.unlink()
                            report["backend_device_id"] = ready.get("backend_device_id")
                            announced = True
                            print("FIREBASE_READY private iOS token available for console test", flush=True)
                        time.sleep(1)
                    captured = os.pread(output.fileno(), 32 * 1024 * 1024, 0).decode(errors="replace")
                    gates = set(re.findall(r"FIREBASE_GATE_PASS ([a-z_]+)", captured))
                    failures = set(re.findall(r"FIREBASE_GATE_FAILED ([a-z_0-9]+)", captured))
                    report.update({"gates": sorted(gates & (expected | OPTIONAL)),
                                   "failures": sorted(failures), "seconds": round(time.monotonic() - start, 1)})
                    if not test_passed(process.returncode, captured, expected):
                        for failure in sorted(failures):
                            print("FIREBASE_GATE_FAILED " + failure, flush=True)
                        raise h.ValidationFailure("firebase_live_validation_failed")
                    if file_names(phone.files(REMOTE_CACHE)):
                        raise h.ValidationFailure("private_handoff_survived")
                finally:
                    if process.poll() is None:
                        h._stop_process_group(process)
        finally:
            try:
                phone.stop_test_app()
            finally:
                token_path.unlink(missing_ok=True)
                try:
                    phone.clear_owned_directory(empty)
                finally:
                    report_path.write_text(json.dumps(report, indent=2) + "\n")
    report.update({"success": True, "private_runtime_files_removed": True,
                   "ipa_sha256": hashlib.sha256(ipa.read_bytes()).hexdigest()})
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print("FIREBASE_VALIDATION_PASS ios " + args.mode, flush=True)


if __name__ == "__main__":
    try:
        main()
    except h.ValidationFailure as error:
        print("FIREBASE_VALIDATION_FAILED " + str(error), flush=True)
        raise SystemExit(1) from None
    except Exception:
        print("FIREBASE_VALIDATION_FAILED unexpected_redacted", flush=True)
        raise SystemExit(1) from None
