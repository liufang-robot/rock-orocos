#!/usr/bin/env python3

import io
import json
from pathlib import PurePosixPath
import re
import subprocess
import sys
import tarfile
import zipfile


class ArchiveError(RuntimeError):
    pass


def canonical_path(path, context):
    if not isinstance(path, str) or not path:
        raise ArchiveError(f"{context} has an empty or non-string path")
    if "\0" in path or "\\" in path:
        raise ArchiveError(f"{context} has a non-normalized path: {path!r}")
    if PurePosixPath(path).is_absolute():
        raise ArchiveError(f"{context} has an absolute path: {path!r}")
    components = path.split("/")
    if ".." in components:
        raise ArchiveError(f"{context} has a traversal path: {path!r}")
    if any(component in ("", ".") for component in components):
        raise ArchiveError(f"{context} has a non-normalized path: {path!r}")
    if str(PurePosixPath(path)) != path:
        raise ArchiveError(f"{context} has a non-normalized path: {path!r}")
    return path


def safe_link_target(path, target, *, hardlink):
    context = f"archive link {path!r}"
    if not isinstance(target, str) or not target or "\0" in target or "\\" in target:
        raise ArchiveError(f"{context} has an invalid target: {target!r}")
    if PurePosixPath(target).is_absolute():
        raise ArchiveError(f"{context} has an absolute target: {target!r}")
    components = [] if hardlink else path.split("/")[:-1]
    for component in target.split("/"):
        if component in ("", "."):
            raise ArchiveError(f"{context} has a non-normalized target: {target!r}")
        if component == "..":
            if not components:
                raise ArchiveError(f"{context} has an escaping target: {target!r}")
            components.pop()
        else:
            components.append(component)
    if not components:
        raise ArchiveError(f"{context} has an invalid target: {target!r}")
    return "/".join(components)


def reject_path_collisions(entries, context):
    for path, entry in entries.items():
        components = path.split("/")
        for index in range(1, len(components)):
            ancestor = "/".join(components[:index])
            if ancestor in entries and entries[ancestor]["type"] != "directory":
                raise ArchiveError(
                    f"{context} has a path-type collision between {ancestor!r} and {path!r}"
                )


