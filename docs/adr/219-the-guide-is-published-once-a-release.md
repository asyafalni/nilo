# The guide is published once a release

**Status:** accepted
**Topic:** [docs-tooling](../design/docs-tooling.md)

## Context

The guide under `docs/guide/` is read on GitHub, where a page renders but there is no search, no navigation between thirty-eight pages, and nothing that says which release a page describes. That last one is the costly part. A user pins a tag (`?ref=vX.Y.Z#…`), and `main` carries `## Unreleased`: a reader following a page on `main` can be reading an API their pinned version does not have.

## Decision

**`docs/guide/` is built into a site with Material for MkDocs and published to GitHub Pages when a release is tagged, one copy per minor release.** `mkdocs.yml` is the configuration, `.github/workflows/docs.yml` publishes it with mike, and `latest` points at the newest tag. A patch lands in its minor's copy, because a patch does not change what the guide teaches.

The guide is the whole site. The reference, the ADRs and the benchmark results stay on GitHub, and every link from the guide into them is rewritten by `docs/site/hooks.py` to the file **at the tag the site was built from**, so a 0.6 page opens the ADR as it stood at v0.6.0. The Markdown is unchanged: `README.md` is each folder's index, and a relative link is still a relative link on GitHub.

`mkdocs.yml` builds strict, heading anchors included, and the `docs` job in `ci.yml` builds it on every push and pull request. A renamed heading that a page still links to fails there rather than on release day. Writing that job found two such links on `main`.

## What it costs, on [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes

Nothing on any of them. No file under `docs/site/` or `mkdocs.yml` is read by `build.zig`, and no binary changes. The cost is a Python toolchain in CI, pinned in `docs/site/requirements.txt`, and about a minute of a runner per tag.

## What was rejected

- **Zensical**, by the same authors and reading the same `mkdocs.yml`. It was 0.0.x when this was written, and its versioning was a fork of mike installed from GitHub, described by its authors as a bridge until native versioning ships. Material for MkDocs has critical support until May 2027; moving is a change to one install line once Zensical versions on its own.
- **Publishing from `main`.** It is the problem above, made public.
- **Zine**, the Zig static site generator. It reads SuperMD rather than Markdown, with front matter on every file, so the guide would have to be converted and would stop rendering as written on GitHub.
- **mdBook and VitePress.** The first wants a hand-kept `SUMMARY.md`, the second does not take `README.md` as an index without rewrites. Neither highlights Zig better than Pygments does.
- **Backfilling v0.5.0.** Its guide fails the strict build (a page missing from the nav, and the two anchors above), and relaxing strictness for one old copy is not worth a second code path. The first copy is 0.6.

## Consequences

- Once, after the first tag publishes: Settings → Pages → Deploy from a branch, `gh-pages`, `/ (root)`.
- A new guide page needs a line in `nav:` in `mkdocs.yml`, in the order `docs/guide/README.md` numbers it. A page missing from the nav fails the `docs` job.
- `pip install -r docs/site/requirements.txt` then `mkdocs serve` shows the site locally with live reload.
