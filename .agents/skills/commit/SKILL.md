---
name: commit
description: Create clean, atomic git commits in this repo by analyzing the working tree, detecting mixed concerns, grouping files by intent, and committing each group with explicit file paths and conventional-commit messages. Use this skill whenever the user says "commit", "atomic commit", "clean commits", "break down commits", "split commits", or asks to land/save/ship pending changes — even if they don't explicitly use the word "atomic". This skill is mandatory in this repo because multiple agents work in parallel and a sloppy `git add .` can clobber another agent's in-progress edits.
---

# Atomic Commit Workflow

## Overview

This repo is worked on by multiple agents in parallel. A non-atomic commit (mixing several concerns, or staging files you didn't touch) doesn't just produce ugly history — it can silently swallow another agent's work. Every commit must do exactly one thing, list its files explicitly, and leave the tree in a working state.

## Hard safety rules

These are non-negotiable in this repo:

- **NEVER** run destructive git operations: `git reset --hard`, `git checkout <old-commit> -- <path>`, `git restore <path>` to revert another agent's work, `rm` on tracked files, force-push. If you are even slightly unsure, stop and ask the user.
- **NEVER** stage with `git add .` or `git add -A`. Always list paths explicitly so you cannot accidentally include another agent's edits or untracked junk.
- **NEVER** `--amend` a commit unless the user explicitly asks for it.
- **NEVER** skip hooks (`--no-verify`) unless the user explicitly asks.
- **ALWAYS** run `git status` and `git diff` before staging anything, so you know the full surface area of pending changes.

## Workflow

### Step 1 — Analyze

Run these in parallel and read all three:

```bash
git status
git diff
git diff --staged
```

You need to know: which files changed, what changed inside them, and what (if anything) is already staged.

### Step 2 — Detect mixed concerns

Group the modified/new files mentally by **purpose**, not by directory. A single commit should not mix:

- Multiple features
- A bug fix + a new feature
- Refactor + new functionality
- Two unrelated bug fixes
- Code changes + unrelated docs (docs that *describe the same change* are fine)
- Tests covering different features

If a single file legitimately contains two concerns, that's a signal the change should have been split earlier. Note it and ask the user how they want to proceed — don't try to split a file's diff yourself.

### Step 3 — Group files

Group files by shared purpose. Each group becomes one commit.

Example:
```
Group 1: feat(auth): add login flow
  - auth/login.ts
  - auth/session.ts
  - tests/auth/login.test.ts

Group 2: fix(validators): tighten password rules
  - validators/password.ts
  - tests/validators/password.test.ts
```

### Step 4 — Commit each group

For each group, follow this exact pattern. The repo convention is to pass paths after `--` so the commit is scoped to those files even if other things are staged.

**For tracked files only (no new files in the group):**
```bash
git commit -m "<scoped message>" -- path/to/file1 path/to/file2
```

**When the group contains new (untracked) files:**
```bash
git restore --staged :/ \
  && git add "path/to/new_file1" "path/to/new_file2" \
  && git commit -m "<scoped message>" -- path/to/file1 path/to/new_file1 path/to/new_file2
```

The `git restore --staged :/` clears the index first so you don't drag in another agent's staged edits. Then add only the new files explicitly, then commit with all paths listed after `--`.

After each commit, verify:
```bash
git log -1 --oneline
```

### Step 5 — Final check

```bash
git log --oneline -n <number-of-commits-just-made>
```

Confirm each commit is scoped, message is clear, and nothing was missed.

## Commit message format

Use conventional commits: `<type>(<scope>): <subject>`

Types: `feat | fix | refactor | docs | test | chore | perf | style`

Pick the type from what the change *is*, not what file it touches:

- `feat`: net-new capability the user can observe
- `fix`: corrects broken behavior
- `refactor`: rearranges code without changing behavior
- `docs`: documentation only (including `specs/`, `README`, comments)
- `test`: adds or fixes tests only
- `chore`: tooling, deps, config that isn't a feature/fix
- `perf`: performance-only change
- `style`: formatting, whitespace, no logic change

The scope is optional but encouraged — use the package, module, or spec area (e.g. `feat(auth):`, `docs(specs):`, `chore(deps):`).

The subject is imperative and lowercase ("add login flow", not "Added login flow").

**Example messages from this repo's history:**
- `specs: route STT back to ElevenLabs Scribe; keep Gemini for dialogue only`
- `docs: define react phaser ownership`
- `specs: forbid free-tier UI in slice 1`

Match this terse, present-tense style.

## Guidelines

**DO**
- One logical change per commit
- Include directly-related tests in the same commit as the code they cover
- Run the relevant tests/build before committing if the change is non-trivial
- Write messages that explain *why* when the *what* isn't obvious from the diff

**DON'T**
- Mix features, fixes, and refactors in one commit
- Commit code you know is broken (no "WIP" commits on `main`)
- Use vague messages ("update", "fix stuff", "wip")
- Leave debug prints, commented-out code, or stray `console.log` in the diff

## TODO checklist

Walk through this list every time:

- [ ] `git status` + `git diff` + `git diff --staged` reviewed
- [ ] Each changed file's purpose identified
- [ ] Mixed concerns flagged and grouped
- [ ] Groups defined, each with a clear conventional-commit message
- [ ] For each group: clear index → stage explicit paths → commit with paths after `--` → `git log -1 --oneline` to verify
- [ ] Final `git log --oneline -n <N>` review

## Activation

Trigger this skill whenever the user says any of:

- "commit", "atomic commit", "clean commits"
- "break down commits", "split commits"
- "save/land/ship these changes"
- Any phrasing that asks to turn pending working-tree changes into commits

Trigger it even if the user doesn't say "atomic" — in this repo, all commits are atomic by default.

## Closing

After the last commit, report back to the user with:

```
Created <N> atomic commits.
```

Followed by the `git log --oneline -n <N>` output so they can scan the result at a glance.
