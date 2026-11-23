#!/usr/bin/env python3
"""Render CHANGELOG.md for the website and Sparkle's cumulative embedded notes."""

import argparse
import html
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent


def read_versions(text):
    headings = list(re.finditer(r"^## ([^\n]+)$", text, re.MULTILINE))
    versions = []
    for index, heading in enumerate(headings):
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        versions.append((heading[1].strip(), text[heading.end():end].strip()))
    if not versions:
        raise ValueError("CHANGELOG.md has no version sections")
    return versions


def inline(text, repo):
    escaped = html.escape(text)
    escaped = re.sub(r"#(\d+)\b", lambda match: (
        f'<a href="https://github.com/{repo}/issues/{match[1]}">{match[0]}</a>'
    ), escaped)
    return re.sub(r"(?<!\w)@([A-Za-z0-9-]+)", lambda match: (
        f'<a href="https://github.com/{match[1]}">{match[0]}</a>'
    ), escaped)


def render_body(text, repo):
    blocks = []
    paragraph = []
    bullets = []

    def flush():
        if paragraph:
            blocks.append("<p>" + inline(" ".join(paragraph), repo) + "</p>")
            paragraph.clear()
        if bullets:
            blocks.append("<ul>\n" + "\n".join(f"<li>{inline(item, repo)}</li>" for item in bullets) + "\n</ul>")
            bullets.clear()

    for line in text.splitlines():
        if not line.strip():
            flush()
        elif line.startswith("- "):
            if paragraph:
                flush()
            bullets.append(line[2:])
        else:
            if bullets:
                flush()
            paragraph.append(line.strip())
    flush()
    return "\n".join(blocks)


def render_notes(versions, repo, version=None):
    if version is not None:
        names = [name for name, _ in versions]
        if version not in names:
            raise ValueError(f"CHANGELOG.md has no section for {version}")
        versions = versions[names.index(version):]
    return "\n".join(
        f'<section id="version-{html.escape(name, quote=True)}">\n'
        f'<h2>{html.escape(name)}</h2>\n{render_body(body, repo)}\n</section>'
        for name, body in versions
    )


def render_page(notes, site_url):
    home = (ROOT / "website/index.html").read_text()
    header = re.search(r'<header class="site">.*?</header>', home, re.DOTALL)[0]
    header = header.replace('href="changelog.html"', 'href="changelog.html" aria-current="page"')
    footer = re.search(r'<footer class="site">.*?</footer>', home, re.DOTALL)[0]
    return f"""<!doctype html>
<!-- Generated from CHANGELOG.md by scripts/generate_changelog.py. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Changelog - Cirrus Photos</title>
<meta name="description" content="Changes in each version of Cirrus Photos.">
<link rel="canonical" href="{html.escape(site_url, quote=True)}/changelog.html">
<link rel="icon" type="image/png" href="assets/favicon.png">
<link rel="apple-touch-icon" href="assets/icon.png">
<link rel="stylesheet" href="style.css?v=changelog">
</head>
<body>
<div class="page">
{header}
<main class="changelog">
<h1>Changelog</h1>
{notes}
</main>
{footer}
</div>
</body>
</html>
"""


def update_appcast(text, versions, repo, site_url):
    def update_item(match):
        item = match[0]
        version = re.search(r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>", item)[1]
        notes = render_notes(versions, repo, html.unescape(version))
        description = "<description><![CDATA[\n" + notes + "\n]]></description>"
        item, replaced = re.subn(r"<description(?:\s[^>]*)?>.*?</description>", lambda _: description,
                                 item, count=1, flags=re.DOTALL)
        if replaced != 1:
            raise ValueError(f"Appcast item {version} has no description")
        link = f"<sparkle:fullReleaseNotesLink>{html.escape(site_url)}/changelog.html</sparkle:fullReleaseNotesLink>"
        if "<sparkle:fullReleaseNotesLink>" in item:
            item = re.sub(r"<sparkle:fullReleaseNotesLink>.*?</sparkle:fullReleaseNotesLink>",
                          lambda _: link, item, flags=re.DOTALL)
        else:
            item = item.replace("<description>", link + "\n      <description>", 1)
        return item

    return re.sub(r"<item>.*?</item>", update_item, text, flags=re.DOTALL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fragment", action="store_true", help="Print cumulative Sparkle HTML")
    parser.add_argument("--version", help="Include this version and earlier versions")
    parser.add_argument("--update-appcast", action="store_true", help="Regenerate existing item descriptions")
    parser.add_argument("--site-url", default="https://cirrusphotos.richardhanss.de")
    parser.add_argument("--repo", default="finia2NA/cirrusphotos")
    args = parser.parse_args()
    versions = read_versions((ROOT / "CHANGELOG.md").read_text())
    if args.fragment:
        print(render_notes(versions, args.repo, args.version))
        return
    page = render_page(render_notes(versions, args.repo), args.site_url.rstrip("/"))
    (ROOT / "website/changelog.html").write_text(page)
    if args.update_appcast:
        path = ROOT / "website/appcast.xml"
        path.write_text(update_appcast(path.read_text(), versions, args.repo, args.site_url.rstrip("/")))


if __name__ == "__main__":
    main()
