"""Verify an unsigned ARM64 preview APK and package it for local signing."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


def run_tool(tool, *args, check=True):
    return subprocess.run([str(tool), *map(str, args)], check=check, capture_output=True, text=True)


def inspect_apk(apk, tools_dir, version_code):
    if not 0 < version_code <= 2100000000:
        raise ValueError("Preview version code must be between 1 and 2100000000")
    for name in ("aapt", "apksigner", "zipalign"):
        if not (tools_dir / name).is_file():
            raise ValueError(f"Missing Android build tool: {name}")
    with zipfile.ZipFile(apk) as archive:
        entries = set(archive.namelist())
        if archive.testzip() is not None or "AndroidManifest.xml" not in entries:
            raise ValueError("APK archive is incomplete or corrupt")
        required_libs = {"lib/arm64-v8a/libapp.so", "lib/arm64-v8a/libflutter.so"}
        native_libs = {name for name in entries if name.startswith("lib/") and name.endswith(".so")}
        missing_libs = sorted(required_libs - native_libs)
        unexpected_libs = sorted(name for name in native_libs if not name.startswith("lib/arm64-v8a/"))
        if missing_libs or unexpected_libs:
            raise ValueError(f"Candidate native libraries: missing={missing_libs}, non-ARM64={unexpected_libs}")
        if any(re.match(r"META-INF/[^/]+\.(RSA|DSA|EC|SF)$", name, re.I) for name in entries):
            raise ValueError("Candidate contains signing material")
    badging = run_tool(tools_dir / "aapt", "dump", "badging", apk).stdout
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    abi = re.search(r"^native-code: (.+)$", badging, re.M)
    if not package or package[1] != "com.bluebubbles.messaging.divy":
        raise ValueError("APK has the wrong application ID")
    if int(package[2]) != version_code:
        raise ValueError("APK version code differs from the requested build")
    if not re.fullmatch(r"\d+\.\d+\.\d+", package[3]):
        raise ValueError("APK version name must be a three-part upstream version")
    if "application-debuggable" in badging:
        raise ValueError("Candidate APK is debuggable")
    if not abi or abi[1].strip() != "'arm64-v8a'":
        raise ValueError("Candidate APK must contain only ARM64 native code")
    signature = run_tool(tools_dir / "apksigner", "verify", "--verbose", apk, check=False)
    if signature.returncode == 0:
        raise ValueError("Candidate already has a valid signature")
    if signature.returncode != 1 or "DOES NOT VERIFY" not in signature.stdout + signature.stderr:
        raise ValueError("APK signature inspection failed unexpectedly")
    return {"applicationId": package[1], "versionCode": version_code, "versionName": package[3], "abi": "arm64-v8a"}


def prepare_artifact(apk, tools_dir, version_code, output_dir):
    metadata = inspect_apk(apk, tools_dir, version_code)
    source_commit = run_tool("git", "rev-parse", "HEAD").stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Cannot identify the source commit")
    if os.environ.get("GITHUB_SHA") and os.environ["GITHUB_SHA"] != source_commit:
        raise ValueError("Checked-out source differs from the workflow commit")
    output_dir.mkdir(parents=True, exist_ok=False)
    filename = f"bluebubbles-divy-{metadata['versionName']}-{version_code}-unsigned.apk"
    output_apk = output_dir / filename
    # Align before signing, including 16 KiB pages for uncompressed native libs.
    run_tool(tools_dir / "zipalign", "-P", "16", "-v", "4", apk, output_apk)
    run_tool(tools_dir / "zipalign", "-c", "-P", "16", "-v", "4", output_apk)
    inspect_apk(output_apk, tools_dir, version_code)
    sha256 = hashlib.sha256(output_apk.read_bytes()).hexdigest()
    metadata.update({
        "sourceCommit": source_commit,
        "filename": filename,
        "sha256": sha256,
        "unsigned": True,
        "flutterVersion": "3.44.6",
        "buildToolsVersion": "36.0.0",
        "workflowRunId": os.environ.get("GITHUB_RUN_ID"),
        "workflowRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    })
    (output_dir / "candidate.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    (output_dir / "SHA256SUMS").write_text(f"{sha256}  {filename}\n", encoding="utf-8")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--version-code", type=int, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        metadata = prepare_artifact(args.apk, args.tools_dir, args.version_code, args.output_dir)
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Candidate verification failed: {error}\n")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
