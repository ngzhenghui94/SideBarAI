#!/usr/bin/env python3
"""Publish one immutable, notarized app and its signed Sparkle feed."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
NAME = "SideBarAI"
EXECUTABLE = "SideBarAI"
IDENTIFIER = "com.icelemontees.SideBarAI"
SLUG = "sidebarai"
REPO = "ngzhenghui94/SideBarAI"
TAG_PREFIX = "v"
ARCHIVE_PREFIX = "SideBarAI"
TAP = "ngzhenghui94/homebrew-tap"
REMOTE = f"https://github.com/{TAP}.git"
CHECKOUT = ROOT / "dist/update-tap"
RELEASES = ROOT / "dist/releases"
SPARKLE = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
TEAM = "F57QJC4XU3"
REQUIREMENT = (f'=identifier "{IDENTIFIER}" and anchor apple generic and '
               'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
               'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
               f'certificate leaf[subject.OU] = "{TEAM}"')
MACHO = {bytes.fromhex(value) for value in
         ("feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
NS = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}


def run(label, *command):
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    if result.returncode:
        raise RuntimeError(f"{label} failed (exit {result.returncode}); private command output withheld")
    return result.stdout.strip()


def git(*arguments):
    return run("Release checkout", "git", "-c", "credential.helper=", "-c",
               "credential.helper=!gh auth git-credential", "-C", str(CHECKOUT), *arguments)


def parts(version):
    if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", version):
        raise ValueError("Expected a numeric version with one to three components")
    return tuple(map(int, version.split(".")))


def next_version(versions, builds):
    version = list(max(map(parts, versions), key=lambda p: p + (0,) * (3 - len(p))))
    version[-1] += 1
    if any(not isinstance(b, str) or not re.fullmatch(r"[1-9]\d{0,3}", b) for b in builds):
        raise ValueError("Expected positive build integers below 10000")
    build = max(map(int, builds)) + 1
    if build > 9999:
        raise ValueError("Build numbering exhausted")
    return ".".join(map(str, version)), str(build)


def info(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)
    if value.get("CFBundleIdentifier") != IDENTIFIER or value.get("CFBundleExecutable") != EXECUTABLE:
        raise ValueError("Refusing unrelated app bundle")
    return value


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def selftest():
    assert next_version(["1.0.1", "1.0.9", "1.0.10"], ["1", "9"]) == ("1.0.11", "10")
    assert next_version(["1.9", "2.0.4"], ["3", "4"]) == ("2.0.5", "5")
    for version in ("../1", "1..2", "", "1.2-beta", "1.2.3.4"):
        try:
            parts(version)
        except ValueError:
            pass
        else:
            raise AssertionError("Unsafe version accepted")
    for build in ("0", "-1", "3.2", "10000", "9999"):
        try:
            next_version(["1.0"], [build])
        except ValueError:
            pass
        else:
            raise AssertionError("Unsafe or exhausted build accepted")
    print("release selftest ok: numeric ordering, safe paths, monotonic builds")


def main(source, final):
    for repository in (REPO, TAP):
        access = json.loads(run("Publication access", "gh", "api", f"repos/{repository}"))
        if access.get("private") or access.get("default_branch") != "main" or not access.get("permissions", {}).get("push"):
            raise RuntimeError("Expected public release destination and push access to main")
    CHECKOUT.parent.mkdir(parents=True, exist_ok=True)
    if not CHECKOUT.exists():
        run("Clone release checkout", "git", "clone", "--branch", "main", REMOTE, str(CHECKOUT))
    if git("remote", "get-url", "origin") != REMOTE or git("branch", "--show-current") != "main":
        raise RuntimeError("Unexpected release checkout identity")
    if git("status", "--porcelain", "--untracked-files=all") or git("rev-list", "--count", "origin/main..HEAD") != "0":
        raise RuntimeError("Preserve and resolve release checkout changes before retrying")
    git("fetch", "origin", "main")
    git("merge", "--ff-only", "origin/main")
    staged = info(source)
    public_key = run("Read public update key", str(SPARKLE / "generate_keys"), "--account", IDENTIFIER, "-p")
    if (public_key != staged.get("SUPublicEDKey") or staged.get("SURequireSignedFeed") is not True
            or staged.get("SUVerifyUpdateBeforeExtraction") is not True):
        raise RuntimeError("Pinned update public key or signed-feed requirement differs")
    versions = [staged["CFBundleShortVersionString"]]
    builds = [staged["CFBundleVersion"]]
    if final.exists():
        if final.is_symlink():
            raise ValueError("Refusing a symlink app destination")
        previous = info(final)
        versions.append(previous["CFBundleShortVersionString"])
        builds.append(previous["CFBundleVersion"])
    feed = CHECKOUT / f"appcasts/{SLUG}.xml"
    if feed.exists():
        run("Existing feed signature", str(SPARKLE / "sign_update"), "--account", IDENTIFIER, "--verify", str(feed))
        tree = ET.parse(feed)
        versions.extend(e.text for e in tree.findall(".//sparkle:shortVersionString", NS))
        builds.extend(e.text for e in tree.findall(".//sparkle:version", NS))
    pages = json.loads(run("Release inventory", "gh", "api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100"))
    for page in pages:
        for release in page:
            if release["tag_name"].startswith(TAG_PREFIX):
                versions.append(release["tag_name"][len(TAG_PREFIX):])
    for directory in RELEASES.iterdir() if RELEASES.exists() else []:
        if directory.is_dir():
            versions.append(directory.name)
            previous = info(directory / f"{NAME}.app")
            builds.append(previous["CFBundleVersion"])
    version, build = next_version(versions, builds)
    staged.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    output = RELEASES / version
    output.mkdir(parents=True, exist_ok=False)
    app = output / f"{NAME}.app"
    run("Copy release app", "ditto", str(source), str(app))
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(staged, stream, sort_keys=False)
    identity_text = run("Signing identity lookup", "security", "find-identity", "-v", "-p", "codesigning")
    identities = re.findall(r'\b([0-9A-Fa-f]{40})\s+"Developer ID Application: [^"\n]+ \(' + TEAM + r'\)"', identity_text)
    if len(identities) != 1:
        raise RuntimeError("Expected exactly one Developer ID identity for the existing team")
    binaries = []
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    binaries.append(path)
    bundles = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in (".framework", ".xpc", ".app")]
    for path in sorted(binaries + bundles, key=lambda p: len(p.parts), reverse=True) + [app]:
        run("Developer ID signing", "codesign", "--force", "--timestamp", "--options", "runtime",
            "--preserve-metadata=entitlements", "--sign", identities[0], str(path))
    run("Stable signing identity", "codesign", "--verify", "--deep", "--strict", "-R", REQUIREMENT, str(app))
    if run("Release architecture", "lipo", "-archs", str(app / f"Contents/MacOS/{EXECUTABLE}")) != "arm64":
        raise RuntimeError("Expected Apple Silicon release")
    run("Signed update policy selftest", str(app / f"Contents/MacOS/{EXECUTABLE}"), "--update-selftest")
    submission = output / "notarization.zip"
    run("Archive submission", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(submission))
    print(f"Submitting {NAME} {version} (build {build}) to Apple", flush=True)
    result = run("Apple notarization", "xcrun", "notarytool", "submit", str(submission), "--keychain-profile", "notary", "--wait", "--output-format", "json")
    (output / "notarization.json").write_text(result + "\n")
    if json.loads(result).get("status") != "Accepted":
        raise RuntimeError("Apple did not accept submission; inspect the recorded submission ID")
    run("Staple ticket", "xcrun", "stapler", "staple", str(app))
    run("Validate ticket", "xcrun", "stapler", "validate", str(app))
    run("Gatekeeper assessment", "spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    run("Final signature verification", "codesign", "--verify", "--deep", "--strict", "-R", REQUIREMENT, str(app))
    archive = output / f"{ARCHIVE_PREFIX}-{version}.zip"
    run("Archive notarized app", "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
    signature = run("Sign update archive", str(SPARKLE / "sign_update"), "--account", IDENTIFIER, "-p", str(archive))
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
        raise RuntimeError("Invalid archive signature")
    run("Verify archive signature", str(SPARKLE / "sign_update"), "--account", IDENTIFIER, "--verify", str(archive), signature)
    tag = TAG_PREFIX + version
    url = f"https://github.com/{REPO}/releases/download/{tag}/{archive.name}"
    appcast = output / "appcast.xml"
    appcast.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{NS['sparkle']}"><channel>
<title>{NAME} Updates</title><link>https://github.com/{REPO}</link><description>Signed Apple Silicon updates</description>
<item><title>{NAME} {version}</title><sparkle:version>{build}</sparkle:version>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="{url}" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}" /></item>
</channel></rss>
''')
    run("Sign appcast", str(SPARKLE / "sign_update"), "--account", IDENTIFIER, str(appcast))
    run("Verify appcast signature", str(SPARKLE / "sign_update"), "--account", IDENTIFIER, "--verify", str(appcast))
    expected = {p.name: digest(p) for p in (archive, appcast)}
    run("Create draft release", "gh", "release", "create", tag, "--repo", REPO, "--target", "main", "--draft",
        "--title", f"{NAME} {version}", "--notes", "Developer ID signed, Apple-notarized, stapled Apple Silicon app with signed Sparkle updates. Authored sources are not included in these release assets.", str(archive), str(appcast))
    with tempfile.TemporaryDirectory(prefix=f"{SLUG}-verify-") as temporary:
        run("Verify uploaded draft", "gh", "release", "download", tag, "--repo", REPO, "--dir", temporary)
        if any(digest(Path(temporary) / name) != value for name, value in expected.items()):
            raise RuntimeError("Uploaded bytes differ; draft retained, feed unchanged")
        run("Publish verified release", "gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest=false")
        for name, value in expected.items():
            downloaded = Path(temporary) / name
            run("Verify public download", "curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--output", str(downloaded), f"https://github.com/{REPO}/releases/download/{tag}/{name}")
            if digest(downloaded) != value:
                raise RuntimeError("Public download differs; live feed unchanged")
    feed.parent.mkdir(exist_ok=True)
    shutil.copy2(appcast, feed)
    cask = CHECKOUT / f"Casks/{SLUG}.rb"
    cask.write_text(f'''cask "{SLUG}" do
  version "{version}"
  sha256 "{expected[archive.name]}"
  url "{url}"
  name "{NAME}"
  desc "Native macOS menu-bar utility"
  homepage "https://github.com/{REPO}"
  depends_on arch: :arm64
  depends_on macos: :sonoma
  app "{NAME}.app"
end
''')
    git("add", "--", f"Casks/{SLUG}.rb", f"appcasts/{SLUG}.xml")
    git("commit", "-m", f"Publish notarized {NAME} {version} and signed updates")
    git("fetch", "origin", "main")
    git("rebase", "origin/main")
    git("push", "origin", "HEAD:main")
    if final.exists():
        info(final)
        shutil.rmtree(final)
    final.parent.mkdir(parents=True, exist_ok=True)
    run("Promote notarized app", "ditto", str(app), str(final))
    print(f"Published https://github.com/{REPO}/releases/tag/{tag}\nReady: {final}\nRetained release: {output}", flush=True)


if __name__ == "__main__":
    try:
        selftest()
        if sys.argv[1:] != ["--selftest"]:
            if len(sys.argv) != 3:
                raise ValueError("Usage: release.py STAGED_APP FINAL_APP; normally invoked by packaging script")
            main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).absolute())
    except (RuntimeError, OSError, ValueError, KeyError, ET.ParseError) as error:
        sys.exit(f"BLOCKED: {error}. Preserve dist/releases and dist/update-tap; inspect recorded Apple submission and GitHub draft before retrying.")
