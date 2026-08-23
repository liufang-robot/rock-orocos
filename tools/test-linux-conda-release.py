#!/usr/bin/env python3

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import warnings
import zipfile


ROOT = Path(__file__).resolve().parent.parent
RELEASE_TOOL = ROOT / "tools" / "prepare-linux-conda-release.rb"
SOURCE_LOCK = ROOT / "packaging" / "source-lock.json"
RUNTIME_BUILD = "h0000000_0"
DEV_BUILD = "h1111111_0"


def file_entry(name, contents=b"payload"):
    return {"name": name, "type": "file", "contents": contents}


def symlink_entry(name, target):
    return {"name": name, "type": "symlink", "target": target}


def hardlink_entry(name, target):
    return {"name": name, "type": "hardlink", "target": target}


def path_record(name, path_type="hardlink"):
    return {"_path": name, "path_type": path_type}


def tar_bytes(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for entry in entries:
            item = tarfile.TarInfo(entry["name"])
            item.mtime = 0
            item.uid = 0
            item.gid = 0
            item.uname = ""
            item.gname = ""
            if entry["type"] == "file":
                contents = entry["contents"]
                item.mode = 0o644
                item.size = len(contents)
                archive.addfile(item, io.BytesIO(contents))
            elif entry["type"] == "symlink":
                item.type = tarfile.SYMTYPE
                item.mode = 0o777
                item.linkname = entry["target"]
                archive.addfile(item)
            elif entry["type"] == "hardlink":
                item.type = tarfile.LNKTYPE
                item.mode = 0o644
                item.linkname = entry["target"]
                archive.addfile(item)
            else:
                raise ValueError(f"unknown fixture entry type: {entry['type']}")
    return output.getvalue()


def zstd_compress(contents):
    result = subprocess.run(
        ["zstd", "-q", "-c"], input=contents, capture_output=True, check=False
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout


def zip_info(name):
    item = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    item.compress_type = zipfile.ZIP_STORED
    item.external_attr = 0o100644 << 16
    return item


def build_conda(
    path,
    package_name,
    build,
    payload_entries,
    documented_paths,
    *,
    extra_zip_members=None,
    second_info_archive=False,
    malformed=False,
):
    if malformed:
        path.write_bytes(b"not a zip archive")
        return

    paths_document = {
        "paths_version": 1,
        "paths": documented_paths,
    }
    info_entries = [
        file_entry(
            "info/index.json",
            json.dumps(
                {
                    "name": package_name,
                    "version": "0.1.0",
                    "build": build,
                    "build_number": 0,
                    "subdir": "linux-64",
                },
                sort_keys=True,
            ).encode(),
        ),
        file_entry(
            "info/paths.json",
            json.dumps(paths_document, sort_keys=True).encode(),
        ),
    ]
    info_archive = zstd_compress(tar_bytes(info_entries))
    payload_archive = zstd_compress(tar_bytes(payload_entries))
    stem = f"{package_name}-0.1.0-{build}"

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(path, mode="w", allowZip64=True) as archive:
            archive.writestr(
                zip_info("metadata.json"),
                json.dumps({"conda_pkg_format_version": 2}, sort_keys=True),
            )
            archive.writestr(zip_info(f"pkg-{stem}.tar.zst"), payload_archive)
            archive.writestr(zip_info(f"info-{stem}.tar.zst"), info_archive)
            if second_info_archive:
                archive.writestr(zip_info("info-extra.tar.zst"), info_archive)
            for name, contents in extra_zip_members or []:
                archive.writestr(zip_info(name), contents)


def package_metadata(name, build, documented_paths):
    depends = ["__glibc >=2.17"]
    if name == "orocos-dev":
        depends.append(f"orocos ==0.1.0 {RUNTIME_BUILD}")
    return {
        "about": {
            "summary": f"{name} summary",
            "description": f"{name} description",
        },
        "index": {
            "name": name,
            "version": "0.1.0",
            "build": build,
            "build_number": 0,
            "subdir": "linux-64",
            "depends": depends,
        },
        "paths": {"paths": documented_paths},
    }


def write_package_pair(directory, runtime_spec):
    directory.mkdir(parents=True)
    runtime_path = directory / f"orocos-0.1.0-{RUNTIME_BUILD}.conda"
    dev_path = directory / f"orocos-dev-0.1.0-{DEV_BUILD}.conda"

    build_conda(
        runtime_path,
        "orocos",
        RUNTIME_BUILD,
        runtime_spec.get("payload", [file_entry("runtime/file")]),
        runtime_spec.get("paths", [path_record("runtime/file")]),
        extra_zip_members=runtime_spec.get("extra_zip_members"),
        second_info_archive=runtime_spec.get("second_info_archive", False),
        malformed=runtime_spec.get("malformed", False),
    )
    dev_payload = [file_entry("development/file", b"development")]
    dev_paths = [path_record("development/file")]
    build_conda(dev_path, "orocos-dev", DEV_BUILD, dev_payload, dev_paths)

    metadata = {
        runtime_path.name: package_metadata(
            "orocos", RUNTIME_BUILD, runtime_spec.get("paths", [path_record("runtime/file")])
        ),
        dev_path.name: package_metadata("orocos-dev", DEV_BUILD, dev_paths),
    }
    return [runtime_path, dev_path], metadata


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def manifest_package(path, metadata):
    index = metadata["index"]
    return {
        "name": index["name"],
        "version": index["version"],
        "build": index["build"],
        "build_number": index["build_number"],
        "subdir": index["subdir"],
        "filename": path.name,
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
        "paths": len(metadata["paths"]["paths"]),
        "depends": index["depends"],
    }


def write_release_bundle(directory, paths, metadata, channel="liufang-robot/orocos"):
    shutil.copyfile(SOURCE_LOCK, directory / "source-lock.json")
    lock_hash = sha256(directory / "source-lock.json")
    packages = sorted(
        [manifest_package(path, metadata[path.name]) for path in paths],
        key=lambda item: item["name"],
    )
    manifest = {
        "schema_version": 1,
        "channel": channel,
        "target_platform": "linux-64",
        "version": "0.1.0",
        "repository_commit": "",
        "source_lock": {"filename": "source-lock.json", "sha256": lock_hash},
        "packages": packages,
    }
    (directory / "release-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    checksum_lines = [
        f"{item['sha256']}  {item['filename']}"
        for item in sorted(packages, key=lambda item: item["filename"])
    ]
    checksum_lines.append(f"{lock_hash}  source-lock.json")
    (directory / "SHA256SUMS.txt").write_text(
        "\n".join(checksum_lines) + "\n", encoding="utf-8"
    )


def write_repodata(directory, paths):
    packages = {
        path.name: {"sha256": sha256(path), "size": path.stat().st_size}
        for path in paths
    }
    (directory / "repodata.json").write_text(
        json.dumps({"packages.conda": packages}), encoding="utf-8"
    )


def write_rattler_stub(directory):
    directory.mkdir()
    stub = directory / "rattler-build"
    stub.write_text(
        """#!/usr/bin/env ruby
require "json"
if ARGV == ["--version"]
  puts "rattler-build fixture"
elsif ARGV[0, 2] == ["package", "inspect"]
  metadata = JSON.parse(File.read(ENV.fetch("OROCOS_TEST_PACKAGE_METADATA")))
  puts JSON.generate(metadata.fetch(File.basename(ARGV.fetch(2))))
else
  warn "unexpected rattler-build arguments: #{ARGV.inspect}"
  exit 1
end
""",
        encoding="utf-8",
    )
    stub.chmod(0o755)


def run_release(arguments, stub_directory, metadata_path):
    environment = os.environ.copy()
    environment["PATH"] = f"{stub_directory}{os.pathsep}{environment['PATH']}"
    environment["OROCOS_TEST_PACKAGE_METADATA"] = str(metadata_path)
    return subprocess.run(
        ["ruby", str(RELEASE_TOOL), *arguments],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


def verify_fixture(root, label, runtime_spec, stub_directory):
    bundle = root / label
    paths, metadata = write_package_pair(bundle, runtime_spec)
    write_release_bundle(bundle, paths, metadata)
    metadata_path = root / f"{label}-metadata.json"
    metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
    result = run_release(
        ["--mode", "verify", "--release-directory", str(bundle)],
        stub_directory,
        metadata_path,
    )
    return result


def main():
    failures = []
    scenarios = {
        "traversal payload": {
            "payload": [file_entry("../escape")],
            "paths": [path_record("../escape")],
        },
        "absolute payload": {
            "payload": [file_entry("/absolute")],
            "paths": [path_record("/absolute")],
        },
        "duplicate payload path": {
            "payload": [file_entry("runtime/file"), file_entry("runtime/file", b"two")],
            "paths": [path_record("runtime/file")],
        },
        "unsafe symlink": {
            "payload": [symlink_entry("runtime/link", "../../escape")],
            "paths": [path_record("runtime/link", "softlink")],
        },
        "unsafe hardlink": {
            "payload": [hardlink_entry("runtime/link", "../../escape")],
            "paths": [path_record("runtime/link")],
        },
        "hidden payload entry": {
            "payload": [file_entry("runtime/file"), file_entry("runtime/hidden")],
            "paths": [path_record("runtime/file")],
        },
        "paths.json type mismatch": {
            "payload": [file_entry("runtime/file")],
            "paths": [path_record("runtime/file", "softlink")],
        },
        "non-normalized payload": {
            "payload": [file_entry("runtime//file")],
            "paths": [path_record("runtime//file")],
        },
        "payload path collision": {
            "payload": [file_entry("runtime/file"), file_entry("runtime/file/child")],
            "paths": [path_record("runtime/file"), path_record("runtime/file/child")],
        },
        "ambiguous info archive": {"second_info_archive": True},
        "unsafe ZIP member": {"extra_zip_members": [("../hidden", b"hidden")]},
        "malformed ZIP": {"malformed": True},
    }

    with tempfile.TemporaryDirectory(prefix="orocos-conda-release-") as temporary:
        root = Path(temporary)
        stub_directory = root / "bin"
        write_rattler_stub(stub_directory)

        valid = verify_fixture(root, "valid", {}, stub_directory)
        if valid.returncode != 0:
            failures.append(f"valid archive was rejected: {valid.stdout}{valid.stderr}")

        for label, runtime_spec in scenarios.items():
            result = verify_fixture(root, label.replace(" ", "-"), runtime_spec, stub_directory)
            if result.returncode == 0:
                failures.append(f"release verification accepted {label}")

        package_directory = root / "packages"
        paths, metadata = write_package_pair(package_directory, {})
        write_repodata(package_directory, paths)
        metadata_path = root / "stage-metadata.json"
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")

        failed_destination = root / "failed-release"
        failed_stage = run_release(
            [
                "--mode",
                "stage",
                "--package-directory",
                str(package_directory),
                "--release-directory",
                str(failed_destination),
                "--channel",
                "invalid@channel",
            ],
            stub_directory,
            metadata_path,
        )
        if failed_stage.returncode == 0:
            failures.append("invalid channel unexpectedly staged a release")
        if failed_destination.exists():
            failures.append("failed staging left a partial final release directory")

        occupied_destination = root / "occupied-release"
        occupied_destination.mkdir()
        marker = occupied_destination / "marker"
        marker.write_text("keep", encoding="utf-8")
        occupied_stage = run_release(
            [
                "--mode",
                "stage",
                "--package-directory",
                str(package_directory),
                "--release-directory",
                str(occupied_destination),
            ],
            stub_directory,
            metadata_path,
        )
        if occupied_stage.returncode == 0:
            failures.append("staging overwrote a nonempty destination")
        if marker.read_text(encoding="utf-8") != "keep":
            failures.append("staging changed a nonempty destination")

        successful_destination = root / "successful-release"
        successful_stage = run_release(
            [
                "--mode",
                "stage",
                "--package-directory",
                str(package_directory),
                "--release-directory",
                str(successful_destination),
            ],
            stub_directory,
            metadata_path,
        )
        if successful_stage.returncode != 0:
            failures.append(
                f"valid release staging failed: {successful_stage.stdout}{successful_stage.stderr}"
            )

    if failures:
        raise RuntimeError("\n".join(failures))

    print("Linux conda release archive tests passed.")


if __name__ == "__main__":
    main()
