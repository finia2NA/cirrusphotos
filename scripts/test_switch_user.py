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

    def path(self, name):
        return self.root / name

    def test_real_and_test_round_trip_preserves_both_caches(self):
        self.assertEqual(switch_user.switch_user(self.root, "test"), "test")
        self.assertEqual(self.path(".env").read_text(), "test fixture")
        self.assertTrue(self.path(".cache.real/real").exists())
        self.path(".cache/test").write_text("test cache")
        self.assertEqual(switch_user.switch_user(self.root, "real"), "real")
        self.assertEqual(self.path(".env").read_text(), "real fixture")
        self.assertTrue(self.path(".cache/real").exists())
        self.assertTrue(self.path(".cache.test/test").exists())
        self.assertEqual(switch_user.switch_user(self.root, "test"), "test")
        self.assertTrue(self.path(".cache/test").exists())

    def test_none_has_no_env_and_a_fresh_cache_that_is_deleted_on_leaving(self):
        self.assertEqual(switch_user.switch_user(self.root, "none"), "none")
        self.assertFalse(self.path(".env").exists())
        self.assertEqual(self.path(".env.real").read_text(), "real fixture")
        self.assertEqual(self.path(".env.test").read_text(), "test fixture")
        self.assertEqual(list(self.path(".cache").iterdir()), [])
        self.assertTrue(self.path(".cache.real/real").exists())
        self.path(".cache/none").write_text("in-app account cache")

        self.assertEqual(switch_user.switch_user(self.root, "test"), "test")
        self.assertEqual(self.path(".env").read_text(), "test fixture")
        self.assertFalse(self.path(".cache/none").exists())
        self.assertFalse(self.path(".cache.none-discard").exists())

        self.assertEqual(switch_user.switch_user(self.root, "none"), "none")
        self.assertEqual(list(self.path(".cache").iterdir()), [])
        self.assertEqual(switch_user.switch_user(self.root, "real"), "real")
        self.assertTrue(self.path(".cache/real").exists())
        self.assertEqual(switch_user.active_target(self.root), "real")

    def test_switching_to_the_active_target_changes_nothing(self):
        self.assertEqual(switch_user.switch_user(self.root, "real"), "real")
        self.assertEqual(self.path(".env").read_text(), "real fixture")
        self.assertTrue(self.path(".cache/real").exists())

    def test_unknown_target_and_ambiguous_layouts_are_refused(self):
        with self.assertRaises(RuntimeError):
            switch_user.switch_user(self.root, "other")
        self.path(".cache.real").mkdir()
        with self.assertRaises(RuntimeError):
            switch_user.switch_user(self.root, "test")
        self.assertEqual(self.path(".env").read_text(), "real fixture")
        self.assertTrue(self.path(".cache/real").exists())
        self.path(".env.real").write_text("second real fixture")
        with self.assertRaises(RuntimeError):
            switch_user.active_target(self.root)

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
                switch_user.switch_user(self.root, "test")
        self.assertEqual(self.path(".env").read_text(), "real fixture")
        self.assertEqual(self.path(".env.test").read_text(), "test fixture")
        self.assertTrue(self.path(".cache/real").exists())
        self.assertFalse(self.path(".cache.real").exists())

    def test_failed_switch_from_none_keeps_its_cache(self):
        switch_user.switch_user(self.root, "none")
        self.path(".cache/none").write_text("in-app account cache")
        rename = switch_user.os.rename
        calls = 0

        def fail_second(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("fixture failure")
            rename(source, destination)

        with patch.object(switch_user.os, "rename", side_effect=fail_second):
            with self.assertRaises(OSError):
                switch_user.switch_user(self.root, "real")
        self.assertEqual(switch_user.active_target(self.root), "none")
        self.assertTrue(self.path(".cache/none").exists())


if __name__ == "__main__":
    unittest.main()
