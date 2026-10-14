#!/usr/bin/env python3
"""Run real session checks through Flutter's official integration_test runner.

Only this dedicated debug app is installed/stopped. The harness does not request
data wipes, settings changes, UI scripting, provisioning, or personal app access.
--no-uninstall disables Flutter's post-test removal, not its Android installation
fallback: a failed install can still trigger uninstall/reinstall. Each restart
phase requires the retained phase marker, a new PID and the expected native-store
state before logout emptiness can pass; lost app data cannot certify continuity.
Credentials travel from a mode-0600 file over ADB stdin to the app-private cache.
They never appear in build defines, process arguments, test reports, or output.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import stat
import sys
import time


from session_validation_support import (
    HOST,
    ORIGIN,
    PROJECT,
    PHASES,
    ValidationFailure,
    captured,
)

PACKAGE = "dev.anythink.sdk.anythink_native_host"
INPUT = "cache/anythink-device-input.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    mode = args.config.stat().st_mode
    if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != 0o600:
        raise ValidationFailure("config_requires_private_regular_file")
    if args.config.is_symlink():
        raise ValidationFailure("config_symlink_forbidden")
    config = json.loads(args.config.read_text())
    if config.get("api_origin") != ORIGIN or str(config.get("project_id")) != PROJECT:
        raise ValidationFailure("dedicated_project_required")
    user = config["users"][0]
    if not all(isinstance(user.get(k), str) and user[k] for k in ("email", "password")):
        raise ValidationFailure("user_credentials_missing")
    adb = shutil.which("adb") or str(
        Path.home() / "Library/Android/sdk/platform-tools/adb"
    )
    flutter = shutil.which("flutter")
    if not flutter:
        raise ValidationFailure("flutter_missing")
    code, inventory = captured([adb, "devices"])
    if code:
        raise ValidationFailure("adb_inventory_failed")
    devices = [
        parts[0]
        for line in inventory.splitlines()
        if len(parts := line.split()) == 2 and parts[1] == "device"
    ]
    if len(devices) != 1:
        raise ValidationFailure("exactly_one_authorized_device_required")
    serial = devices[0]  # Kept in memory, never printed or written to a report.
    prefix = [adb, "-s", serial]
    code, model = captured(prefix + ["shell", "getprop", "ro.product.model"])
    if code or model.strip() != "Seeker":
        raise ValidationFailure("seeker_required")
    apk = HOST / "build/app/outputs/flutter-apk/app-debug.apk"
    if not apk.is_file():
        raise ValidationFailure("configured_host_apk_missing")
    print("DEVICE_VALIDATION installing dedicated debug host", flush=True)
    code, output = captured(prefix + ["install", "-r", str(apk)], timeout=120)
    if code or "Success" not in output:
        raise ValidationFailure("host_install_failed")
    report = {
        "device_model": "Seeker",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "phases": [],
    }
    try:
        for phase, required_gates in PHASES.items():
            print(f"DEVICE_VALIDATION starting {phase}", flush=True)
            code, _ = captured(prefix + ["shell", "am", "force-stop", PACKAGE])
            if code:
                raise ValidationFailure("host_force_stop_failed")
            code, process_ids = captured(prefix + ["shell", "pidof", PACKAGE])
            if code == 0 or process_ids.strip():
                raise ValidationFailure("host_process_still_alive")
            runtime = {"phase": phase, "api_origin": ORIGIN, "project_id": PROJECT}
            if phase == "establish":
                runtime.update({"email": user["email"], "password": user["password"]})
            payload = json.dumps(runtime).encode()
            code, _ = captured(
                prefix + [
                    "shell", "run-as", PACKAGE, "sh", "-c",
                    shlex.quote(f"umask 077; cat > {INPUT}"),
                ],
                payload=payload,
            )
            del payload
            runtime.clear()
            if code:
                raise ValidationFailure("private_runtime_transfer_failed")
            code, file_mode = captured(
                prefix + ["shell", "run-as", PACKAGE, "stat", "-c", "%a", INPUT]
            )
            if code or file_mode.strip() != "600":
                raise ValidationFailure("runtime_file_permissions_invalid")
            command = [
                flutter, "test", "integration_test/device_session_test.dart",
                "--no-pub", "--no-uninstall", "--reporter=expanded", "-d", serial,
                f"--dart-define=ANYTHINK_API_ORIGIN={ORIGIN}",
                f"--dart-define=ANYTHINK_PROJECT_ID={PROJECT}",
            ]
            start = time.monotonic()
            code, output = captured(command, timeout=600)
            gates = set(re.findall(r"DEVICE_GATE_PASS ([a-z_]+)", output))
            failures = set(re.findall(r"DEVICE_GATE_FAILED ([a-z_0-9]+)", output))
            for gate in sorted(gates & required_gates):
                print(f"DEVICE_GATE_PASS {gate}", flush=True)
            if code or gates != required_gates or "All tests passed!" not in output:
                # Only the allowlisted static failure format crosses this boundary.
                for failure in sorted(failures):
                    print(f"DEVICE_GATE_FAILED {failure}", flush=True)
                raise ValidationFailure(f"phase_failed_{phase}")
            code, _ = captured(
                prefix + ["shell", "run-as", PACKAGE, "test", "!", "-e", INPUT]
            )
            if code:
                raise ValidationFailure("runtime_input_survived_test")
            report["phases"].append({
                "phase": phase,
                "gates": sorted(gates),
                "seconds": round(time.monotonic() - start, 1),
            })
        report["completed_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        report["integration_apk_sha256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
        report["integration_apk_bytes"] = apk.stat().st_size
        report_path = HOST / "build/device-validation-report.json"
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        print("DEVICE_VALIDATION_PASS all seven real-device gates passed", flush=True)
    finally:
        # Our cleanup deletes only the one-use input and stops the process.
        # A storage wipe/uninstall would not prove that SDK logout cleared it;
        # the mandatory phase markers protect the oracle from such data loss.
        captured(prefix + ["shell", "run-as", PACKAGE, "rm", "-f", INPUT])
        captured(prefix + ["shell", "am", "force-stop", PACKAGE])


if __name__ == "__main__":
    try:
        main()
    except ValidationFailure as failure:
        print(f"DEVICE_VALIDATION_INCOMPLETE {failure}", flush=True)
        sys.exit(1)
    except KeyboardInterrupt:
        print("DEVICE_VALIDATION_INCOMPLETE interrupted", flush=True)
        sys.exit(130)
    except Exception:
        print("DEVICE_VALIDATION_INCOMPLETE unexpected_redacted", flush=True)
        sys.exit(1)
