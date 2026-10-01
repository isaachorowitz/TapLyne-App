#!/usr/bin/env python3
"""Reproduce Taplyne's pinned WebDriverAgent XCTest runner checkout."""

import argparse
import hashlib
import io
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tarfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
TAG = "v16.13.6"
COMMIT = "9d1d17ddb59e6097ddc3324b23ca9f4174507b12"
REPOSITORY = "https://github.com/appium/WebDriverAgent.git"
SHARED = ("RelayProtocol.swift", "RelayCipher.swift", "RelayPeer.swift", "RelayRPC.swift")
BUNDLE_ID = "agency.ziplyne.taplyne.wda"
MARKER = ".taplyne-runner-source.json"


def call(*args, cwd=None, capture=True):
    return subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.PIPE if capture else None).stdout


def resolve_source(source, cache):
    if source is None:
        source = cache
        if not (source / ".git").exists():
            source.parent.mkdir(parents=True, exist_ok=True)
            call("git", "clone", "--filter=blob:none", "--branch", TAG, "--single-branch", REPOSITORY, str(source), capture=False)
    source = source.resolve()
    if not (source / ".git").exists():
        raise ValueError("WebDriverAgent source must be a Git checkout")
    actual = call("git", "rev-parse", "HEAD", cwd=source).decode().strip()
    tag_commit = call("git", "rev-parse", f"{TAG}^{{commit}}", cwd=source).decode().strip()
    if actual != COMMIT or tag_commit != COMMIT:
        raise ValueError(f"WebDriverAgent source must be exact {TAG} commit {COMMIT}")
    if call("git", "status", "--porcelain", cwd=source).strip():
        raise ValueError("WebDriverAgent source has local changes; use a clean pinned checkout")
    return source


def digest(paths):
    h = hashlib.sha256()
    for path in paths:
        h.update(path.name.encode())
        h.update(path.read_bytes())
    return h.hexdigest()


def prepared_files(output):
    return [output / "WebDriverAgent.xcodeproj/project.pbxproj",
            output / "WebDriverAgentRunner/UITestingUITests.m",
            output / "WebDriverAgentLib/Routing/FBWebServer.m"] + [output / "TaplyneRelay" / name for name in (*SHARED, "TLRunnerRelay.swift")]


def patch_hook(checkout):
    path = checkout / "WebDriverAgentRunner/UITestingUITests.m"
    source = path.read_text()
    imported = '#import "WebDriverAgentRunner-Swift.h"\n'
    if imported not in source:
        needle = "#import <WebDriverAgentLib/XCTestCase.h>\n"
        if source.count(needle) != 1:
            raise ValueError("upstream WDA test import changed")
        source = source.replace(needle, needle + imported)
    invocation = "  [TLRunnerRelay start];\n"
    if invocation not in source:
        needle = "  [webServer startServing];"
        if source.count(needle) != 1:
            raise ValueError("upstream WDA runner entry point changed")
        source = source.replace(needle, invocation + needle)
    path.write_text(source)


def patch_mjpeg_binding(checkout):
    path = checkout / "WebDriverAgentLib/Routing/FBWebServer.m"
    source = path.read_text()
    needle = "  self.screenshotsBroadcaster.delegate = self.mjpegServer;\n"
    if source.count(needle) != 1:
        raise ValueError("upstream WDA MJPEG listener changed")
    source = source.replace(needle, needle + "  self.screenshotsBroadcaster.interface = FBConfiguration.sharedInstance.bindingIPAddress;\n")
    path.write_text(source)


def patch_project(checkout, filenames):
    path = checkout / "WebDriverAgent.xcodeproj/project.pbxproj"
    project = json.loads(call("plutil", "-convert", "json", "-o", "-", str(path)))
    objects = project["objects"]
    target = next((obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"
                   and obj.get("name") == "WebDriverAgentRunner"), None)
    if target is None:
        raise ValueError("upstream WDA runner target missing")
    phase = next((objects[ref] for ref in target["buildPhases"]
                  if objects[ref]["isa"] == "PBXSourcesBuildPhase"), None)
    if phase is None:
        raise ValueError("upstream WDA runner sources phase missing")
    group = next((obj for obj in objects.values() if obj.get("isa") == "PBXGroup"
                  and obj.get("name") == "WebDriverAgentRunner"), None)
    if group is None:
        raise ValueError("upstream WDA runner group missing")
    for name in filenames:
        file_id = hashlib.sha256(("Taplyne file " + name).encode()).hexdigest()[:24].upper()
        build_id = hashlib.sha256(("Taplyne build " + name).encode()).hexdigest()[:24].upper()
        objects[file_id] = {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift",
                            "name": name, "path": "TaplyneRelay/" + name, "sourceTree": "SOURCE_ROOT"}
        objects[build_id] = {"isa": "PBXBuildFile", "fileRef": file_id}
        if file_id not in group["children"]:
            group["children"].append(file_id)
        if build_id not in phase["files"]:
            phase["files"].append(build_id)
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    for ref in configurations:
        settings = objects[ref]["buildSettings"]
        settings.update({"SWIFT_VERSION": "5.0", "DEFINES_MODULE": "YES",
                         "SWIFT_INSTALL_OBJC_HEADER": "YES",
                         "SWIFT_OBJC_INTERFACE_HEADER_NAME": "WebDriverAgentRunner-Swift.h",
                         "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
                         "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID})
    with path.open("wb") as output:
        plistlib.dump(project, output, fmt=plistlib.FMT_XML, sort_keys=False)
    call("plutil", "-lint", str(path), capture=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path, help="clean pinned WDA checkout; defaults to a cached clone")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".build/runner/wda")
    args = parser.parse_args()
    output = args.output.resolve()
    build_root = (ROOT / ".build/runner").resolve()
    if output != build_root / "wda":
        raise ValueError("output must be the task-owned .build/runner/wda path")
    files = [ROOT / "Shared" / name for name in SHARED] + [ROOT / "Runner/TLRunnerRelay.swift", pathlib.Path(__file__)]
    missing = [str(path.relative_to(ROOT)) for path in files if not path.is_file()]
    if missing:
        raise ValueError("missing runner inputs: " + ", ".join(missing))
    source = resolve_source(args.source, build_root / "upstream")
    signature = digest(files)
    marker_path = output / MARKER
    if marker_path.exists():
        marker = json.loads(marker_path.read_text())
        if marker.get("inputSHA256") == signature:
            if marker.get("preparedSHA256") != digest(prepared_files(output)):
                raise ValueError("prepared WDA checkout changed; refusing to use it")
            print(json.dumps({"event": "runner_prepared", "path": str(output), "reused": True}))
            return
    if output.exists():
        if not marker_path.exists():
            raise ValueError("refusing to replace unmarked output directory")
        shutil.rmtree(output)
    output.mkdir(parents=True)
    archive = call("git", "archive", "--format=tar", COMMIT, cwd=source)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(output, filter="data")
    relay_directory = output / "TaplyneRelay"
    relay_directory.mkdir()
    for path in files[:-1]:
        shutil.copyfile(path, relay_directory / path.name)
    patch_hook(output)
    patch_mjpeg_binding(output)
    patch_project(output, [path.name for path in files[:-1]])
    marker_path.write_text(json.dumps({"tag": TAG, "commit": COMMIT, "inputSHA256": signature,
                                       "preparedSHA256": digest(prepared_files(output))}) + "\n")
    print(json.dumps({"event": "runner_prepared", "path": str(output), "reused": False,
                      "tag": TAG, "commit": COMMIT}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"runner preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
