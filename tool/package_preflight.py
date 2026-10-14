#!/usr/bin/env python3
"""Run official nonpublishing package validation; never uploads a package.

This preserves publish_to: none and always passes --dry-run. Pub does not offer
an offline publish-validation mode, so this can read registry metadata. It does
not prove registry name ownership or publication readiness.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from check_package import PACKAGES, ROOT, snapshot_digest

MISSING_URL = (
    '* It\'s strongly recommended to include a "homepage" or "repository" '
    'field in your pubspec.yaml'
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--package", choices=PACKAGES)
    parser.add_argument(
        "--allow-missing-publishing-url", action="store_true",
        help="Allow only pub's known missing homepage/repository warning.",
    )
    parser.add_argument(
        "--report-dir", type=Path, default=ROOT / "build/package-preflight",
    )
    args = parser.parse_args()
    flutter = shutil.which(args.flutter)
    if flutter is None:
        raise SystemExit("Flutter executable was not found.")
    output_dir = args.report_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    # An interrupted run must not leave a previous successful summary behind.
    (output_dir / "report.json").unlink(missing_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="anythink-package-preflight-") as temporary:
        workspace = Path(temporary)
        for name in PACKAGES:
            shutil.copytree(
                ROOT / "packages" / name, workspace / "packages" / name,
                ignore=shutil.ignore_patterns(
                    ".dart_tool", "build", "coverage", "pubspec.lock",
                    "pubspec_overrides.yaml", ".flutter-plugins*", "*.log", ".DS_Store",
                    ".env", ".env.*", ".secrets", ".git",
                ),
            )
        for filename in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml"):
            shutil.copyfile(ROOT / filename, workspace / filename)
        native_host = workspace / "integration/native_host"
        native_host.mkdir(parents=True)
        shutil.copyfile(
            ROOT / "integration/native_host/pubspec.yaml", native_host / "pubspec.yaml",
        )
        results = check_packages(args, flutter, output_dir, workspace)
    report = {
        "checked_utc": datetime.now(timezone.utc).isoformat(),
        "packages": results,
        "published": False,
        "release_ready": False,
        "note": (
            "Copied workspace validates current archive contents, not source git "
            "cleanliness. publish_to:none remains; registry ownership is unverified."
        ),
    }
    (output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if all(item["validation_accepted"] for item in results) else 1


def check_packages(args, flutter, output_dir, workspace):
    results = []
    for name in ([args.package] if args.package else PACKAGES):
        package = workspace / "packages" / name
        manifest_lines = (package / "pubspec.yaml").read_text().splitlines()
        if "publish_to: none" not in manifest_lines:
            raise SystemExit("Expected development publication guard is missing.")
        print(name + ": official publish --dry-run", flush=True)
        result = subprocess.run(
            [flutter, "pub", "publish", "--dry-run"], cwd=package,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=600,
        )
        (output_dir / (name + ".log")).write_text(result.stdout)
        known_warning = (
            result.returncode == 65
            and MISSING_URL in result.stdout
            and "Package has 1 warning." in result.stdout
            and "Package has 1 warning and" not in result.stdout
        )
        accepted = result.returncode == 0 or (
            args.allow_missing_publishing_url and known_warning
        )
        results.append({
            "package": name,
            "snapshot_sha256": snapshot_digest(package),
            "command": "flutter pub publish --dry-run",
            "exit_code": result.returncode,
            "validation_accepted": accepted,
            "missing_publishing_url": known_warning,
            "published": False,
        })
        if not accepted:
            print(result.stdout[-6000:], file=sys.stderr)
        print(name + (": checked" if accepted else ": blocked"), flush=True)
    return results


if __name__ == "__main__":
    sys.exit(main())
