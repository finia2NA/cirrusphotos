import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import switch_user


class SwitchUserTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / ".env").write_text("real fixture")
        (self.root / ".env.test").write_text("test fixture")
        (self.root / ".cache").mkdir()
        (self.root / ".cache" / "real").write_text("real cache")

    def test_round_trip_preserves_both_caches(self):
        self.assertEqual(switch_user.switch_user(self.root), "phototest")
        self.assertEqual((self.root / ".env").read_text(), "test fixture")
        self.assertTrue((self.root / ".cache.real" / "real").exists())
        (self.root / ".cache" / "test").write_text("test cache")
        self.assertEqual(switch_user.switch_user(self.root), "real user")
        self.assertEqual((self.root / ".env").read_text(), "real fixture")
        self.assertTrue((self.root / ".cache" / "real").exists())
        self.assertTrue((self.root / ".cache.test" / "test").exists())
        self.assertEqual(switch_user.switch_user(self.root), "phototest")
        self.assertTrue((self.root / ".cache" / "test").exists())

    def test_ambiguous_backup_is_not_overwritten(self):
        (self.root / ".cache.real").mkdir()
        with self.assertRaises(RuntimeError):
            switch_user.switch_user(self.root)
        self.assertEqual((self.root / ".env").read_text(), "real fixture")
        self.assertTrue((self.root / ".cache" / "real").exists())

    def test_failed_rename_restores_original_layout(self):
        rename = switch_user.os.rename
        calls = 0

        def fail_once(source, destination):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError("fixture failure")
            rename(source, destination)

        with patch.object(switch_user.os, "rename", side_effect=fail_once):
            with self.assertRaises(OSError):
                switch_user.switch_user(self.root)
        self.assertEqual((self.root / ".env").read_text(), "real fixture")
        self.assertEqual((self.root / ".env.test").read_text(), "test fixture")
        self.assertTrue((self.root / ".cache" / "real").exists())
        self.assertFalse((self.root / ".cache.real").exists())


if __name__ == "__main__":
    unittest.main()
