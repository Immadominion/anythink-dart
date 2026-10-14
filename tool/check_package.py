#!/usr/bin/env python3
"""Analyze and test one unpublished package outside the repository workspace.

Uses official pub resolution and SDK tools. The source checkout and its lockfile
are never changed. Local peer packages are copied and overridden in the disposable
consumer, so no hosted package name is assumed to belong to this repository.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = (
    "anythink_dart",
    "anythink_flutter",
    "anythink_flutter_auth",
    "anythink_flutter_push",
    "anythink_flutter_purchases",
)


def stage_package(name, target):
    source = ROOT / "packages" / name
    shutil.copytree(
        source,
        target,
        ignore=shutil.ignore_patterns(
            ".dart_tool", "build", "coverage", "pubspec.lock",
            "pubspec_overrides.yaml", ".flutter-plugins*", "*.log", ".DS_Store",
            ".env", ".env.*", ".secrets", ".git",
        ),
    )
    # Official pub workspace escape hatch; release manifests stay unchanged.
    overrides = "resolution:\n"
    if name != "anythink_dart":
        overrides += (
            "dependency_overrides:\n"
            "  anythink_dart:\n"
            "    path: ../anythink_dart\n"
        )
    (target / "pubspec_overrides.yaml").write_text(overrides)
    shutil.copyfile(ROOT / "analysis_options.yaml", target / "analysis_options.yaml")


def snapshot_digest(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            digest.update(path.relative_to(directory).as_posix().encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, choices=PACKAGES)
    parser.add_argument(
        "--resolution", choices=("latest", "lowest-direct", "lowest"),
        default="latest", help="lowest downgrades dev/transitive tools too",
    )
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--dart", default="dart")
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--report-dir", type=Path)
    args = parser.parse_args()
    report_dir = (
        args.report_dir or ROOT / "build/compatibility" /
        (args.package + "-" + args.resolution)
    ).resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / "report.json"
    report_path.unlink(missing_ok=True)
    report = {
        "package": args.package,
        "resolution": args.resolution,
        "offline": args.offline,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "steps": [],
        "status": "incomplete",
    }
    flutter_package = args.package != "anythink_dart"
    sdk = shutil.which(args.flutter if flutter_package else args.dart)
    if sdk is None:
        raise SystemExit("Required SDK executable was not found.")
    environment = os.environ.copy()
    if flutter_package:
        # Dart invoked by pub/test must come from this selected Flutter SDK.
        environment["PATH"] = (
            str(Path(sdk).resolve().parent) + os.pathsep + environment["PATH"]
        )

    def run(label, command, directory, *, timeout=900):
        print(args.package + ": " + label, flush=True)
        process = subprocess.run(
            command, cwd=directory, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )
        # Flutter sends startup-lock notices to stderr. Preserve diagnostics in
        # the log without contaminating machine-readable pub JSON on stdout.
        output = process.stdout
        if process.stderr:
            output += "\n[stderr]\n" + process.stderr
        (report_dir / (label + ".log")).write_text(output)
        report["steps"].append({"name": label, "exit_code": process.returncode})
        if process.returncode:
            print(output[-12000:], file=sys.stderr)
            raise subprocess.CalledProcessError(process.returncode, command)
        return process.stdout

    exit_code = 0
    try:
        with tempfile.TemporaryDirectory(prefix="anythink-package-check-") as temporary:
            staging = Path(temporary)
            target = staging / args.package
            stage_package(args.package, target)
            if flutter_package:
                stage_package("anythink_dart", staging / "anythink_dart")
            report["snapshots_sha256"] = {
                path.name: snapshot_digest(path)
                for path in sorted(staging.iterdir()) if path.is_dir()
            }
            report["toolchain"] = run("version", [sdk, "--version"], target).strip()
            resolution = "downgrade" if args.resolution == "lowest" else "get"
            command = [sdk, "pub", resolution]
            if args.offline:
                command.append("--offline")
            run("resolve", command, target)
            if args.resolution == "lowest-direct":
                initial = json.loads(run(
                    "initial-dependencies", [sdk, "pub", "deps", "--json"],
                    target,
                ))
                names = [
                    item["name"] for item in initial["packages"]
                    if item["kind"] == "direct" and item["source"] == "hosted"
                ]
                if not names:
                    raise RuntimeError("No hosted runtime dependencies to validate.")
                command = [sdk, "pub", "downgrade", *names]
                if args.offline:
                    command.append("--offline")
                run("downgrade-direct", command, target)
            shutil.copyfile(target / "pubspec.lock", report_dir / "pubspec.lock")
            dependency_json = run("dependencies", [sdk, "pub", "deps", "--json"], target)
            dependencies = json.loads(dependency_json)
            report["dependencies"] = [
                {"name": item["name"], "version": item["version"], "kind": item["kind"]}
                for item in dependencies["packages"]
                if item["name"] != args.package
            ]
            analyze = [sdk, "analyze", "--fatal-infos"]
            if flutter_package:
                analyze.append("--no-pub")
            run("analyze", analyze, target)
            tests = [sdk, "test", "--reporter", "expanded"]
            if flutter_package:
                tests.append("--no-pub")
            run("test", tests, target)
            if not flutter_package:
                run(
                    "example-help",
                    [sdk, "run", "example/anythink_dart_example.dart", "--help"],
                    target,
                )
            report["status"] = "passed"
    except subprocess.CalledProcessError as failure:
        exit_code = failure.returncode or 1
        report["status"] = "failed"
    except subprocess.TimeoutExpired:
        exit_code = 1
        report["status"] = "timeout"
    finally:
        report["completed_utc"] = datetime.now(timezone.utc).isoformat()
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(args.package + ": " + report["status"], flush=True)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
