#!/usr/bin/env python3
"""Run SDK session gates with official Flutter and simctl tools.

Only the dedicated SDK host is installed/stopped. The harness does not request
uninstall, simulator erase, settings changes or UI scripting. --no-uninstall
disables Flutter's post-test removal; Flutter still owns installation and may
reinstall the host. Retained phase markers, distinct PIDs and expected Keychain
state are mandatory, so lost app data cannot certify session continuity.
Credentials enter its private cache at mode 0600 and are deleted by the test
before use; no secrets enter build arguments.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import time

import session_validation_support as h

HOST = h.HOST
BUNDLE = "dev.anythink.sdk.anythinkNativeHost"
INPUT_NAME = "anythink-device-input.json"
MARKER_NAME = "anythink-device-state.json"


def must(command, timeout=30):
    code, output = h.captured(command, timeout=timeout)
    if code:
        raise h.ValidationFailure("ios_command_failed")
    return output


def current_cache(device):
    """Resolve afresh: Flutter can replace the app container on installation."""
    raw_path = must([
        "xcrun", "simctl", "get_app_container", device, BUNDLE, "data",
    ]).strip()
    container = Path(raw_path)
    if not container.is_absolute() or not container.is_dir():
        raise h.ValidationFailure("ios_app_container_invalid")
    cache = container / "Library/Caches"
    cache.mkdir(parents=True, exist_ok=True)
    return cache


def read_config(path):
    if path.is_symlink() or not path.is_file():
        raise h.ValidationFailure("private_regular_config_required")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise h.ValidationFailure("private_config_required")
    config = json.loads(path.read_text())
    if (
        config.get("api_origin") != h.ORIGIN
        or str(config.get("project_id")) != h.PROJECT
    ):
        raise h.ValidationFailure("dedicated_project_required")
    users = config.get("users")
    if not isinstance(users, list) or not users or not isinstance(users[0], dict):
        raise h.ValidationFailure("user_credentials_missing")
    if not all(
        isinstance(users[0].get(key), str) and users[0][key]
        for key in ("email", "password")
    ):
        raise h.ValidationFailure("user_credentials_missing")
    return config


def booted_ios_device():
    inventory = json.loads(must([
        "xcrun", "simctl", "list", "devices", "booted", "--json",
    ]))
    devices = [
        (runtime, device)
        for runtime, rows in inventory["devices"].items()
        for device in rows
        if device["state"] == "Booted"
    ]
    if len(devices) != 1:
        raise h.ValidationFailure("exactly_one_booted_simulator_required")
    runtime, device = devices[0]
    version = re.fullmatch(
        r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+(?:-\d+)*)",
        runtime,
    )
    if version is None:
        raise h.ValidationFailure("booted_ios_simulator_required")
    return device["udid"], runtime, "iOS " + version[1].replace("-", ".")


def remove_runtime_inputs(device, known_inputs):
    """Remove only harness input; preserve Keychain and restart evidence."""
    try:
        known_inputs.add(current_cache(device) / INPUT_NAME)
    finally:
        # Even if simctl lookup fails, remove any previously known input.
        for input_file in known_inputs:
            input_file.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(
        description="Validate iOS simulator sessions across three processes.",
    )
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    config = read_config(args.config)
    flutter = shutil.which("flutter")
    if not flutter:
        raise h.ValidationFailure("flutter_missing")
    device, runtime_id, runtime_name = booted_ios_device()
    app = HOST / "build/ios/iphonesimulator/Runner.app"
    artifacts = {
        "runner_binary_sha256": app / "Runner",
        "app_framework_sha256": app / "Frameworks/App.framework/App",
        "dart_kernel_sha256": (
            app / "Frameworks/App.framework/flutter_assets/kernel_blob.bin"
        ),
    }
    if not all(path.is_file() for path in artifacts.values()):
        raise h.ValidationFailure("ios_debug_host_artifact_missing")
    report_path = HOST / "build/ios-device-validation-report.json"
    report_path.unlink(missing_ok=True)
    must(["xcrun", "simctl", "install", device, str(app)], timeout=120)
    known_inputs = set()
    report = {
        "platform": "iOS simulator",
        "runtime": runtime_name,
        "runtime_identifier": runtime_id,
        "physical_device": False,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "phases": [],
    }
    try:
        for phase, required in h.PHASES.items():
            # A nonzero result is normal when the dedicated app has exited.
            h.captured(["xcrun", "simctl", "terminate", device, BUNDLE])
            input_file = current_cache(device) / INPUT_NAME
            known_inputs.add(input_file)
            payload = {
                "phase": phase,
                "api_origin": h.ORIGIN,
                "project_id": h.PROJECT,
            }
            if phase == "establish":
                payload.update({
                    key: config["users"][0][key]
                    for key in ("email", "password")
                })
            fd = os.open(input_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(payload, stream)
            payload.clear()
            config.clear()
            print("IOS_VALIDATION starting " + phase, flush=True)
            start = time.monotonic()
            code, output = h.captured([
                flutter, "test", "integration_test/device_session_test.dart",
                "--no-pub", "--no-uninstall", "--reporter=expanded",
                "-d", device,
                "--dart-define=ANYTHINK_API_ORIGIN=" + h.ORIGIN,
                "--dart-define=ANYTHINK_PROJECT_ID=" + h.PROJECT,
            ], timeout=600)
            gates = set(re.findall(r"DEVICE_GATE_PASS ([a-z_]+)", output))
            for gate in sorted(gates & required):
                print("DEVICE_GATE_PASS " + gate, flush=True)
            if code or gates != required or "All tests passed!" not in output:
                failures = set(re.findall(
                    r"DEVICE_GATE_FAILED ([a-z_0-9]+)", output,
                ))
                for failure in sorted(failures):
                    print("DEVICE_GATE_FAILED " + failure, flush=True)
                raise h.ValidationFailure("ios_phase_failed_" + phase)

            # Never inspect the path from before Flutter's possible reinstall.
            input_file = current_cache(device) / INPUT_NAME
            known_inputs.add(input_file)
            if input_file.exists():
                raise h.ValidationFailure("ios_runtime_input_survived")
            report["phases"].append({
                "phase": phase,
                "gates": sorted(gates),
                "seconds": round(time.monotonic() - start, 1),
            })

        cache = current_cache(device)
        input_file = cache / INPUT_NAME
        known_inputs.add(input_file)
        if input_file.exists():
            raise h.ValidationFailure("ios_runtime_input_survived")
        if (cache / MARKER_NAME).exists():
            raise h.ValidationFailure("ios_restart_marker_survived")
        report.update({
            "completed_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "runtime_input_removed": True,
            "restart_marker_removed": True,
            **{
                label: hashlib.sha256(path.read_bytes()).hexdigest()
                for label, path in artifacts.items()
            },
        })
    finally:
        config.clear()
        try:
            h.captured(["xcrun", "simctl", "terminate", device, BUNDLE])
        finally:
            remove_runtime_inputs(device, known_inputs)
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print("IOS_VALIDATION_PASS all seven simulator gates passed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except h.ValidationFailure as failure:
        print("IOS_VALIDATION_INCOMPLETE " + str(failure), flush=True)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("IOS_VALIDATION_INCOMPLETE interrupted", flush=True)
        raise SystemExit(130)
    except Exception:
        print("IOS_VALIDATION_INCOMPLETE unexpected_redacted", flush=True)
        raise SystemExit(1)
