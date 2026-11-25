#!/usr/bin/env python3
"""Exercise AppUpdates and the standard Sparkle UI against a loopback appcast."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import plistlib
import shutil
import subprocess
from tempfile import TemporaryDirectory
from threading import Thread
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK = ROOT / "build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"


def run(probe: Path, scenario: str, versions: tuple[int, ...]) -> None:
    requests = []
    workspace = probe.parents[3]
    download_started = workspace / "download-started"
    finish_download = workspace / "finish-download"
    archive = b""
    signature = ""

    class Appcast(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path == "/update.zip" and scenario == "download":
                self.send_response(200)
                self.send_header("Content-Length", str(len(archive)))
                self.end_headers()
                self.wfile.write(archive[:1])
                download_started.touch()
                deadline = time.monotonic() + 16
                while not finish_download.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                if finish_download.exists():
                    self.wfile.write(archive[1:])
                return
            if self.path != "/appcast.xml":
                return self.send_error(404)
            version = versions[min(len(requests), len(versions)) - 1]
            signed = f'sparkle:edSignature="{signature}"' if signature else ""
            feed = f"""<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel><title>Pisa update test</title><item><title>Version {version}</title>
            <sparkle:version>{version}</sparkle:version>
            <enclosure url="http://127.0.0.1:{self.server.server_port}/update.zip" length="{len(archive) or 1}"
            type="application/octet-stream" {signed}/>
            </item></channel></rss>""".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(feed)))
            self.end_headers()
            self.wfile.write(feed)

    with ThreadingHTTPServer(("127.0.0.1", 0), Appcast) as server:
        downloads = scenario in ("download", "failed-download")
        info = {
            "CFBundleIdentifier": "com.docomoz.pisa.updateprobe." + uuid.uuid4().hex,
            "CFBundleExecutable": probe.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "SUFeedURL": f"http://127.0.0.1:{server.server_port}/appcast.xml",
            "SUPublicEDKey": plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["SUPublicEDKey"],
            "SUEnableAutomaticChecks": scenario != "disabled",
            "SUAutomaticallyUpdate": downloads,
            "SUVerifyUpdateBeforeExtraction": True,
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        }
        if scenario == "download":
            signing_key = workspace / "fixture-key"
            info["SUPublicEDKey"] = subprocess.check_output([probe, "fixture-key", signing_key], text=True).strip()
            updated_app = workspace / "fixture" / probe.parents[2].name
            shutil.copytree(probe.parents[2], updated_app, symlinks=True)
            updated_info = dict(info, CFBundleShortVersionString="2.0", CFBundleVersion=str(versions[-1]))
            (updated_app / "Contents/Info.plist").write_bytes(plistlib.dumps(updated_info))
            subprocess.run(["codesign", "--force", "--sign", "-", updated_app], check=True)
            update_zip = workspace / "update.zip"
            subprocess.run(["ditto", "-c", "-k", "--keepParent", updated_app, update_zip], check=True)
            archive = update_zip.read_bytes()
            signature = subprocess.check_output([probe, "sign-fixture", signing_key, update_zip], text=True).strip()

        (probe.parent.parent / "Info.plist").write_bytes(plistlib.dumps(info))
        Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run([probe, scenario, workspace], check=True, timeout=40)
        finally:
            server.shutdown()
        expected = ["/appcast.xml"] * len(versions)
        if downloads:
            expected.append("/update.zip")
        if requests != expected:
            raise SystemExit(f"{scenario}: expected {expected}, got {requests}")
        print(f"PASS: {scenario}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("framework_dir", type=Path, nargs="?", default=FRAMEWORK)
    framework = parser.parse_args().framework_dir.resolve()
    if not (framework / "Sparkle.framework").is_dir():
        parser.error(f"Resolve Xcode packages first or pass the directory containing Sparkle.framework: {framework}")

    with TemporaryDirectory(prefix="pisa-update-probe-") as directory:
        root = Path(directory)
        probe = root / "PisaUpdateProbe.app/Contents/MacOS/PisaUpdateProbe"
        probe.parent.mkdir(parents=True)
        shutil.copytree(framework / "Sparkle.framework", probe.parent.parent / "Frameworks/Sparkle.framework", symlinks=True)
        subprocess.run([
            "xcrun", "swiftc", "-module-cache-path", root / "modules", "-F", framework,
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", ROOT / "Sources/Pisa/AppUpdates.swift",
            Path(__file__).with_name("AppUpdateChecksProbe.swift"), "-o", probe,
        ], check=True)
        run(probe, "launch", (2,))
        run(probe, "activity", (1, 2))
        run(probe, "disabled", (2,))
        run(probe, "failed-download", (2,))
        run(probe, "download", (2,))


if __name__ == "__main__":
    main()
