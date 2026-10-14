#!/usr/bin/env python3
"""Run native authentication on the dedicated, pre-signed physical iOS host.

The user handles the provider sheet. Runtime input stays in the test app's
private cache. This runner does not create credentials or change signing.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

import session_validation_support as h
from run_android_firebase_validation import private_json
from ios_provider_validation_support import verify_signed_artifact
from run_physical_ios_session_validation import (
    INPUT_NAME, REMOTE_CACHE, SUBDIRECTORY, Phone, file_names,
    physical_phone, require_private_input, write_private,
)

CANCEL_GATES = {"real_native_cancel_preserves_signed_out_state"}
EXCHANGE_GATES = {
    "native_provider_token_verified_as_ordinary_backend_user",
    "native_provider_session_in_real_secure_store",
    "native_provider_session_refresh_and_identity",
    "native_provider_logout_and_secure_store_clear",
}
STAGES = {
    "waiting_for_user_start_cancel", "waiting_for_user_start_exchange",
    "cancel_native_chooser", "select_only_dedicated_provider_test_account",
}



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=("google", "apple"), required=True)
    parser.add_argument("--phase", choices=("cancel", "exchange"), required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--flutter", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    args = parser.parse_args()
    # An ordinary Apple test identity must be selected before enabling exchange.
    if args.provider == "apple" and args.phase != "cancel":
        raise h.ValidationFailure("ordinary_apple_identity_not_configured")
    expected = CANCEL_GATES if args.phase == "cancel" else EXCHANGE_GATES
    report_path = h.HOST / ("evidence/ios-" + args.provider + "-" + args.phase + ".json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"success": False, "provider": args.provider, "phase": args.phase,
              "physical_device": True, "status": "setup_started"}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    app, ipa = args.app.resolve(), args.ipa.resolve()
    verify_signed_artifact(app, ipa)
    identifier, details = physical_phone()
    phone = Phone(identifier)
    phone.stop_test_app()
    phone.command(["install", "app", str(app)], timeout=180)
    if SUBDIRECTORY in file_names(phone.files("Library/Caches")) and file_names(phone.files(REMOTE_CACHE)):
        raise h.ValidationFailure("preexisting_provider_input")
    config = private_json(h.HOST.parents[1] / ".secrets/firebase-sdk/google-oauth-clients.json")
    payload = {
        "provider": args.provider, "phase": args.phase, "expected_user_id": 1548,
        "expected_email": config["native_validation_identity"],
        "server_client_id": config["server_client_id"],
        "ios_client_id": config["ios_client_id"],
    }
    with tempfile.TemporaryDirectory(prefix="anythink-ios-provider-") as temp:
        source, empty = Path(temp) / "input", Path(temp) / "empty"
        source.mkdir(mode=0o700)
        empty.mkdir(mode=0o700)
        write_private(source / INPUT_NAME, payload)
        try:
            phone.copy_directory(source)
            require_private_input(phone.files(REMOTE_CACHE))
            command = [args.flutter, "drive", "--no-pub", "--profile",
                       "--driver=test_driver/provider_driver.dart",
                       "--target=integration_test/native_sign_in_device_test.dart",
                       "--use-application-binary=" + str(ipa), "--keep-app-running",
                       "--timeout=600", "-d", details["hardwareProperties"]["udid"]]
            with tempfile.TemporaryFile() as output:
                process = subprocess.Popen(command, cwd=args.workspace / "integration/native_host",
                                           stdin=subprocess.DEVNULL, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                start, observed = time.monotonic(), set()
                try:
                    while process.poll() is None:
                        if time.monotonic() - start > 660:
                            raise h.ValidationFailure("native_provider_timeout")
                        captured = os.pread(output.fileno(), 32 * 1024 * 1024, 0).decode(errors="replace")
                        for stage in re.findall(r"NATIVE_AUTH_STAGE ([a-z_]+)", captured):
                            if stage in STAGES and stage not in observed:
                                print("NATIVE_AUTH_STAGE " + stage, flush=True)
                                observed.add(stage)
                        time.sleep(1)
                    captured = os.pread(output.fileno(), 32 * 1024 * 1024, 0).decode(errors="replace")
                    gates = set(re.findall(r"NATIVE_AUTH_GATE_PASS ([a-z_]+)", captured))
                    failures = set(re.findall(r"NATIVE_AUTH_GATE_FAILED ([a-z_0-9]+)", captured))
                    report.update({"gates": sorted(gates & expected), "failures": sorted(failures),
                                   "seconds": round(time.monotonic() - start, 1)})
                    if (process.returncode or gates != expected or failures or
                            "All tests passed." not in captured or
                            "Application failed to start on attempt:" in captured):
                        raise h.ValidationFailure("native_provider_check_failed")
                    if file_names(phone.files(REMOTE_CACHE)):
                        raise h.ValidationFailure("runtime_input_not_consumed")
                finally:
                    if process.poll() is None:
                        h._stop_process_group(process)
        finally:
            try:
                phone.stop_test_app()
            finally:
                phone.clear_owned_directory(empty)
                report_path.write_text(json.dumps(report, indent=2) + "\n")
    report.update({"success": True, "private_input_removed": True,
                   "ipa_sha256": hashlib.sha256(ipa.read_bytes()).hexdigest()})
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print("NATIVE_AUTH_VALIDATION_PASS " + args.provider + " " + args.phase, flush=True)


if __name__ == "__main__":
    try:
        main()
    except h.ValidationFailure as error:
        print("NATIVE_AUTH_VALIDATION_FAILED " + str(error), flush=True)
        raise SystemExit(1) from None
    except Exception:
        print("NATIVE_AUTH_VALIDATION_FAILED unexpected_redacted", flush=True)
        raise SystemExit(1) from None
