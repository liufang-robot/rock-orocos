import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

from build.stage import stage_recipe


class StageRecipeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository"
        self.root.mkdir()
        self.recipe = self.root / "images/recipes"
        self.recipe.mkdir(parents=True)
        (self.recipe / "recipe.json").write_text('{"steps": []}\n')
        (self.root / "toolchain-input.txt").write_text("committed input\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-qm", "fixture")
        self.destination = Path(self.temporary.name) / "staged"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def test_archive_is_identified_and_excludes_local_outputs(self):
        (self.recipe / ".build").mkdir()
        (self.recipe / ".build/private-key").write_text("must not be uploaded")
        staged = stage_recipe(self.root, self.recipe, self.destination)
        self.assertFalse((staged / ".build").exists())
        identity = json.loads((staged / "orocos/source.json").read_text())
        self.assertEqual(identity["revision"], self.git("rev-parse", "HEAD"))
        archive_path = staged / "orocos/source.tar.gz"
        self.assertEqual(identity["source_archive_sha256"],
                         hashlib.sha256(archive_path.read_bytes()).hexdigest())
        with tarfile.open(archive_path) as archive:
            self.assertEqual(archive.extractfile("toolchain-input.txt").read(), b"committed input\n")
            self.assertFalse(any("private-key" in name or name.startswith(".git/")
                                 for name in archive.getnames()))

    def test_rejects_uncommitted_recipe_or_toolchain_changes(self):
        for path in (self.recipe / "recipe.json", self.root / "toolchain-input.txt"):
            with self.subTest(path=path):
                original = path.read_text()
                path.write_text("uncommitted change\n")
                with self.assertRaisesRegex(ValueError, "Commit tracked changes"):
                    stage_recipe(self.root, self.recipe, self.destination)
                self.assertFalse(self.destination.exists())
                path.write_text(original)

    def test_rejects_staged_but_uncommitted_changes(self):
        (self.root / "toolchain-input.txt").write_text("staged change\n")
        self.git("add", ".")
        with self.assertRaisesRegex(ValueError, "Commit tracked changes"):
            stage_recipe(self.root, self.recipe, self.destination)

    def test_rejects_recipe_outside_the_source_repository(self):
        with self.assertRaises(ValueError):
            stage_recipe(self.root, Path(self.temporary.name), self.destination)


if __name__ == "__main__":
    unittest.main()
