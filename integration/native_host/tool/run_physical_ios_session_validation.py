#!/usr/bin/env python3
"""Run the existing session phases on one physical iPhone using a signed IPA.

The binary must already be signed. This runner never provisions, changes device
settings, uninstalls an app, or accesses another application's data. Credentials
enter only the dedicated test app's isolated cache directory and are consumed by
the test before authentication. All device/process output remains captured.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import time
from urllib.parse import unquote, urlparse
import zipfile

import session_validation_support as h
from run_ios_session_validation import read_config

BUNDLE = "dev.anythink.sdk.anythinkNativeHost"
SUBDIRECTORY = "anythink-physical-session"
REMOTE_CACHE = "Library/Caches/" + SUBDIRECTORY
INPUT_NAME = "anythink-device-input.json"
MARKER_NAME = "anythink-device-state.json"


def device_json(arguments, *, timeout=60):
    with tempfile.TemporaryDirectory(prefix="anythink-ios-command-") as temp:
        result_path = Path(temp) / "result.json"
        code, _ = h.captured([
            "xcrun", "devicectl", *arguments,
            "--timeout", str(timeout), "--json-output", str(result_path),
        ], timeout=timeout + 10)
        if code or not result_path.is_file():
            raise h.ValidationFailure("physical_ios_command_failed")
        result = json.loads(result_path.read_text())
        if "error" in result or not isinstance(result.get("result"), dict):
            raise h.ValidationFailure("physical_ios_command_result_invalid")
        return result["result"]


def physical_phone():
    inventory = device_json(["list", "devices"])
    devices = [
        device for device in inventory.get("devices", [])
        if device.get("hardwareProperties", {}).get("reality") == "physical"
        and device.get("hardwareProperties", {}).get("platform") == "iOS"
    ]
    if len(devices) != 1:
        raise h.ValidationFailure("exactly_one_physical_iphone_required")
    identifier = devices[0]["identifier"]
    details = device_json([
        "device", "info", "details", "--device", identifier,
    ])
    properties = details.get("deviceProperties", {})
    connection = details.get("connectionProperties", {})
    if (
        properties.get("developerModeStatus") != "enabled"
        or not properties.get("ddiServicesAvailable")
        or connection.get("pairingState") != "paired"
    ):
        raise h.ValidationFailure("physical_iphone_not_ready")
    return identifier, details


class Phone:
    def __init__(self, identifier):
        self.identifier = identifier

    def command(self, arguments, *, timeout=60):
        return device_json([
            "device", *arguments, "--device", self.identifier,
        ], timeout=timeout)

    def files(self, subdirectory):
        if subdirectory not in ("Library/Caches", REMOTE_CACHE):
            raise h.ValidationFailure("unsafe_cache_path")
        return self.command([
            "info", "files", "--domain-type", "appDataContainer",
            "--domain-identifier", BUNDLE,
            "--subdirectory", subdirectory, "--no-recurse",
        ])

    def copy_directory(self, source, *, remove_existing=False):
        if not source.is_dir() or source.is_symlink():
            raise h.ValidationFailure("regular_input_directory_required")
        return self.command([
            "copy", "to", "--domain-type", "appDataContainer",
            "--domain-identifier", BUNDLE, "--source", str(source),
            "--destination", REMOTE_CACHE,
            "--remove-existing-content", str(remove_existing).lower(),
        ])

    def clear_owned_directory(self, empty_source):
        # CoreDevice can remove the destination and then report 7000 because an
        # empty source produces no destination node. Verify the resulting state
        # instead of treating that transport result alone as cleanup evidence.
        try:
            self.copy_directory(empty_source, remove_existing=True)
        except h.ValidationFailure:
            pass
        root_names = file_names(self.files("Library/Caches"))
        if SUBDIRECTORY in root_names and file_names(self.files(REMOTE_CACHE)):
            raise h.ValidationFailure("test_directory_not_empty")

    def stop_test_app(self):
        apps = self.command(["info", "apps", "--bundle-id", BUNDLE])["apps"]
        if not apps:
            return
        if len(apps) != 1:
            raise h.ValidationFailure("ambiguous_test_app")
        app_url = apps[0]["url"]
        app_path = "/" + unquote(urlparse(app_url).path).strip("/") + "/"
        if not app_path.startswith("/private/var/"):
            raise h.ValidationFailure("unexpected_test_app_location")
        processes = self.command([
            "info", "processes", "--filter",
            "executable.path BEGINSWITH '" + app_path + "'",
        ])["runningProcesses"]
        for process in processes:
            executable = "/" + unquote(urlparse(process["executable"]).path).lstrip("/")
            if not executable.startswith(app_path):
                raise h.ValidationFailure("unexpected_process_selection")
            self.command([
                "process", "terminate", "--pid",
                str(process["processIdentifier"]),
            ])


def file_names(result):
    rows = result.get("files")
    if not isinstance(rows, list):
        raise h.ValidationFailure("file_listing_shape_unrecognized")
    names = set()
    for row in rows:
        name = row.get("name")
        if not isinstance(name, str) or not name or "/" in name:
            raise h.ValidationFailure("file_listing_name_invalid")
        names.add(name)
    return names


def write_private(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream)


def require_private_input(result):
    matches = [row for row in result.get("files", []) if row.get("name") == INPUT_NAME]
    if len(matches) != 1:
        raise h.ValidationFailure("runtime_input_copy_unconfirmed")
    row = matches[0]
    if (
        row.get("metadata", {}).get("permissions") != 0o600
        or row.get("resources", {}).get("isDirectory") is not False
        or row.get("resources", {}).get("isSymbolicLink") is not False
    ):
        raise h.ValidationFailure("runtime_input_not_private_regular_file")


def drive_command(flutter, ipa, mode, device_udid):
    # FlutterDriveService.stop uninstalls the app, so keep it running here and
    # let Phone.stop_test_app perform only an exact-process stop between phases.
    return [
        flutter, "drive", "--no-pub", "--" + mode,
        "--driver=test_driver/physical_session_driver.dart",
        "--target=integration_test/device_session_test.dart",
        "--use-application-binary=" + str(ipa),
        "--keep-app-running", "--timeout=300", "-d", device_udid,
    ]


def phase_passed(code, output, required):
    gates = set(re.findall(r"DEVICE_GATE_PASS ([a-z_]+)", output))
    return (
        code == 0
        and gates == required
        and "DEVICE_GATE_FAILED " not in output
        and "Application failed to start on attempt:" not in output
        and "All tests passed." in output
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--mode", choices=("debug", "profile"), default="profile")
    args = parser.parse_args()
    report_path = h.HOST / "evidence/ios-physical-session-20261014.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps({
        "success": False,
        "status": "setup_started",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, indent=2) + "\n")
    config = read_config(args.config)
    flutter = shutil.which("flutter")
    if flutter is None:
        raise h.ValidationFailure("flutter_missing")
    app = args.app.resolve()
    ipa = args.ipa.resolve()
    if not app.is_dir() or not ipa.is_file():
        raise h.ValidationFailure("signed_app_and_ipa_required")
    if plistlib.loads((app / "Info.plist").read_bytes()).get("CFBundleIdentifier") != BUNDLE:
        raise h.ValidationFailure("dedicated_test_app_required")
    with zipfile.ZipFile(ipa) as archive:
        if plistlib.loads(archive.read("Payload/Runner.app/Info.plist")).get("CFBundleIdentifier") != BUNDLE:
            raise h.ValidationFailure("dedicated_test_ipa_required")
        for relative in ("Runner", "Frameworks/App.framework/App"):
            if hashlib.sha256((app / relative).read_bytes()).digest() != hashlib.sha256(
                archive.read("Payload/Runner.app/" + relative),
            ).digest():
                raise h.ValidationFailure("app_and_ipa_binary_mismatch")
    code, _ = h.captured(["codesign", "--verify", "--deep", "--strict", str(app)])
    if code:
        raise h.ValidationFailure("signed_app_verification_failed")
    identifier, details = physical_phone()
    phone = Phone(identifier)
    phone.command(["install", "app", str(app)], timeout=180)
    root_names = file_names(phone.files("Library/Caches"))
    if SUBDIRECTORY in root_names and file_names(phone.files(REMOTE_CACHE)):
        raise h.ValidationFailure("preexisting_physical_test_state")
    report = {
        "platform": "iOS", "physical_device": True,
        "build_mode": args.mode,
        "device_model": details["hardwareProperties"].get("marketingName"),
        "os_version": details["deviceProperties"].get("osVersionNumber"),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "real_anythink_backend": True,
        "locked_device_tested": False,
        "provider_push_purchase_flows_tested": False,
        "phases": [], "success": False,
        "ipa_sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
    }
    owned_directory = False
    failure = None
    with tempfile.TemporaryDirectory(prefix="anythink-ios-input-") as temp:
        temp_path = Path(temp)
        source = temp_path / "input"
        empty = temp_path / "empty"
        source.mkdir(mode=0o700)
        empty.mkdir(mode=0o700)
        try:
            for phase, required in h.PHASES.items():
                phone.stop_test_app()
                payload = {
                    "phase": phase, "api_origin": h.ORIGIN,
                    "project_id": h.PROJECT,
                }
                if phase == "establish":
                    payload.update({
                        key: config["users"][0][key]
                        for key in ("email", "password")
                    })
                input_path = source / INPUT_NAME
                write_private(input_path, payload)
                payload.clear()
                config.clear()
                owned_directory = True
                phone.copy_directory(source)
                input_path.unlink()
                require_private_input(phone.files(REMOTE_CACHE))
                print("PHYSICAL_IOS_VALIDATION starting " + phase, flush=True)
                started = time.monotonic()
                code, output = h.captured(drive_command(
                    flutter, ipa, args.mode,
                    details["hardwareProperties"]["udid"],
                ), timeout=480)
                gates = set(re.findall(r"DEVICE_GATE_PASS ([a-z_]+)", output))
                failures = set(re.findall(r"DEVICE_GATE_FAILED ([a-z_0-9]+)", output))
                for gate in sorted(gates & required):
                    print("DEVICE_GATE_PASS " + gate, flush=True)
                for label in sorted(failures):
                    print("DEVICE_GATE_FAILED " + label, flush=True)
                if not phase_passed(code, output, required):
                    report["failed_phase_observation"] = {
                        "flutter_exit_code": code,
                        "gates": sorted(gates & required),
                        "failed_gates": sorted(failures),
                        "debug_service_connection_closed": "Connection closed before full header" in output,
                        "launch_retried": "Application failed to start on attempt:" in output,
                    }
                    raise h.ValidationFailure("physical_ios_phase_failed_" + phase)
                if INPUT_NAME in file_names(phone.files(REMOTE_CACHE)):
                    raise h.ValidationFailure("runtime_input_survived")
                report["phases"].append({
                    "phase": phase, "gates": sorted(gates),
                    "seconds": round(time.monotonic() - started, 1),
                })
            if file_names(phone.files(REMOTE_CACHE)):
                raise h.ValidationFailure("runtime_test_state_survived")
            report["success"] = True
        except h.ValidationFailure as error:
            failure = error
            report["failure"] = str(error)
        finally:
            config.clear()
            cleanup_failed = False
            try:
                phone.stop_test_app()
            except Exception:
                cleanup_failed = True
            if owned_directory:
                try:
                    names = file_names(phone.files(REMOTE_CACHE))
                    if not names.issubset({INPUT_NAME, MARKER_NAME}):
                        raise h.ValidationFailure("unexpected_test_directory_content")
                    phone.clear_owned_directory(empty)
                except Exception:
                    cleanup_failed = True
            report["private_runtime_input_removed"] = owned_directory and not cleanup_failed
            if cleanup_failed:
                report["success"] = False
                report["cleanup_failure"] = "test_app_or_directory_cleanup_unconfirmed"
                failure = h.ValidationFailure("physical_ios_cleanup_unconfirmed")
            report["completed_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            report_path.write_text(json.dumps(report, indent=2) + "\n")
    if failure:
        raise failure
    print("PHYSICAL_IOS_VALIDATION_PASS all seven real device gates", flush=True)


if __name__ == "__main__":
    try:
        main()
    except h.ValidationFailure as error:
        print("PHYSICAL_IOS_VALIDATION_INCOMPLETE " + str(error), flush=True)
        raise SystemExit(1) from None
    except KeyboardInterrupt:
        print("PHYSICAL_IOS_VALIDATION_INCOMPLETE interrupted", flush=True)
        raise SystemExit(130) from None
    except Exception:
        print("PHYSICAL_IOS_VALIDATION_INCOMPLETE unexpected_redacted", flush=True)
        raise SystemExit(1) from None
