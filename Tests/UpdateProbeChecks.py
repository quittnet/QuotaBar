"""Run the real Sparkle information probe against a disposable loopback feed."""

import http.server
import os
import pathlib
import plistlib
import subprocess
import sys
import threading
import uuid
from xml.etree import ElementTree as ET


class FeedServer(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.partition("?")[0]
        self.server.requests.append(path)
        feed = self.server.directory / "appcast.xml"
        if path != "/appcast.xml" or not feed.is_file():
            self.send_error(404)
            return
        data = feed.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/rss+xml")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def make_feeds(directory, sign, url):
    archive = directory / "QuotaBar.zip"
    archive.write_bytes(bytes(range(256)) * 16)
    signature = sign("-p", archive, capture_output=True, text=True).stdout.strip()
    sign("--verify", archive, signature)
    original = archive.read_bytes()
    for offset in [0, 1, 255, 2048, len(original) - 1]:
        changed = bytearray(original)
        changed[offset] ^= 1
        archive.write_bytes(changed)
        result = sign("--verify", archive, signature, check=False, capture_output=True)
        if result.returncode == 0:
            raise RuntimeError(f"Sparkle accepted modified archive at offset {offset}")
    archive.write_bytes(original)
    sign("--verify", archive, signature)

    namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", namespace)
    for name, versions in {
        "older": [36], "equal": [37], "newer": [38],
        "multi": [36, 39, 38], "incompatible": [40],
    }.items():
        feed = directory / (name + ".xml")
        channel = ET.Element("channel")
        rss = ET.Element("rss", version="2.0")
        rss.append(channel)
        ET.SubElement(channel, "title").text = "QuotaBar probe"
        for build in versions:
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = f"Build {build}"
            for key, value in [
                ("version", str(build)), ("shortVersionString", f"1.8.{build}"),
                ("minimumSystemVersion", "99.0" if name == "incompatible" else "14.0"),
            ]:
                ET.SubElement(item, f"{{{namespace}}}{key}").text = value
            ET.SubElement(item, "enclosure", {
                "url": url + "/QuotaBar.zip", "length": str(len(original)),
                "type": "application/octet-stream", f"{{{namespace}}}edSignature": signature,
            })
        ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
        sign(feed)
        sign("--verify", feed)
    valid = (directory / "newer.xml").read_bytes()
    (directory / "tampered.xml").write_bytes(valid.replace(b"Build 38", b"Build 48"))
    (directory / "malformed.xml").write_bytes(b"<rss><channel><")
    sign(directory / "malformed.xml", capture_output=True)


def main():
    root, sparkle = map(pathlib.Path, sys.argv[1:])
    preference_domain = pathlib.Path(os.environ["QUOTABAR_TEST_PREFERENCES"], "sparkle-probe")
    app = root / "Probe.app"
    contents = app / "Contents"
    directory = root / "feeds"
    directory.mkdir()
    key = root / "private"
    # Sparkle's file-key option keeps this test independent of the release Keychain.
    keys = subprocess.check_output([
        "xcrun", "swift", "-module-cache-path", str(root / "modules"), "-e",
        "import CryptoKit; import Foundation; let k = Curve25519.Signing.PrivateKey(); "
        "print(k.rawRepresentation.base64EncodedString()); print(k.publicKey.rawRepresentation.base64EncodedString())"
    ], text=True).splitlines()
    key.touch(mode=0o600)
    key.write_text(keys[0])

    def sign(*args, check=True, **kwargs):
        return subprocess.run([sparkle / "bin/sign_update", "--ed-key-file", key, *args], check=check, **kwargs)

    with http.server.HTTPServer(("127.0.0.1", 0), FeedServer) as server:
        server.requests = []
        server.directory = directory
        url = f"http://127.0.0.1:{server.server_port}"
        make_feeds(directory, sign, url)
        info = {
            "CFBundleIdentifier": "app.quotabar.probe." + uuid.uuid4().hex,
            "SUDefaultsDomain": str(preference_domain),
            "CFBundleName": "QuotaBar Probe", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Probe", "CFBundleVersion": "37",
            "CFBundleShortVersionString": "1.8.0", "LSMinimumSystemVersion": "14.0",
            "LSBackgroundOnly": True, "SUPublicEDKey": keys[1], "SUFeedURL": url + "/appcast.xml",
            "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
            "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
            "SUSignedFeedFailureExpirationInterval": 0,
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        frameworks = contents / "Frameworks"
        frameworks.mkdir()
        subprocess.run(["ditto", "--noextattr", "--norsrc", sparkle / "Sparkle.framework", frameworks / "Sparkle.framework"], check=True)
        signer = pathlib.Path(__file__).resolve().parents[1] / "sign-quotabar.sh"
        subprocess.run([signer, app, root, "-"], check=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            profile = root / "profile"
            profile.mkdir()
            subprocess.run(
                [contents / "MacOS/Probe", directory], check=True, timeout=120,
                env={**os.environ, "HOME": str(profile), "CFFIXED_USER_HOME": str(profile)},
            )
        finally:
            server.shutdown()
            thread.join()
        preferences = plistlib.loads(preference_domain.with_suffix(".plist").read_bytes())
        if "SULastCheckTime" not in preferences:
            raise RuntimeError("Sparkle did not record its last check in the private fixture plist")
        print("Sparkle recorded its last check in the private fixture plist.")
        if server.requests != ["/appcast.xml"] * 80:
            raise RuntimeError(f"Unexpected probe requests: {server.requests}")
        print(f"Verified {len(server.requests)} feed requests and rejection of five modified archives.")


if __name__ == "__main__":
    main()
