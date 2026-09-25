"""Stage only committed recipe and toolchain inputs for the disposable VM."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()


def stage_recipe(root: Path, recipe: Path, destination: Path) -> Path:
    root = root.resolve()
    relative = recipe.resolve().relative_to(root)
    # A build must identify one reviewed revision, including its recipe. Ignore
    # untracked local build outputs; git archive cannot include them.
    if git(root, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Commit tracked changes before building an image")
    revision = git(root, "rev-parse", "HEAD")
    destination.mkdir(parents=True, exist_ok=False)
    recipe_archive = destination / "recipe.tar"
    subprocess.run(["git", "-C", str(root), "archive", "--format=tar",
                    f"--output={recipe_archive}", revision, str(relative)], check=True)
    with tarfile.open(recipe_archive) as archive:
        archive.extractall(destination, filter="data")
    recipe_archive.unlink()
    staged = destination / relative
    if not (staged / "recipe.json").is_file():
        raise ValueError("The recipe must be committed in the repository")
    payload = staged / "orocos"
    payload.mkdir(exist_ok=True)
    source_archive = payload / "source.tar.gz"
    subprocess.run(["git", "-C", str(root), "archive", "--format=tar.gz",
                    f"--output={source_archive}", revision], check=True)
    identity = {
        "revision": revision,
        "tree": git(root, "rev-parse", f"{revision}^{{tree}}"),
        "source_archive_sha256": hashlib.sha256(source_archive.read_bytes()).hexdigest(),
    }
    (payload / "source.json").write_text(json.dumps(identity, indent=2) + "\n")
    return staged
