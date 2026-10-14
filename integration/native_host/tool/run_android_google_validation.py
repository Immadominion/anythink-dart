#!/usr/bin/env python3
"""Real Google chooser validation with a private, single-use runtime input.

Only the user interacts with Google UI. Raw native logs, account identities and
tokens never leave the captured process stream. No credential is compiled.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time

import session_validation_support as h
from run_android_firebase_validation import private_json
from run_native_resilience_validation import Device, ANDROID_PACKAGE

INPUT = "cache/anythink-google-input.json"
DIAGNOSTIC = "cache/anythink-google-error.json"
STAGES = {
    "waiting_for_user_start_cancel",
    "waiting_for_user_start_exchange",
    "cancel_native_chooser",
    "select_only_dedicated_provider_test_account",
}
EXCHANGE_GATES = {
    "native_provider_token_verified_as_ordinary_backend_user",
    "native_provider_session_in_real_secure_store",
    "native_provider_session_refresh_and_identity",
    "native_provider_logout_and_secure_store_clear",
}


def main(phase="exchange"):
    expected = {"real_native_cancel_preserves_signed_out_state"} if phase == "cancel" else EXCHANGE_GATES
    report_path = h.HOST / f"evidence/android-google-{phase}-20261014.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    # An interrupted or failed new attempt must never leave an older pass as
    # the apparent result for this phase.
    report_path.write_text(json.dumps({
        "phase": phase, "success": False, "state": "started_not_completed",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, indent=2) + "\n")
    config = private_json(h.HOST.parents[1] / ".secrets/firebase-sdk/google-oauth-clients.json")
    payload = {
        "phase": phase,
        "expected_user_id": 1548,
        "expected_email": config["native_validation_identity"],
        "server_client_id": config["server_client_id"],
    }
    config.clear()
    flutter = shutil.which("flutter")
    if not flutter:
        raise h.ValidationFailure("flutter_missing")
    device = Device("android")
    report = {
        "platform": "Android", "device": "Seeker", "real_google_provider": True,
        "phase": phase,
        "real_anythink_backend": True, "expected_ordinary_user_id": 1548,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    started = time.monotonic()
    command = [
        flutter, "test", "integration_test/native_sign_in_device_test.dart", "--no-pub",
        "--no-uninstall", "--reporter=expanded", "-d", device.identifier,
    ]
    cleanup_ok = False
    process = None
    input_owned = False
    with tempfile.TemporaryFile() as output_file:
        try:
            device.stop()
            device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", INPUT])
            device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", DIAGNOSTIC])
            input_owned = True
            device.must([
                "shell", "run-as", ANDROID_PACKAGE, "sh", "-c",
                shlex.quote("umask 077; cat > " + INPUT),
            ], payload=json.dumps(payload).encode())
            payload.clear()
            if device.must(["shell", "run-as", ANDROID_PACKAGE, "stat", "-c", "%a", INPUT]).strip() != "600":
                raise h.ValidationFailure("runtime_input_mode_invalid")
            process = subprocess.Popen(
                command, cwd=h.HOST, stdin=subprocess.DEVNULL,
                stdout=output_file, stderr=subprocess.STDOUT, start_new_session=True,
            )
            observed = set()
            while process.poll() is None:
                if time.monotonic() - started > 780:
                    raise h.ValidationFailure("google_validation_timeout")
                output = os.pread(output_file.fileno(), 32 * 1024 * 1024, 0).decode("utf-8", errors="replace")
                markers = set(re.findall(r"NATIVE_AUTH_(STAGE|GATE_PASS) ([a-z_]+)", output))
                for kind, label in markers - observed:
                    if (kind == "STAGE" and label in STAGES) or (kind == "GATE_PASS" and label in expected):
                        print("NATIVE_AUTH_" + kind + " " + label, flush=True)
                        observed.add((kind, label))
                time.sleep(1)
            output = os.pread(output_file.fileno(), 32 * 1024 * 1024, 0).decode("utf-8", errors="replace")
            gates = set(re.findall(r"NATIVE_AUTH_GATE_PASS ([a-z_]+)", output))
            failures = set(re.findall(r"NATIVE_AUTH_GATE_FAILED ([a-z_0-9]+)", output))
            report.update({
                "gates": sorted(gates & expected), "failures": sorted(failures),
                "success": process.returncode == 0 and not failures and gates == expected and "All tests passed!" in output,
                "seconds": round(time.monotonic() - started, 1),
            })
            for failure in sorted(failures):
                print("NATIVE_AUTH_GATE_FAILED " + failure, flush=True)
            code, diagnostic = h.captured(device.prefix + [
                "shell", "run-as", ANDROID_PACKAGE, "cat", DIAGNOSTIC,
            ])
            if not code:
                # The host has already redacted emails, bearer strings and
                # token/opaque-identifier-shaped values before this transfer.
                decoded = json.loads(diagnostic)
                path = h.HOST.parents[1] / ".secrets/firebase-sdk/google-last-error.json"
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as stream:
                    json.dump(decoded, stream)
                os.chmod(path, 0o600)
                print("GOOGLE_PRIVATE_REDACTED_DIAGNOSTIC_AVAILABLE", flush=True)
            if not report["success"]:
                report_path.write_text(json.dumps(report, indent=2) + "\n")
                print("GOOGLE_FLUTTER_EXIT " + str(process.returncode), flush=True)
                for marker in ["BUILD FAILED", "Failed to install", "Error launching application", "Lost connection to device", "TimeoutException"]:
                    if marker in output:
                        print("GOOGLE_HOST_FAILURE " + marker.replace(" ", "_").lower(), flush=True)
                for code in sorted(set(re.findall(r"\bINSTALL_FAILED_[A-Z_]+\b", output))):
                    print("GOOGLE_HOST_INSTALL_CODE " + code, flush=True)
                if "adb shell failed to write the SHA hash" in output:
                    print("GOOGLE_HOST_FAILURE install_hash_write", flush=True)
            device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", INPUT])
        finally:
            payload.clear()
            try:
                if process is not None and process.poll() is None:
                    h._stop_process_group(process)
            finally:
                try:
                    device.stop()
                finally:
                    if input_owned:
                        try:
                            device.must(["shell", "run-as", ANDROID_PACKAGE, "rm", "-f", DIAGNOSTIC])
                            device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", DIAGNOSTIC])
                        finally:
                            device.must(["shell", "run-as", ANDROID_PACKAGE, "rm", "-f", INPUT])
                            device.must(["shell", "run-as", ANDROID_PACKAGE, "test", "!", "-e", INPUT])
                        cleanup_ok = True
    report["private_runtime_input_removed"] = cleanup_ok
    apk = h.HOST / "build/app/outputs/flutter-apk/app-debug.apk"
    report["integration_apk_sha256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    if not report["success"]:
        raise h.ValidationFailure("google_live_validation_failed")
    print("GOOGLE_VALIDATION_PASS " + phase, flush=True)


if __name__ == "__main__":
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("phase", choices=["cancel", "exchange"])
        main(parser.parse_args().phase)
    except h.ValidationFailure as error:
        print("GOOGLE_VALIDATION_FAILED " + str(error), flush=True)
        raise SystemExit(1) from None
    except Exception:
        print("GOOGLE_VALIDATION_FAILED unexpected_redacted", flush=True)
        raise SystemExit(1) from None
