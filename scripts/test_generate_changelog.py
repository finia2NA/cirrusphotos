import unittest
import xml.etree.ElementTree as ET

import generate_changelog as changelog


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.versions = changelog.read_versions(
            "# Changelog\n\n## 0.2\n\n- New feature\n\nThanks to @reporter for #12.\n\n"
            "## 0.1\n\nFirst release.\n\n- Original feature\n"
        )

    def test_notes_include_offered_and_earlier_versions_in_source_order(self):
        latest = changelog.render_notes(self.versions, "owner/repo", "0.2")
        self.assertLess(latest.index("<h2>0.2</h2>"), latest.index("<h2>0.1</h2>"))
        self.assertIn("Original feature", latest)
        older = changelog.render_notes(self.versions, "owner/repo", "0.1")
        self.assertIn("First release.", older)
        self.assertNotIn("New feature", older)
        with self.assertRaises(ValueError):
            changelog.render_notes(self.versions, "owner/repo", "missing")

    def test_text_is_escaped_and_issue_and_reporter_links_are_clickable(self):
        result = changelog.render_body('- A <script> & "quote"\n\nThanks @reporter for #12.', "owner/repo")
        self.assertNotIn("<script>", result)
        self.assertIn("&lt;script&gt; &amp; &quot;quote&quot;", result)
        self.assertIn('href="https://github.com/owner/repo/issues/12"', result)
        self.assertIn('href="https://github.com/reporter"', result)

    def test_appcast_keeps_signed_download_and_version_metadata(self):
        original = """<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><title>Version 0.2</title><sparkle:version>2</sparkle:version>
<sparkle:shortVersionString>0.2</sparkle:shortVersionString><pubDate>date</pubDate>
<description><![CDATA[old notes]]></description>
<enclosure url="https://example.test/app.dmg" sparkle:edSignature="signature" length="123" /></item>
</channel></rss>"""
        result = changelog.update_appcast(original, self.versions, "owner/repo", "https://example.test")
        before = ET.fromstring(original).find("./channel/item")
        after = ET.fromstring(result).find("./channel/item")
        for tag in ("title", "{http://www.andymatuschak.org/xml-namespaces/sparkle}version", "pubDate"):
            self.assertEqual(before.findtext(tag), after.findtext(tag))
        self.assertEqual(before.find("enclosure").attrib, after.find("enclosure").attrib)
        self.assertIn("Original feature", after.findtext("description"))
        self.assertEqual(after.findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}fullReleaseNotesLink"),
                         "https://example.test/changelog.html")
        self.assertEqual(result, changelog.update_appcast(result, self.versions, "owner/repo", "https://example.test"))

    def test_website_uses_same_complete_history_and_active_navigation(self):
        notes = changelog.render_notes(self.versions, "owner/repo")
        page = changelog.render_page(notes, "https://example.test")
        self.assertIn(notes, page)
        self.assertIn('href="changelog.html" aria-current="page"', page)


if __name__ == "__main__":
    unittest.main()
