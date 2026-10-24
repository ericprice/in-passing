#!/usr/bin/env python3
"""Check the exact signed app before notarization and publication."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from configure_posthog import validate_configuration


def validate(app):
    root = Path(__file__).resolve().parent.parent
    if app.name != "In Passing.app" or not app.is_dir():
        raise ValueError("Expected In Passing.app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = plistlib.loads((root / "Configuration/App.plist").read_bytes())
    expected.update(plistlib.loads((root / "Configuration/Updates.plist").read_bytes()))
    for key in ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "LSUIElement", "SUFeedURL", "SUPublicEDKey", "SUVerifyUpdateBeforeExtraction"]:
        if info.get(key) != expected[key]:
            raise ValueError(f"Unexpected {key}")
    executable = app / "Contents/MacOS/InPassing"
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    if set(architectures) != {"arm64", "x86_64"}:
        raise ValueError("Release executable must include arm64 and x86_64")
    versions = subprocess.check_output(["xcrun", "vtool", "-show-build", str(executable)], text=True)
    if re.findall(r"minos\s+(\S+)", versions) != ["14.0", "14.0"]:
        raise ValueError("Both architectures must target macOS 14.0")
    resources = app / "Contents/Resources"
    analytics = plistlib.loads((resources / "PostHogConfiguration.plist").read_bytes())
    validate_configuration(analytics)
    if analytics.get("IN_PASSING_ANALYTICS_ENVIRONMENT") != "production" or analytics.get("IN_PASSING_ANALYTICS_INTERNAL") != "false":
        raise ValueError("Distribution must bundle production/external analytics provenance")
    if (resources / "in-passing-menu-icon.pdf").read_bytes() != (root / "Resources/in-passing-menu-icon.pdf").read_bytes():
        raise ValueError("Menu artwork differs from source")
    for name in ["Assets.car", "in-passing-app-icon.icns", "Sparkle-LICENSE.txt", "Licenses/PostHog.txt", "Licenses/libwebp.txt", "Licenses/PLCrashReporter.txt", "PostHog_PostHog.bundle/Contents/Resources/PrivacyInfo.xcprivacy"]:
        if not (resources / name).is_file():
            raise ValueError(f"Missing resource: {name}")
    signature = subprocess.run(["codesign", "-d", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
    if "Authority=Developer ID Application:" not in signature or "Timestamp=" not in signature or "runtime" not in signature:
        raise ValueError("Developer ID, secure timestamp, and hardened runtime are required")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    try:
        validate(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"Release validation failed: {error}")
    print("Release metadata, analytics provenance, privacy resource, licenses, and signature verified.")
