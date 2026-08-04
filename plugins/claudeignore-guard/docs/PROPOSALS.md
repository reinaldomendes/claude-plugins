# claudeignore-guard — proposals

> Review findings and a proposed order of work. **Items 1 and 2 are implemented (0.5.0);
> items 3-7 are not.** This file
> records the *problem* behind each item, so that a proposal can be rejected on its merits
> later instead of being re-derived from scratch.

The plugin's core design is not in question. Borrowing git's matcher through a mirror,
applying `.claudeignore` last, and taking the verdict from `check-ignore -q` are the right
calls, and the existing [README](./README.md) already documents what the guard does *not*
cover — the discipline this plugin exists to correct. Everything below is either a hole in
what it claims to cover, or a way to make the honest caveat actionable.

| # | Item | Kind | Why it ranks here |
|---|------|------|-------------------|
| ~~1~~ | ~~Resolve symlinks before matching~~ | **done 0.5.0** | Fixed; 8 cases in the suite, incl. dir links, broken links and out-of-project links. |
| ~~2~~ | ~~Unbuildable mirror must not fail open~~ | **done 0.5.0** | `_ci_ensure` now returns a third outcome; warn-and-allow, or deny under `CLAUDEIGNORE_STRICT=1`. |
| 3 | Generate `permissions.deny` from `.claudeignore` | feature | Turns the Bash/Grep caveat from a warning into a next step. |
| 4 | Scope caveat above the fold | docs | The reader most likely to over-trust the plugin never reaches §Scope. |
| 5 | Mirror hygiene and identity | hardening | The mirror is the plugin's only trust boundary and its only opaque artifact. |
| 6 | Spike `Grep` redaction via `PostToolUse` | spike | "Impossible" may be overstated; worth knowing before docs commit to it. |
| 7 | Quote expansions used as patterns | nit | A project path containing `[` or `*` misbehaves. |

---

## 1. Resolve symlinks before matching

**Problem.** `Read` follows symlinks; the hook matches path strings. So a link whose target
is excluded is read straight through. In a project whose `.claudeignore` contains `.env`:

```bash
ln -s .env link.txt
```

`Read .env` is denied. `Read link.txt` returns the file's contents. Reproduced by hand
against the current hook with the guard fully enabled.

**Why it matters.** This is not only an adversarial path. Repositories symlink config files
routinely — a checked-in `config/local.env → ../.env`, a `current → releases/…` deploy
layout, a dotfile linked out of a shared directory. In every one of those the user has
written the rule they were told to write, the denial never fires, and the failure looks
exactly like success. That is precisely the failure mode named in the README's own
statement of the problem, reproduced inside the fix for it.

`..` was probed alongside this and is handled: `Read .claude/../.env` is correctly denied.

**Proposal.** After `ABS` is built in `claudeignore-guard.sh`, also evaluate the resolved
path, and block when *either* matches:

```bash
RES=$(readlink -f "$ABS" 2>/dev/null) || RES=""
WHY=$(ci_is_ignored "$ABS" "$ROOT" "$SESSION_ID") \
  || { [ -n "$RES" ] && [ "$RES" != "$ABS" ] && WHY=$(ci_is_ignored "$RES" "$ROOT" "$SESSION_ID"); } \
  || exit 0
```

**Why this way.** Matching the literal path *first* keeps every current denial message
byte-identical — the rule quoted back to the user stays the one they can see in the file
they edit. The resolved path is a second chance to deny, never a first chance to allow.

The asymmetry with `ci_is_ignored`'s existing project scoping is deliberate and worth
stating out loud: a link *pointing into* an excluded file is blocked, while a link pointing
*out of* the project stays unjudged, because `case "$target" in "$root"/*)` declines paths
outside the root. Widening that would mean deciding whose ignore rules govern a file in
another repository — a larger question than this fix, and the conservative answer keeps the
existing `$CLAUDE_PROJECT_DIR` contract intact.

**Cost.** One `readlink` fork, and only on the path where the literal match already missed.
The common case — an allowed file — pays it once; the mtime freshness pass remains untouched.
`readlink -f` on a non-existent path prints nothing and fails, which is the correct answer
for a `Write` to a new file.

**Tests.** Link to an excluded file → denied. Link to an allowed file → allowed. Link
pointing outside the project → allowed, unchanged. Broken link → allowed, no error output.
A directory symlink whose target is excluded → denied.

---

## 2. An unbuildable mirror must not fail open

