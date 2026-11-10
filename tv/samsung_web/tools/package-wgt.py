#!/usr/bin/env python3
"""Stage/audit only the generated Samsung web payload; never edit owner files."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

TOOLS = Path("/opt/tvbro-tizen-toolchain")
OWNER = Path("/owner")
SIGNATURES = {"author-signature.xml", "signature1.xml"}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def files(root, omit_signatures=False):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("Refuse symlinks in a package payload")
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            if not omit_signatures or relative not in SIGNATURES:
                result[relative] = sha(path.read_bytes())
    return result


def manifest(data):
    root = ET.fromstring(data)
    ns = {"t": "http://tizen.org/ns/widgets"}
    app = root.find("t:application", ns)
    profile = root.find("t:profile", ns)
    if app is None or profile is None or app.get("required_version") != "3.0" or profile.get("name") != "tv-samsung":
        raise RuntimeError("Require the actual Samsung TV web manifest targeting 3.0")
    return {"applicationId": app.get("id"), "package": app.get("package"),
            "requiredVersion": app.get("required_version"), "profile": profile.get("name"),
            "widgetVersion": root.get("version"),
            "privileges": sorted(p.get("name") for p in root.findall("t:privilege", ns))}


def stage(metadata_file, work, evidence, expected_sha):
    if os.getuid() != 10000 or not Path("/.dockerenv").is_file():
        raise RuntimeError("Stage only as tvbro-sdk UID10000 in the prepared container")
    if work.resolve().parent != TOOLS / "work" or not work.name.startswith("samsung-web-"):
        raise RuntimeError("Unexpected generated workspace")
    if evidence.resolve().parent != Path("/evidence/samsung-web"):
        raise RuntimeError("Unexpected generated evidence directory")
    mount = [line.split() for line in Path("/proc/self/mountinfo").read_text().splitlines()
             if line.split()[4] == "/owner"]
    if len(mount) != 1 or "ro" not in mount[0][5].split(","):
        raise RuntimeError("The owner mount must be read-only")
    kind = subprocess.check_output(["stat", "-f", "-c", "%T", str(TOOLS / "work")], text=True).strip()
    if kind not in {"ext2/ext3", "ext4"}:
        raise RuntimeError("The new generated workspace must reside on ext4")
    raw = metadata_file.read_bytes()
    if not re.fullmatch("[0-9a-f]{64}", expected_sha) or sha(raw) != expected_sha:
        raise RuntimeError("latest-build.json changed before capture; use the final approved baseline")
    build = json.loads(raw)
    if build.get("status") != "samsung_web_payload_staged" or not build.get("javascriptEs5Syntax") or not build.get("legacyCssGate"):
        raise RuntimeError("Require successful staged legacy-web build gates")
    suffix = build["payload"].replace(chr(92), "/").split("/tv/output/samsung-web/", 1)
    if len(suffix) != 2:
        raise RuntimeError("Payload must belong to the owner's ignored Samsung output")
    source = (OWNER / "tv/output/samsung-web" / suffix[1]).resolve()
    if source.parent != OWNER / "tv/output/samsung-web" or not source.name.startswith("payload-"):
        raise RuntimeError("Payload must be one generated output directory")
    expected = build["payloadHashes"]
    if not isinstance(expected, dict) or not expected or set(expected) & SIGNATURES:
        raise RuntimeError("Invalid unsigned payload manifest")
    if files(source) != expected:
        raise RuntimeError("Source payload bytes differ from latest-build.json")
    target_manifest = manifest((source / "config.xml").read_bytes())
    work.mkdir(exist_ok=False)
    evidence.mkdir(parents=True, exist_ok=False)
    shutil.copytree(source, work / "payload")
    (work / "out").mkdir()
    if files(work / "payload") != expected:
        raise RuntimeError("Payload copy differs from the captured hashes")
    (evidence / "payload-build.json").write_bytes(raw)
    baseline = {"sourceMetadata": str(metadata_file), "sourceMetadataSha256": sha(raw),
                "sourcePayload": str(source), "workspace": str(work), "evidence": str(evidence),
                "ownerReadOnly": True, "workspaceFilesystem": kind, "manifest": target_manifest,
                "payloadFiles": len(expected), "payloadHashes": expected}
    (evidence / "baseline.json").write_text(json.dumps(baseline, indent=2) + "\n")
    print(json.dumps({"status": "generated_payload_staged", "sourcePayload": str(source),
                      "metadataSha256": sha(raw), "files": len(expected), "workspace": str(work)}))


def verify(work, evidence, sdk_exit, profile="TVBroLocalQualification"):
    baseline = json.loads((evidence / "baseline.json").read_text())
    expected = baseline["payloadHashes"]
    matches_source = files(Path(baseline["sourcePayload"])) == expected
    staged_files = files(work / "payload", omit_signatures=True)
    sdk_generated = {}
    # The SDK creates this temporary manifest and explicitly excludes it from
    # the WGT. Keep its hash as evidence; all original payload bytes still match.
    if ".manifest.tmp" in staged_files:
        sdk_generated[".manifest.tmp"] = staged_files.pop(".manifest.tmp")
    matches_copy = staged_files == expected
    artifacts = list((work / "out").glob("*.wgt"))
    proof = {"schemaVersion": 1, "status": "sdk_wgt_packaging_failed", "sdkExitCode": sdk_exit,
             "profile": profile, "certificateScope": "unqualified SDK certificate profile",
             "samsungPublisherCertificate": False, "samsungDeviceInstallAuthorized": False,
             "physicalTvTested": False, "baseline": baseline,
             "sourcePayloadUnchanged": matches_source, "stagedPayloadUnchanged": matches_copy,
             "excludedSdkGeneratedFiles": sdk_generated,
             "latestMetadataChangedSinceCapture": sha(Path(baseline["sourceMetadata"]).read_bytes()) != baseline["sourceMetadataSha256"]}
    if sdk_exit == 0 and len(artifacts) == 1:
        artifact = artifacts[0]
        with zipfile.ZipFile(artifact) as archive:
            entries = [entry for entry in archive.infolist() if not entry.is_dir()]
            if len({entry.filename for entry in entries}) != len(entries):
                raise RuntimeError("Duplicate signed archive entries")
            archive_hashes = {entry.filename: sha(archive.read(entry))
                              for entry in entries if entry.filename not in SIGNATURES}
            signature_files = sorted(entry.filename for entry in entries if entry.filename in SIGNATURES)
            signature_xml = {}
            for name in signature_files:
                root = ET.fromstring(archive.read(name))
                if root.tag != "{http://www.w3.org/2000/09/xmldsig#}Signature":
                    raise RuntimeError("A package signature is not XMLDSig")
                signature_xml[name] = {"sha256": sha(archive.read(name)), "xmlDsigPresent": True}
            proof.update({"archivePayloadFiles": len(archive_hashes),
                          "archivePayloadHashes": archive_hashes,
                          "archivePayloadMatches": archive_hashes == expected,
                          "signatureFiles": signature_files, "signatureXml": signature_xml,
                          "manifest": manifest(archive.read("config.xml")),
                          "artifact": {"name": artifact.name, "size": artifact.stat().st_size,
                                       "sha256": sha(artifact.read_bytes())}})
        if matches_source and matches_copy and proof["archivePayloadMatches"] and set(signature_files) == SIGNATURES:
            shutil.copyfile(artifact, evidence / artifact.name)
            proof["artifact"]["evidencePath"] = str(evidence / artifact.name)
            proof["status"] = "certificate_profile_wgt_packaged_payload_unchanged"
    (evidence / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps({"status": proof["status"], "sdkExitCode": sdk_exit,
                      "proof": str(evidence / "proof.json"), "artifact": proof.get("artifact")}))
    if proof["status"] != "certificate_profile_wgt_packaged_payload_unchanged":
        raise SystemExit(sdk_exit if 0 < sdk_exit < 126 else 1)


def unsigned(work, evidence):
    baseline = json.loads((evidence / "baseline.json").read_text())
    expected = baseline["payloadHashes"]
    if not expected or files(Path(baseline["sourcePayload"])) != expected or files(work / "payload") != expected:
        raise RuntimeError("Require exactly the captured generated payload files")
    artifact = work / "out/TVBro-0.1.0-unsigned.wgt"
    with zipfile.ZipFile(artifact, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(expected):
            archive.writestr(name, (work / "payload" / name).read_bytes())
    with zipfile.ZipFile(artifact) as archive:
        names = archive.namelist()
        actual = {name: sha(archive.read(name)) for name in names}
        if len(names) != len(expected) or actual != expected or set(names) & SIGNATURES:
            raise RuntimeError("Unsigned archive bytes differ from the captured payload")
        target_manifest = manifest(archive.read("config.xml"))
    matches_source = files(Path(baseline["sourcePayload"])) == expected
    matches_copy = files(work / "payload") == expected
    if not matches_source or not matches_copy:
        raise RuntimeError("Payload changed during unsigned packaging")
    destination = evidence / artifact.name
    shutil.copyfile(artifact, destination)
    proof = {"schemaVersion": 1, "status": "unsigned_wgt_created",
             "sdkAttempted": False, "sdkSigningPassed": False, "sdkExitCode": None,
             "signaturesAbsent": True, "signatureFiles": [],
             "samsungPublisherCertificate": False, "samsungDeviceInstallAuthorized": False,
             "physicalTvTested": False, "baseline": baseline, "manifest": target_manifest,
             "sourcePayloadUnchanged": matches_source, "stagedPayloadUnchanged": matches_copy,
             "archivePayloadFiles": len(actual), "archivePayloadHashes": actual,
             "archivePayloadMatches": True,
             "latestMetadataChangedSinceCapture": sha(Path(baseline["sourceMetadata"]).read_bytes()) != baseline["sourceMetadataSha256"],
             "artifact": {"name": artifact.name, "size": destination.stat().st_size,
                          "sha256": sha(destination.read_bytes()), "evidencePath": str(destination)}}
    (evidence / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps({"status": proof["status"], "sdkSigningPassed": False,
                      "proof": str(evidence / "proof.json"), "artifact": proof["artifact"]}))


if __name__ == "__main__":
    if sys.argv[1] == "stage":
        stage(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), sys.argv[5])
    elif sys.argv[1] == "verify":
        verify(Path(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4]), sys.argv[5] if len(sys.argv) > 5 else "TVBroLocalQualification")
    elif sys.argv[1] == "unsigned":
        unsigned(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        raise SystemExit("Expected stage, verify or unsigned")
