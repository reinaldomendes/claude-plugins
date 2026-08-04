# claudeignore-guard — gotchas

Things that cost real time to establish, or that will mislead you if you assume the obvious.
Each entry is a **measured** finding with the conditions it was measured under, not a
restatement of documentation. Where documentation and measurement disagree, both are here.

For proposed work see [PROPOSALS.md](./PROPOSALS.md); for behaviour see [README.md](./README.md).

---

## 1. `permissions.deny` does not stop `cat` or `grep` in Bash

**Measured on Claude Code 2.1.220**, one session, throwaway directory,
`{"permissions":{"deny":["Read(.env)"]}}` in `.claude/settings.local.json`:

| attempt | result |
|---|---|
| `Read` the file | **denied by the harness** — proving the rule was active |
| `cat .env` | **permitted**, printed `SECRET=canary-9f2a` |
| `grep -rn canary-9f2a .` | **permitted**, returned `./.env:1:SECRET=canary-9f2a` |
| `python3 -c "print(open('.env').read())"` | permitted — this one *is* documented as uncovered |

The [permissions docs](https://code.claude.com/docs/en/permissions) say otherwise: *"Read and
Edit deny rules apply to Claude's built-in file tools and to file commands Claude Code
recognizes in Bash, such as `cat`, `head`, `tail`, and `sed`."* On 2.1.220 that did not hold.
The version is past every gate the docs mention (2.1.208, 2.1.210), so version does not
explain it.

**Consequence.** A deny rule reliably stops the *file tools*, which is where accidental reads
happen and is real value. Do not assume it stops a shell command. For paths where a `cat` must
also fail, the [sandbox](https://code.claude.com/docs/en/sandboxing) is the only mechanism here
that constrains processes rather than tools.

**Still untested:** the `Grep` **tool**. Both shell rows above ran through `Bash`. The docs'
claim that `Read` rules apply best-effort to `Grep` and `Glob` is unmeasured in either
direction — do not quote it as settled, in either direction.

---

## 1b. Deny-rule negation is undocumented — and I asserted both answers

Read/Edit rules are documented as using gitignore **pattern** syntax. The docs say nothing
about the `!` **negation** mechanic; searching the permissions page for it returns nothing.

Worth recording because this repo's own docs stated it both ways within a few commits: first
"gitignore negations have no equivalent in deny rules" (asserted, unevidenced), then "they do —
deny rules use gitignore syntax" (conflating *pattern* syntax with the negation mechanic, also
unevidenced). Both were confident; neither was measured.

**The open question**, if anyone needs it: does `"deny": ["Read(.env*)"]` with
`"allow": ["Read(.env.example)"]` let the example file through, or does deny win? That
precedence — not `!` parsing — is what decides whether a `.claudeignore` with re-includes can
be expressed as permission rules at all. Test with a canary, per gotcha 2.

---

## 2. A results table cannot tell "the model declined" from "the platform blocked it"

The first attempt at gotcha 1 produced a table reading *Denied, Denied, Allowed, Denied* —
which looked like clean confirmation of the docs. It was worthless. The **why** column showed
that three of the four rows said *"I declined"*: the assistant refused on its own judgement and
the harness was never asked. One row even reported "Denied" for the `python3` case, which the
docs say is **permitted** — the model was more conservative than the platform, and that
inversion is invisible in the outcome column alone.

**When testing a boundary, instruct the session to attempt the command and report what the
harness did**, state that the target is a throwaway canary rather than a real secret, and ask
for the exact command run. Otherwise you measure the assistant's caution.

The same run also lacked a same-session control: the second attempt showed `cat` permitted but
never re-checked that `Read` was still denied, leaving "the rule wasn't active" open. It took
three attempts to measure this correctly, and the first two were misleading in *opposite*
directions.

---

## 3. Blocking a secret from Claude is not the same as blocking it from your tools

`cat .env` surfaces contents into context. `pnpm dev`, `docker compose up` and `python app.py`
also read `.env` — and must keep working.

This is why the sandbox is the wrong instrument for a repo whose dev server needs its `.env`:
it stops the *process* touching the path, so the app fails to start. Any future Bash guard in
this plugin should therefore key on **content-surfacing commands** (`cat`, `head`, `strings`,
`base64`, `grep`, …) rather than on paths alone — that distinction is what lets a secret stay
usable while staying unread. Recorded here because it is the design constraint that will decide
whether such a guard is tolerable or infuriating.

---

## 3b. "Re-include the directory" is only half the rule

Stated in this repo's docs for several versions as *"re-include the outermost excluded
directory"*. That is right only when a rule excluded the **directory**. When it excluded the
**contents**, the directory was never excluded and re-including it does nothing:

| blocking rule | excluded | working negation |
|---|---|---|
| `dir`, `/dir` | the directory | `!dir/` |
| `dir/*` | the contents | `!dir/file` |

Found on a real `.gitignore` carrying `.vscode/*`: `!.vscode/` left `launch.json` denied,
`!.vscode/launch.json` freed it, and `.vscode/tasks.json` stayed denied — surgical, as it
should be.

The **hook was already correct** — its escape hint branches on the winning rule's shape and
produced a working line in all three cases (`/dir`, `dir/*`, bare filename), verified. Only the
prose was wrong. Worth recording because the code being right is exactly why nobody noticed the
documentation was not.

---

## 4. `git check-ignore -v` exits 0 for a negation

`-q` means "this path is excluded". `-v` means "some rule matched", **including a `!` rule**.
Taking the verdict from `-v` makes `!.env.example` read as *ignored*. This caused a real bug
here; the verdict now comes from `-q`, and `-v` runs afterwards only to recover which rule
matched.

---

## 5. `grep -c` prints `0` and exits `1`

So `n=$(grep -c … || echo 0)` yields `"0\n0"` and any arithmetic on it fails. This crashed the
`SessionStart` notice for every project whose `.git/info/exclude` held only comments — and the
notice's test passed anyway, because it asserted *silence* and a crash is silent. **Assert
stderr is clean, not merely that output is absent.**

---

## 6. `jq -e` exits 0 on empty input

`echo "" | jq -e '.foo'` succeeds. Any test shaped `[ -n "$out" ]`-less, like
`echo "$o" | jq -e '.x' && ok "…"`, passes when the hook emitted **nothing** — which is usually
the exact failure being tested for. Guard with `[ -n "$o" ] &&` first. This produced two false
passes in this repo's own suite, one of them hiding a genuinely broken `DISABLED` flag.

---

## 7. Unquoted expansions in pattern positions silently disable enforcement

`${target#$root/}` treats `$root` as a **pattern**, not a literal. A project directory named
`weird[1]*dir` therefore strips the wrong prefix, the path stops looking like it is inside the
project, and every rule stops applying — silently, for that whole project. Quote inside the
expansion: `${target#"$root"/}`. Filed originally as a cosmetic nit; it was a total loss of
enforcement.

---

## 8. Anything in `initialUserMessage` reads as the user speaking

It is prepended to the user's turn, so a hook notice arrives where instructions arrive. A
one-line `[notice … not typed by the user]` prefix was **not** enough: Claude attributed the
text to the user on the very next turn. The framing has to be structural — a named XML-style
tag, as Claude Code uses for its own injected context — plus an explicit "no request is being
made" inside it.

Related: `systemMessage` renders in the terminal CLI **only**; the VS Code / Cursor extension
displays nothing. `initialUserMessage` renders on both.

---

## 9. The mirror inherits your global `core.excludesFile` — nobody chose that

The mirror is a git repository, so `git check-ignore` reads the user's global excludes file
(`~/.config/git/ignore`) inside it exactly as in any other repo. It arrived free with
borrowing git's engine and went unnoticed through nine releases, while this plugin's own
design notes stated the opposite: *"Global `core.excludesFile` is **not** read."* The code
had been reading it the whole time.

Measured with a fixture injecting a global ignore via `XDG_CONFIG_HOME`, a project whose
`.claudeignore` held only `/mine.txt`, and a `global-only.txt` covered by neither:

| mode | `mine.txt` | `global-only.txt` |
|---|---|---|
| merge (default) | denied | **denied** — by a file the project never mentions |
| isolated (`CLAUDEIGNORE_NO_GITIGNORE=1`) | denied | **denied** — the opt-out did not opt out |

Merge mode's row is defensible and now documented: merge means *enforce what git ignores*.
The isolated row was a real bug — the flag promises `.claudeignore` alone. Fixed in 0.5.13
by querying with `-c core.excludesFile=/dev/null` when merge is off.

**Two lessons worth more than the fix.** A wrapper inherits its engine's ambient
configuration whether or not you decided anything, so *"we don't read X"* is a claim about
code you wrote, never about behaviour you get. And the whole test suite passed throughout:
every case ran in an environment where no global ignore existed, so the contamination had
nothing to contaminate. This was found by a user's real `git check-ignore -v` output naming
`/home/…/.config/git/ignore`, not by the suite.
