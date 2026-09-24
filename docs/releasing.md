# Cutting a release

What happens between `## Unreleased` and a tag. Read it when you cut one; the rest of the time [`CHANGELOG.md`](../CHANGELOG.md) is all anybody needs.

**`CHANGELOG.md` holds one release, the untagged one.** Work lands under `## Unreleased`. Cutting a release renames that heading to the version and bumps it in five other places:

- `.version` in `build.zig.zon`
- the badge and the `?ref=` in `README.md`
- the `?ref=` in `docs/guide/getting-started.md`
- the "needs Zig" line in `docs/roadmap.md`
- the comment in `stress/arsip/build.zig.zon`

The version follows the size of the change: a fix or any small change is a patch, minor is for new features, major for breaks.

**The two `?ref=` lines carry the tag's commit after a `#`.** A `?ref=` alone is not a pin: the tags are annotated and Zig 0.16's fetcher hands back `main` for one (`docs/history.md`, under "Claims that decay"). The commit exists only once the tag does, so either write the lines with the commit `git rev-parse vX.Y.Z^{commit}` will answer *after* tagging, or tag first and amend.

**Tagging moves the section onto that tag's release page**: `gh release create vX.Y.Z --verify-tag --notes-file …`, with every `](./` link rewritten to a blob URL pinned to the tag, because a relative link does not resolve on a release page. What stays in `CHANGELOG.md` is one line under `## Released` pointing at the page, and any README link into the section becomes a link to that page. The file is then the next release again, and never grows past one.

**Pushing the tag also publishes the guide.** `.github/workflows/docs.yml` builds `docs/guide/` into the `X.Y` copy of the site and moves `latest` only when the tag is the newest ([ADR 0296](./adr/0296-the-guide-is-published-once-a-release.md)).
