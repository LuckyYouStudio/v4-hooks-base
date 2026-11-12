#!/usr/bin/env python3
"""Checks that every relative link in the repository's Markdown files resolves to a file in the repository.

    python3 script/check-links.py          # exit code 1 if anything is broken

Checked:
  1. Markdown links and images  [text](target)  whose target is not http(s)/mailto/#anchor.
  2. Back-ticked paths that point into audits/ or docs/research/ (written either relative to the
     repository root or relative to the file), because most cross-references here are written as code.
Skipped: lib/, out/, cache/, broadcast/, checker/out, checker/cache, checker/reports-local, .git.
"""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SKIP = {"lib", "out", "cache", "broadcast", ".git", os.path.join("checker", "out"),
        os.path.join("checker", "cache"), os.path.join("checker", "reports-local")}
LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
CODE_PATH = re.compile(r"`((?:\.\./)*(?:audits|docs/research)/[A-Za-z0-9_./-]*)`")


def md_files():
    for base, dirs, files in os.walk(ROOT):
        rel = os.path.relpath(base, ROOT)
        dirs[:] = [d for d in dirs if os.path.normpath(os.path.join(rel, d)) not in SKIP]
        for f in files:
            if f.endswith(".md"):
                yield os.path.join(base, f)


def main():
    broken, n_links, n_paths, n_files = [], 0, 0, 0
    for path in sorted(md_files()):
        n_files += 1
        here = os.path.dirname(path)
        text = open(path, encoding="utf-8").read()
        for lineno, line in enumerate(text.split("\n"), 1):
            for m in LINK.finditer(line):
                target = m.group(1)
                if re.match(r"^(https?:|mailto:|#)", target) or target.startswith("<"):
                    continue
                n_links += 1
                target = target.split("#")[0]
                if not os.path.exists(os.path.normpath(os.path.join(here, target))):
                    broken.append((path, lineno, "link", m.group(1)))
            for m in CODE_PATH.finditer(line):
                n_paths += 1
                t = m.group(1)
                if not (os.path.exists(os.path.normpath(os.path.join(here, t)))
                        or os.path.exists(os.path.normpath(os.path.join(ROOT, t)))):
                    broken.append((path, lineno, "path", t))
    for path, lineno, kind, target in broken:
        print("BROKEN %s  %s:%d  %s" % (kind, os.path.relpath(path, ROOT), lineno, target))
    print("%d markdown files, %d relative links, %d back-ticked audits/ or docs/research/ paths, %d broken"
          % (n_files, n_links, n_paths, len(broken)))
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