def decompress_zstd(contents, context):
    try:
        result = subprocess.run(
            ["zstd", "-q", "-d", "-c"],
            input=contents,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise ArchiveError(f"cannot run zstd for {context}: {error}") from error
    if result.returncode != 0:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()
        raise ArchiveError(f"cannot decompress {context}: {diagnostic}")
    return result.stdout


def read_tar(contents, context):
    entries = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:") as archive:
            for member in archive:
                path = canonical_path(member.name, context)
                if path in entries:
                    raise ArchiveError(f"{context} has duplicate path {path!r}")

                if member.isreg():
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise ArchiveError(f"{context} cannot read regular file {path!r}")
                    data = stream.read()
                    if len(data) != member.size:
                        raise ArchiveError(f"{context} has truncated file {path!r}")
                    entry = {"type": "file", "contents": data}
                elif member.isdir():
                    entry = {"type": "directory"}
                elif member.issym():
                    target = safe_link_target(path, member.linkname, hardlink=False)
                    entry = {"type": "symlink", "target": target}
                elif member.islnk():
                    target = safe_link_target(path, member.linkname, hardlink=True)
                    entry = {"type": "hardlink", "target": target}
                else:
                    raise ArchiveError(
                        f"{context} has unsupported entry type {member.type!r} at {path!r}"
                    )
                entries[path] = entry
    except (tarfile.TarError, EOFError, OSError) as error:
        raise ArchiveError(f"cannot parse {context}: {error}") from error

    reject_path_collisions(entries, context)
    for path, entry in entries.items():
        if entry["type"] != "hardlink":
            continue
        target = entry["target"]
        target_entry = entries.get(target)
        if target_entry is None:
            raise ArchiveError(f"{context} hardlink {path!r} has missing target {target!r}")
        if target_entry["type"] not in ("file", "hardlink"):
            raise ArchiveError(f"{context} hardlink {path!r} has invalid target {target!r}")
    return entries


def parse_paths_json(info_entries):
    path = "info/paths.json"
    entry = info_entries.get(path)
    if entry is None or entry["type"] != "file":
        raise ArchiveError("info archive must contain one regular info/paths.json")
    try:
        document = json.loads(entry["contents"].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ArchiveError(f"invalid info/paths.json: {error}") from error
    if not isinstance(document, dict) or document.get("paths_version") != 1:
        raise ArchiveError("info/paths.json paths_version must be 1")
    if set(document) != {"paths_version", "paths"} or not isinstance(document["paths"], list):
        raise ArchiveError("info/paths.json must contain only paths_version and a paths array")

    paths = {}
    for item in document["paths"]:
        if not isinstance(item, dict):
            raise ArchiveError("info/paths.json entries must be objects")
        path = canonical_path(item.get("_path"), "info/paths.json")
        path_type = item.get("path_type")
        if path_type not in ("hardlink", "softlink", "directory"):
            raise ArchiveError(f"info/paths.json has invalid type for {path!r}: {path_type!r}")
        if path in paths:
            raise ArchiveError(f"info/paths.json has duplicate path {path!r}")
        paths[path] = {"type": path_type}
    reject_path_collisions(paths, "info/paths.json")
    return paths


def validate_payload(payload_entries, documented_paths):
    actual_paths = {}
    type_mapping = {
        "file": "hardlink",
        "hardlink": "hardlink",
        "symlink": "softlink",
        "directory": "directory",
    }
    for path, entry in payload_entries.items():
        actual_paths[path] = {"type": type_mapping[entry["type"]]}

    hidden = sorted(set(actual_paths) - set(documented_paths))
    if hidden:
        raise ArchiveError(f"package payload has unreported path(s): {', '.join(hidden)}")
    missing = sorted(set(documented_paths) - set(actual_paths))
    if missing:
        raise ArchiveError(f"info/paths.json has missing payload path(s): {', '.join(missing)}")
    for path in sorted(actual_paths):
        actual_type = actual_paths[path]["type"]
        expected_type = documented_paths[path]["type"]
        if actual_type != expected_type:
            raise ArchiveError(
                f"package payload type for {path!r} is {actual_type}, "
                f"info/paths.json reports {expected_type}"
            )
    return [
        {"path": path, "type": actual_paths[path]["type"]}
        for path in sorted(actual_paths)
    ]


def inspect_conda(path):
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = [member.filename for member in members]
            if len(names) != len(set(names)):
                raise ArchiveError("conda ZIP has duplicate members")
            for member in members:
                canonical_path(member.filename, "conda ZIP")
                if "/" in member.filename or member.is_dir():
                    raise ArchiveError(f"conda ZIP member must be a root file: {member.filename!r}")
                if member.flag_bits & 1:
                    raise ArchiveError(f"conda ZIP member is encrypted: {member.filename!r}")
            corrupt = archive.testzip()
            if corrupt:
                raise ArchiveError(f"conda ZIP member failed CRC validation: {corrupt!r}")

            info_names = [name for name in names if re.fullmatch(r"info-.+\.tar\.zst", name)]
            package_names = [name for name in names if re.fullmatch(r"pkg-.+\.tar\.zst", name)]
            if len(info_names) != 1:
                raise ArchiveError(f"conda ZIP must contain exactly one info tar, found {len(info_names)}")
            if len(package_names) != 1:
                raise ArchiveError(
                    f"conda ZIP must contain exactly one package payload tar, found {len(package_names)}"
                )
            expected_names = {"metadata.json", info_names[0], package_names[0]}
            unexpected = sorted(set(names) - expected_names)
            if unexpected:
                raise ArchiveError(f"conda ZIP has unexpected member(s): {', '.join(unexpected)}")
            if "metadata.json" not in names:
                raise ArchiveError("conda ZIP is missing metadata.json")

            try:
                metadata = json.loads(archive.read("metadata.json").decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise ArchiveError(f"invalid conda metadata.json: {error}") from error
            if metadata != {"conda_pkg_format_version": 2}:
                raise ArchiveError("conda metadata.json must declare only format version 2")

            info_tar = decompress_zstd(archive.read(info_names[0]), info_names[0])
            package_tar = decompress_zstd(archive.read(package_names[0]), package_names[0])
    except (zipfile.BadZipFile, OSError, RuntimeError) as error:
        if isinstance(error, ArchiveError):
            raise
        raise ArchiveError(f"cannot parse conda ZIP: {error}") from error

    info_entries = read_tar(info_tar, "conda info tar")
    for name in info_entries:
        if not name.startswith("info/"):
            raise ArchiveError(f"conda info tar has path outside info/: {name!r}")
    payload_entries = read_tar(package_tar, "conda package payload tar")
    documented_paths = parse_paths_json(info_entries)
    return {"paths": validate_payload(payload_entries, documented_paths)}


def main():
    if len(sys.argv) != 2:
        raise ArchiveError("usage: inspect-conda-archive.py PACKAGE.conda")
    result = inspect_conda(sys.argv[1])
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except ArchiveError as error:
        print(f"invalid conda archive: {error}", file=sys.stderr)
        raise SystemExit(1)
