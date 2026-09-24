# An ADR is the rule in force, and a topic page is what joins them

**Status:** accepted
**Topic:** [docs-tooling](../design/docs-tooling.md)
**Applies:** [ADR 068](./068-the-guide-is-the-source-of-its-own-snippets.md) (a rule held by a build step, not a paragraph)

## Context

By September 2026 `docs/adr/` held 297 files, and about a third of them were amends: an ADR that narrowed, widened, corrected or reversed an earlier one. Reading one decision meant reading its chain, and the rule actually in force was whatever the last link said, in whichever file that was. A citation in code named the first link, so a reader followed it to a position that had since moved. Two ADRs that were one design (the layering and what a layer may import, the migration process and the marker it reads) were cited apart, and nothing said where the topic as a whole was written down.

Two things were wrong, and they want different fixes. A chain of amends is one decision spread over several files; that is fixed by merging. Decisions that are separate but belong together are a different problem; that is fixed by a page that joins them, not by merging decisions that are genuinely separate.

## Decision

**An ADR says the rule in force.** A change to a decision edits that ADR in place: the Decision section is rewritten to what holds now, and the position it replaced moves under "What was rejected", with the evidence that moved it. A new number is for a new decision, not for a new version of an old one. A new decision that changes part of an older one edits the older one too, so each says the rule in force, and its head names the older one with `**Extends:**`. The head of an ADR names others only with `Applies`, `Extends`, `Carries out`, `Closes` and `Found by`; `Amends`, `Supersedes`, `Refines` and the rest are refused, because each is a revision written as a new file.

**The amend chains were merged once, and the survivors renumbered.** 297 ADRs became 220, numbered 001 to 220 in their old order, in three digits so that an old number and a new one can never be read as the same. Every citation in the repository was re-pointed to the survivor that now holds it. `docs/adr/renumbered.md` is the table from old to new, kept so that a commit message or a released changelog entry written before the renumbering can still be read; nothing cites it.

**The numbers are not compacted again.** An ADR that stops being true is deleted, its citations re-pointed to whatever replaced it, and its number stays a gap. A renumbering rewrites every file that cites an ADR, and doing it once was the price of starting clean, not a habit.

**Every ADR names its topic**, as a `**Topic:**` line under its title. A topic that has a page in `docs/design/` is written as a link to it. The page is the rule as a whole: how the pieces fit, each rule in force with the ADR that decided it, the ADRs beside the topic, and what is open. The ADRs stay the record of why; the page is where a reader starts. Pages are written one topic at a time; `docs/design/sql-migrations.md` is the first.

**`zig build adr-check` holds all of it, and `test` depends on it.** It refuses a file in `docs/adr/` not named `NNN-slug.md`, two ADRs with one number, a title with a number in it, a missing `**Status:**` or `**Topic:**` line, a topic written as a plain slug when its page exists, a page that does not link every ADR whose topic it is, a page's relative link to a file that is not there, and a head line that names another ADR with a word outside that list. Across every text file in the repository it refuses a four-digit ADR number anywhere but `renumbered.md`, a three-digit one with no file behind it (lists like `ADRs 052, 061 and 123` and ones broken across a comment's lines included), and a link to an ADR file that does not exist.

## What was rejected

**Keeping the old numbers and adding topic pages over them.** The pages would have joined the ADRs, but every citation would still land on the first link of a chain, and a reader would still have to know which later ADR had overruled it. The redundancy was the problem, and a page over it is one more copy.

**Keeping old numbers alive as aliases**, a merged ADR's file left as a stub pointing at its survivor. Two numbers for one decision is the thing the renumbering was for removing, and a stub is a file somebody edits by mistake.

**Merging by topic rather than by chain**, one ADR a topic. A topic holds several decisions, each with its own rejected alternative; one file for all of them loses which alternative lost to which rule. That is the page's job, and the page links the decisions rather than replacing them.

**Four digits, renumbered from 0001.** A citation of 41 written before the renumbering and one written after would mean different things, and nothing could tell a stale citation from a current one. Three digits make an old number recognisable by its length, which is what lets the check refuse it.

**A paragraph in CLAUDE.md instead of a build step.** The renumbering itself missed links without a `./`, numeric link texts and lists wrapped across comment lines, each found only by a scan. A rule nobody runs does not catch the next one.

## What it costs

Nothing a user builds: `adr-check` is a build step over the repository's text and adds nothing to any artifact. It reads every text file outside the dot, `zig-out`, `zig-pkg` and `node_modules` directories, about 1.5 seconds on the author's machine, and it does not cache, so it is paid on every `zig build test`.