**Problem.** `_ci_ensure` returns non-zero for two situations that mean opposite things:

- there are no rules to enforce — correct, silent, and the documented no-op; and
- the mirror could not be created or written — read-only or full `$TMPDIR`, a restrictive
  `umask`, a pre-existing directory owned by another user, `git init` failing.

The hook treats both as "allow". `_ci_merge_dir` already returns `1` on a failed write, but
`_ci_scan` discards that status, so an empty merged file simply leaves `_CI_ACTIVE` at `1`
and enforcement evaporates. Nothing is printed. The session behaves exactly like a project
with no ignore files.

**Why it matters.** Silent loss of enforcement is the one failure this plugin cannot
afford, because its entire value is that a user who wrote a rule can trust the rule. Every
*other* gap is disclosed in the README and can be reasoned about; this one is invisible and
environment-dependent, so it will surface as "it worked on my laptop and not in the
container" long after the user stopped thinking about it.

**Proposal.** Give `_ci_ensure` a third outcome — `0` enforce, `1` nothing to enforce,
`2` could not build — by having `_ci_scan`/`_ci_sync_dir` propagate write failures. On `2`,
report rather than shrug. Two defensible policies:

- **warn and allow** — emit `additionalContext` (per the hook contract, stderr is only shown
  on a non-zero exit) plus a `SessionStart` line, and continue; or
- **fail closed** — deny with an explanation, behind `CLAUDEIGNORE_STRICT=1`.

Recommended: warn-and-allow as the default, `CLAUDEIGNORE_STRICT=1` for anyone who would
rather lose the tool than lose the guarantee. That ordering respects the catalog rule that a
hook blocking work it shouldn't is worse than one that does nothing, while making sure the
user *knows* the difference.

**Why not just fail closed by default.** A broken `$TMPDIR` would then deny every `Read` in
the project, including files no rule mentions. The failure would be loud, which is the goal,
but the blast radius is the whole session — an unacceptable default for a hygiene tool, and
exactly the "blocks work it shouldn't" case the catalog rules call out.

**Tests.** Point `TMPDIR` at a read-only directory and assert a warning is produced and the
verdict is explicit; with `CLAUDEIGNORE_STRICT=1`, assert a deny. Assert the genuine
no-rules case stays silent — it must not regress into warning on every clean project.

---

## 3. Generate `permissions.deny` from `.claudeignore`

**Problem.** The README correctly says the real boundary is `permissions.deny`, then leaves
the user to hand-write it. They won't. Translating gitignore patterns into permission rules
by hand, for every project, is exactly the kind of clerical work that does not get done —
so the honest caveat currently converts into no protection at all.

**Why it matters.** `Bash` and `Grep` are not oversights, they are structural: blocking
`cat .env` needs command parsing, and a guard that scans command strings for filenames also
blocks `echo "see .env for details"`. That reasoning is sound and should not change. But the
harness *already* enforces a boundary at every entry point — the user just has to declare
it. Generating that declaration is the cheapest way to close the plugin's biggest real gap
without weakening its design.

**Proposal.** A slash command — `/claudeignore-deny` — that reads the project's ignore files
and prints the corresponding `permissions.deny` block, with an opt-in flag to merge it into
`.claude/settings.json`.

Scope it honestly:

- translate literal paths and simple globs;
- **skip negations and anything whose gitignore semantics don't survive translation**, and
  say so in the output, naming each rule skipped;
- never silently emit an approximation. A deny list that looks complete and isn't is the
  same class of lie this plugin was built to correct.

**Why a command and not automatic.** Writing to `settings.json` unprompted mutates the
user's configuration and could deny paths they still need; the deny list is also the kind of
thing that belongs in review and version control. Printing by default and merging on request
keeps the decision where it belongs.

---

## 4. Move the scope caveat above the fold

**Problem.** §Scope is thorough and sits well below the tagline. The reader arriving from a
blog post that presents `.claudeignore` as native — the plugin's most likely installer, and
the one most primed to over-trust it — reads "makes `.claudeignore` actually work" and stops.

