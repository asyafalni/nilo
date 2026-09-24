"""The one piece of the documentation site that is not configuration.

The site is `docs/guide/` and nothing else, but the guide links out of itself
on almost every page: to an ADR, to the reference, to a benchmark result, to an
example's `main.zig`. MkDocs cannot serve a file outside its `docs_dir`, so
every such link is rewritten here to the same file on GitHub, pinned to the ref
the site was built from. A page of the 0.6 guide then opens the ADR as it stood
at v0.6.0, not as it stands on main today.

`NILO_DOCS_REF` names that ref; the release workflow sets it to the tag, and a
local `mkdocs serve` falls back to main.
"""

import os
import posixpath
import re

REPO = "https://github.com/nevindra/nilo"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# `](target)` with no scheme, no bare anchor and no mail address in front.
LINK = re.compile(r"\]\((?!https?:|mailto:|#)([^)\s]+)\)")
FENCE = re.compile(r"^\s*(```|~~~)")


def on_page_markdown(markdown, page, config, files):
    ref = os.environ.get("NILO_DOCS_REF", "main")
    docs = os.path.relpath(config["docs_dir"], ROOT).replace(os.sep, "/")
    here = posixpath.join(docs, posixpath.dirname(page.file.src_uri))

    def rewrite(match):
        target, _, anchor = match.group(1).partition("#")
        path = posixpath.normpath(posixpath.join(here, target))
        if path == docs or path.startswith(docs + "/"):
            return match.group(0)
        kind = "tree" if target.endswith("/") or os.path.isdir(os.path.join(ROOT, path)) else "blob"
        url = f"{REPO}/{kind}/{ref}/{path}"
        return f"]({url}#{anchor})" if anchor else f"]({url})"

    out, fenced = [], False
    for line in markdown.split("\n"):
        if FENCE.match(line):
            fenced = not fenced
        out.append(line if fenced else LINK.sub(rewrite, line))
    return "\n".join(out)
