"""Artifact checks shared by opt-in physical iOS provider runners."""

import plistlib
import zipfile

import session_validation_support as h
from run_physical_ios_session_validation import BUNDLE


def verify_signed_artifact(app, ipa):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise h.ValidationFailure("dedicated_app_required")
    with zipfile.ZipFile(ipa) as archive:
        for relative in ("Runner", "Frameworks/App.framework/App", "Info.plist"):
            if (app / relative).read_bytes() != archive.read("Payload/Runner.app/" + relative):
                raise h.ValidationFailure("ipa_app_mismatch")
    code, _ = h.captured(["codesign", "--verify", "--deep", "--strict", str(app)])
    if code:
        raise h.ValidationFailure("signed_app_verification_failed")