**Proposal.** One line directly under the tagline: covers `Read`/`Edit`/`Write`;
`Bash` and `Grep` are not covered — see [Scope](./README.md#scope--read-this-before-trusting-it).

**Why.** The catalog rule is to document what a guard does not cover. That is satisfied in
letter already; placement is what decides whether it is satisfied in effect.

---

## 5. Mirror hygiene and identity

**Problems**, in rising order of consequence:

- **Not debuggable.** The mirror is keyed by a checksum, so nothing in
  `$TMPDIR/claudeignore-guard/` reveals which project an entry belongs to. The README's own
  troubleshooting step is "delete the whole directory", because inspecting it is impractical.
- **Never collected.** Two mirrors per project, plus orphans for every project renamed or
  deleted. Growth is monotonic. Nothing breaks; it merely accumulates forever.
- **Weak key.** `cksum` is a 32-bit checksum. A collision between two project paths means
  one project's rules are enforced against the other — rare, but silently wrong, and the
  cost of avoiding it is one command substitution at session start.
- **Predictable shared path.** On a multi-user host the mirror path is guessable and lives
  in a world-writable directory. Whoever creates it first controls which rules exist, and
  per item 2 a mirror that cannot be written currently fails *open*.

**Proposal.** `mkdir -m 700`; refuse a mirror whose owner is not the current user; write a
`.ci-root` file containing the project path; key on a stronger hash. Optionally prune
mirrors whose `.ci-root` no longer exists on disk.

**Why grouped and ranked below the bugs.** None of these produce a wrong verdict today on a
single-user machine. They matter because the mirror is the plugin's only piece of hidden
state and its only trust boundary — and because item 2's fix is what makes the last of them
stop being exploitable.

**Note on mode switching.** Baking the mode into the mirror name is correct and prevents a
real bug: flipping `CLAUDEIGNORE_NO_GITIGNORE` changes no source mtime, so a shared mirror
would keep enforcing rules the user just dropped. The tradeoff is that each flip lands on a
mirror with no `.ci-dirs` and pays the full discovery scan again. Worth documenting where the
per-call cost is measured, so the number isn't read as a regression.

---

## 6. Spike: `Grep` redaction via `PostToolUse`

**Problem.** The README says `Grep`/`Glob` cannot be covered because they take a directory
and a pattern rather than a file path. True at `PreToolUse` — but `PostToolUse` sees the
*output*, and that output carries file paths.

**Proposal.** Timeboxed experiment, not a commitment: a `PostToolUse` hook on `Grep` that
drops result lines belonging to excluded files and appends a count of what was withheld.

**Why it's worth an hour.** The leak the article's readers care about is filename-keyed —
grepping for a token name and getting the line from `.env`. If that specific case closes,
the plugin's headline claim gets materially more true. If the output shape turns out to be
unreliable across `Grep`'s modes, the finding is still useful: the README can then say
*tried, and here is why not* instead of *not possible*, which is a stronger claim.

**Why it stays a spike.** Redaction that works in `files_with_matches` mode and fails in
`content` mode would be worse than no redaction, because partial invisible coverage is
untrustworthy coverage. The experiment decides whether item 6 becomes a feature or a
documented dead end.

---

## 7. Quote expansions used as patterns

**Problem.** `${ABS#$ROOT/}` and `case "$target" in "$root"/*)` place an unquoted expansion
where bash performs pattern matching, so a project path containing `[`, `*` or `?`
mis-strips the prefix or mis-scopes the check.

**Why it's last.** Rare in practice and cosmetic in effect — but it sits in the two lines
that decide *is this path in the project* and *what do we call it*, which is a poor place
for an edge case to hide.

---

## Sequence

1. Items **1 + 2** as one correctness change, with tests. They interact: fixing 2 removes
   the fail-open that makes 5's shared-path concern reachable.
2. Item **4** alongside them — one line, same theme.
3. Item **3** as its own change; it is a new surface, not a fix.
4. Items **5** and **7** as hardening.
5. Item **6** last, as a spike that either becomes work or becomes a sentence in the README.

`bash test/run-tests.sh` green before any push, and each plugin change bumps
`plugin.json` — the version *is* the release.

## Explicitly not proposed

- **Parsing `Bash` commands for filenames.** The existing reasoning holds: false positives
  on every shell command cost more than the gap, and item 3 addresses the same exposure
  through the boundary the harness actually enforces.
- **Re-implementing gitignore matching** to avoid the mirror. The mirror exists because
  `check-ignore` cannot be told which ignore files count. Owning a bash reimplementation of
  gitignore semantics forever is a worse trade than one temporary directory.
- **Blocking paths outside `$CLAUDE_PROJECT_DIR`.** See item 1 — it would require deciding
  whose rules govern another repository's files.
