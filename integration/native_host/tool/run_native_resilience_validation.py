#!/usr/bin/env python3
"""Interrupt only the dedicated host during a controlled loopback refresh.

No real credentials, personal apps, UI scripting or device-setting changes are
used. The harness requests no data wipe or uninstall. --no-uninstall disables
Flutter's teardown removal, but its Android install fallback can still uninstall
and reinstall. Recovery requires a retained marker, a different PID and the
persisted pending-rotation envelope, so data loss cannot pass these gates.
Native storage and app process interruption are real; provider responses and
lifecycle callback dispatch belong to the test-only boundary.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time

import session_validation_support as h
from run_ios_session_validation import booted_ios_device

ANDROID_PACKAGE = "dev.anythink.sdk.anythink_native_host"
IOS_BUNDLE = "dev.anythink.sdk.anythinkNativeHost"
INPUT = "anythink-resilience-input.json"
MARKER = "anythink-resilience-state.json"
INTERRUPT_GATES = {
    "native_store_order_and_namespace_isolation",
    "lifecycle_resume_checks_coalesced",
    "native_pending_marker_before_interruption",
}
RECOVER_GATES = {
    "pending_rotation_restored_as_uncertain",
    "uncertain_credentials_not_replayed",
    "uncertain_session_explicit_logout_clears_native_store",
    "corrupt_native_envelope_rejected_without_deletion",
}


class Device:
    def __init__(self, platform):
        self.platform = platform
        if platform == "ios":
            self.identifier, _, self.runtime = booted_ios_device()
            self.name = "iOS simulator"
        else:
            adb = shutil.which("adb")
            if not adb:
                raise h.ValidationFailure("adb_missing")
            code, output = h.captured([adb, "devices"])
            devices = [
                row[0]
                for line in output.splitlines()
                if len(row := line.split()) == 2 and row[1] == "device"
            ]
            if code or len(devices) != 1:
                raise h.ValidationFailure("exactly_one_authorized_device_required")
            self.identifier = devices[0]
            self.prefix = [adb, "-s", self.identifier]
            model = self.must(["shell", "getprop", "ro.product.model"]).strip()
            if model != "Seeker":
                raise h.ValidationFailure("seeker_required")
            self.name = "Seeker"
            self.runtime = "Android " + self.must([
                "shell", "getprop", "ro.build.version.release",
            ]).strip()

    def must(self, arguments, *, payload=None):
        command = self.prefix + arguments if self.platform == "android" else arguments
        code, output = h.captured(command, payload=payload)
        if code:
            raise h.ValidationFailure("native_command_failed")
        return output

    def ios_cache(self):
        container = Path(self.must([
            "xcrun", "simctl", "get_app_container", self.identifier,
            IOS_BUNDLE, "data",
        ]).strip())
        if not container.is_absolute() or not container.is_dir():
            raise h.ValidationFailure("ios_container_invalid")
        cache = container / "Library/Caches"
        if not cache.is_dir():
            raise h.ValidationFailure("installed_host_cache_required")
        return cache

    def marker_exists(self):
        """Absence is distinct from malformed content or failed device access."""
        if self.platform == "android":
            output = self.must([
                "shell", "run-as", ANDROID_PACKAGE, "sh", "-c",
                shlex.quote(
                    "if test -e cache/" + MARKER
                    + "; then printf present; else printf absent; fi"
                ),
            ]).strip()
            if output not in {"present", "absent"}:
                raise h.ValidationFailure("marker_presence_check_failed")
            return output == "present"
        return (self.ios_cache() / MARKER).exists()

    def read_marker(self):
        if self.platform == "android":
            code, output = h.captured(self.prefix + [
                "shell", "run-as", ANDROID_PACKAGE, "cat", "cache/" + MARKER,
            ])
            if code:
                return None
        else:
            path = self.ios_cache() / MARKER
            if not path.exists():
                return None
            output = path.read_text()
        try:
            return json.loads(output)
        except json.JSONDecodeError:
            # writeAsString may be observed before its final flush completes.
            return None

    def write_input(self, phase):
        payload = json.dumps({"phase": phase}).encode()
        if self.platform == "android":
            self.must([
                "shell", "run-as", ANDROID_PACKAGE, "sh", "-c",
                shlex.quote("umask 077; cat > cache/" + INPUT),
            ], payload=payload)
            mode = self.must([
                "shell", "run-as", ANDROID_PACKAGE,
                "stat", "-c", "%a", "cache/" + INPUT,
            ]).strip()
            if mode != "600":
                raise h.ValidationFailure("runtime_input_permissions_invalid")
        else:
            fd = os.open(
                self.ios_cache() / INPUT,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(fd, "wb") as stream:
                stream.write(payload)

    def stop(self, *, require_running=False):
        if self.platform == "android":
            if require_running:
                code, output = h.captured(self.prefix + [
                    "shell", "pidof", ANDROID_PACKAGE,
                ])
                if code or not output.strip():
                    raise h.ValidationFailure("host_not_alive_at_interruption")
            self.must(["shell", "am", "force-stop", ANDROID_PACKAGE])
            code, output = h.captured(self.prefix + [
                "shell", "pidof", ANDROID_PACKAGE,
            ])
            if code == 0 or output.strip():
                raise h.ValidationFailure("host_process_survived_stop")
        else:
            code, _ = h.captured([
                "xcrun", "simctl", "terminate", self.identifier, IOS_BUNDLE,
            ])
            if require_running and code:
                raise h.ValidationFailure("host_not_alive_at_interruption")

    def clean_input(self):
        if self.platform == "android":
            self.must([
                "shell", "run-as", ANDROID_PACKAGE, "rm", "-f", "cache/" + INPUT,
            ])
        else:
            (self.ios_cache() / INPUT).unlink(missing_ok=True)

    def require_input_consumed(self):
        if self.platform == "android":
            self.must([
                "shell", "run-as", ANDROID_PACKAGE,
                "test", "!", "-e", "cache/" + INPUT,
            ])
        elif (self.ios_cache() / INPUT).exists():
            raise h.ValidationFailure("runtime_input_survived")


def test_command(device):
    flutter = shutil.which("flutter")
    if not flutter:
        raise h.ValidationFailure("flutter_missing")
    return [
        flutter, "test", "integration_test/device_resilience_test.dart",
        "--no-pub", "--no-uninstall", "--reporter=expanded",
        "-d", device.identifier,
    ]


def interrupt_phase(device):
    device.write_input("interrupt")
    start = time.monotonic()
    # A temporary output sink avoids blocked pipes without logging arbitrary
    # Flutter/plugin output. This test uses synthetic credentials only.
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(
            test_command(device),
            cwd=h.HOST,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            marker = None
            deadline = start + 300
            while time.monotonic() < deadline:
                marker = device.read_marker()
                if marker is not None:
                    break
                if process.poll() is not None:
                    raise h.ValidationFailure("host_exited_before_refresh_marker")
                time.sleep(0.5)
            if (
                not isinstance(marker, dict)
                or marker.get("phase") != "refresh_held"
                or set(marker.get("gates", [])) != INTERRUPT_GATES
                or not isinstance(marker.get("pid"), int)
            ):
                raise h.ValidationFailure("refresh_marker_not_ready")
            device.require_input_consumed()
            device.stop(require_running=True)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                h._stop_process_group(process)
            return {
                "phase": "interrupted_refresh",
                "gates": sorted(INTERRUPT_GATES),
                "external_app_process_stop": True,
                "seconds": round(time.monotonic() - start, 1),
            }
        finally:
            if process.poll() is None:
                h._stop_process_group(process)


def recover_phase(device):
    device.write_input("recover")
    start = time.monotonic()
    code, output = h.captured(test_command(device), timeout=600)
    gates = set(re.findall(r"RESILIENCE_GATE_PASS ([a-z_]+)", output))
    if code or gates != RECOVER_GATES or "All tests passed!" not in output:
        for failure in sorted(set(re.findall(
            r"RESILIENCE_GATE_FAILED ([a-z_0-9]+)", output,
        ))):
            print("RESILIENCE_GATE_FAILED " + failure, flush=True)
        raise h.ValidationFailure("recovery_phase_failed")
    device.require_input_consumed()
    if device.marker_exists():
        raise h.ValidationFailure("recovery_marker_survived")
    return {
        "phase": "restart_recovery",
        "gates": sorted(gates),
        "seconds": round(time.monotonic() - start, 1),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=["android", "ios"])
    args = parser.parse_args()
    device = Device(args.platform)
    device.stop()
    if device.marker_exists():
        raise h.ValidationFailure("preexisting_resilience_state_requires_review")
    report = {
        "platform": args.platform,
        "device": device.name,
        "runtime": device.runtime,
        "physical_device": args.platform == "android",
        "transport": "test-only loopback server; synthetic credentials",
        "lifecycle": "controlled resume callbacks on the real bridge",
        "storage": "real native secure-storage plugin",
        "locked_device_storage_tested": False,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "phases": [],
    }
    try:
        for phase in (interrupt_phase, recover_phase):
            print("RESILIENCE_VALIDATION starting " + phase.__name__, flush=True)
            result = phase(device)
            report["phases"].append(result)
            for gate in result["gates"]:
                print("RESILIENCE_GATE_PASS " + gate, flush=True)
    finally:
        try:
            device.stop()
        finally:
            device.clean_input()
    artifact = h.HOST / (
        "build/app/outputs/flutter-apk/app-debug.apk"
        if args.platform == "android"
        else "build/ios/iphonesimulator/Runner.app/Frameworks/App.framework/flutter_assets/kernel_blob.bin"
    )
    report.update({
        "completed_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
        "artifact_bytes": artifact.stat().st_size,
        "runtime_input_removed": True,
        "restart_marker_removed": True,
    })
    path = h.HOST / ("build/" + args.platform + "-resilience-report.json")
    path.write_text(json.dumps(report, indent=2) + "\n")
    print("RESILIENCE_VALIDATION_PASS seven gates passed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except h.ValidationFailure as error:
        print("RESILIENCE_VALIDATION_INCOMPLETE " + str(error), flush=True)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("RESILIENCE_VALIDATION_INCOMPLETE interrupted", flush=True)
        raise SystemExit(130)
    except Exception:
        print("RESILIENCE_VALIDATION_INCOMPLETE unexpected_redacted", flush=True)
        raise SystemExit(1)
