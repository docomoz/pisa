#!/usr/bin/env python3
"""Rebuild the pinned, static Apple Silicon audio-only WebRTC module."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import venv

vendor = Path(__file__).resolve().parent
versions = json.loads((vendor / "versions.json").read_text())
parser = argparse.ArgumentParser()
parser.add_argument("--work-dir", type=Path, required=True)
args = parser.parse_args()
work = args.work_dir.resolve()
work.mkdir(parents=True, exist_ok=True)
archive = work / "webrtc-audio-processing-2.1.tar.xz"
if not archive.exists():
    urllib.request.urlretrieve(versions["source_url"], archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != versions["source_sha256"]:
    raise SystemExit("Source archive checksum mismatch")
source = work / "webrtc-audio-processing-2.1"
if not source.exists():
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            target = (work / member.name).resolve()
            if work not in target.parents:
                raise SystemExit("Unsafe source archive path")
            if member.issym() or member.islnk():
                linked = (target.parent / member.linkname).resolve()
                if work not in linked.parents:
                    raise SystemExit("Unsafe source archive link")
        bundle.extractall(work)
environment = work / "tools"
if not (environment / "bin/meson").exists():
    venv.create(environment, with_pip=True)
    subprocess.run([str(environment / "bin/pip"), "install", "meson==" + versions["meson"], "ninja==" + versions["ninja"]], check=True)
env = dict(os.environ)
env["PATH"] = str(environment / "bin") + os.pathsep + env.get("PATH", "")
build = work / "build"
command = [str(environment / "bin/meson"), "setup"]
if (build / "build.ninja").exists():
    command.append("--reconfigure")
command += [str(build), str(source), "--default-library=static", "--buildtype=release", "-Db_ndebug=true", "-Dc_args=-mmacosx-version-min=15.0", "-Dcpp_args=-mmacosx-version-min=15.0"]
subprocess.run(command, check=True, env=env)
subprocess.run([str(environment / "bin/ninja"), "-C", str(build), "-j", "4"], check=True, env=env)
absl = source / "subprojects/abseil-cpp-20240722.0"
wrapper = work / "PisyaAEC.o"
subprocess.run(["clang++", "-O2", "-std=c++17", "-mmacosx-version-min=15.0", "-DWEBRTC_LIBRARY_IMPL", "-DWEBRTC_ENABLE_SYMBOL_EXPORT", "-D_WINSOCKAPI_", "-DNDEBUG", "-DWEBRTC_ARCH_ARM64", "-DWEBRTC_MAC", "-DWEBRTC_POSIX", "-DWEBRTC_APM_DEBUG_DUMP=0", "-I" + str(source / "webrtc"), "-I" + str(absl), "-c", str(vendor / "PisyaAEC.cpp"), "-o", str(wrapper)], check=True)
libraries = [build / "webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"]
libraries += sorted((build / "subprojects/abseil-cpp-20240722.0").glob("libabsl_*.a"))
subprocess.run(["libtool", "-static", "-o", str(vendor / "libPisyaAEC.a"), str(wrapper)] + list(map(str, libraries)), check=True)
for path in source.rglob("*"):
    if path.is_file() and path.name in {"COPYING", "LICENSE", "NOTICE", "PATENTS"} and "subprojects" not in path.parts:
        shutil.copyfile(path, vendor / ("LICENSE-" + str(path.relative_to(source)).replace("/", "_")))
shutil.copyfile(absl / "LICENSE", vendor / "Abseil-LICENSE")
print("Built", vendor / "libPisyaAEC.a")
