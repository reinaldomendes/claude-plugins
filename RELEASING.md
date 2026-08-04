# Releasing `reinaldo-open-plugins`

How to cut releases of this plugin marketplace. **This catalog floats** — consumers track
the default branch and never pin it. Everything here is a quality gate or a convenience, so
landing one early is pure upside and leaves no half-finished artifacts; there is nothing a
consumer needs to freeze.

## Versioning model

- **Per-plugin version** — `plugins/<name>/.claude-plugin/plugin.json` → `"version"`
  (semver). This is what Claude Code compares to decide "is there a newer version of this
  plugin?" for consumers on auto-update. Resolution order: `plugin.json version` →
  `marketplace.json` entry version → git commit SHA — so **the `plugin.json` version is
  authoritative**. Bump it and auto-update carries the change to every consumer.
- **Catalog tag (optional)** — a git tag (`vX.Y.Z`) is useful for *your own*
  reproducibility and changelog, **not** as a consumer pin contract. Consumers here do not
  set `source.ref`, so a tag has no effect on what they receive.

## How consumers use it (floating)

In `~/.claude/settings.json` — **no `ref`**:

```json
"extraKnownMarketplaces": {
  "reinaldo-open-plugins": {
    "source": { "source": "git", "url": "https://github.com/reinaldomendes/reinaldo-open-plugins.git" },
    "autoUpdate": true
  }
}
```

With `ref` omitted it tracks the default branch and `autoUpdate` follows it — updates land
next session after a short randomized delay.

## Version-bump tooling

Because the catalog floats, **forgetting to bump a changed plugin's version means no
consumer ever re-fetches it** — a silent non-release. Two pieces guard against that:

- **`bin/bump.sh <plugin> [patch|minor|major] [--commit]`** — bumps the version in that
  plugin's `plugin.json` (default `patch`). Pure bash + `jq`, no npm toolchain. With
  `--commit` it makes an isolated commit of just that manifest —
  `chore(<plugin>): bump to <version>`. Use `--all` instead of a plugin name to bump every
  plugin at once.
- **`.githooks/pre-push`** — a **reject-gate**: on a push to the default branch it refuses
  if a plugin whose content changed (excluding its `docs/`) hasn't had its version
  increased vs. the remote, naming the plugin and the `bin/bump.sh` command to run. It
  never edits or commits — it only rejects. Bypass with `git push --no-verify`.

**One-time install per clone** (git hooks aren't committed; this points git at the tracked
hooks dir):

```bash
git config core.hooksPath .githooks
```

## Release steps

1. **Make the change** to the plugin(s) under `plugins/<name>/`.
2. **Bump the version** of each changed plugin — `bin/bump.sh <plugin> [level]`:
   - patch (`1.0.1`) — fix, no behavior change for users
   - minor (`1.1.0`) — new capability, backward compatible
   - major (`2.0.0`) — breaking change (hook behavior, removed option, renamed plugin)
3. **Run the test suite** and make sure it's green:
   ```bash
   bash test/run-tests.sh
   ```
4. **Commit and push** to the default branch:
   ```bash
   git add -A
   git commit -m "feat(<plugin>): <summary>"
   git push
   ```
   The pre-push gate passes because the version was bumped; floating consumers pick it up
   automatically on their next session. (Forget the bump and the gate stops you.)
5. **Tag (optional)** — only if you want a named checkpoint:
   ```bash
   git tag -a vX.Y.Z -m "reinaldo-open-plugins vX.Y.Z" && git push --follow-tags
   ```

## Conventions

- The **`plugin.json` version is the release unit**; bump it for every user-visible change.
  A catalog tag is a convenience, not a requirement.
- Each plugin keeps its **own** semver; versions need not match each other or any tag.
- Don't move a **published** tag — cut a new one. (Unpushed tags are yours to move.)
- **A plugin below `1.0.0`** is signalling that its behavior may still change without a
  major bump. Promote it to `1.0.0` once you're prepared to treat changes as breaking.

## Quick checklist

- [ ] `git config core.hooksPath .githooks` set once in this clone
- [ ] Plugin change made under `plugins/<name>/`
- [ ] Version bumped — `bin/bump.sh <plugin> [patch|minor|major]`
- [ ] `bash test/run-tests.sh` green
- [ ] Docs updated — a plugin's `docs/README.md` states its **scope and its limits**
- [ ] Committed and pushed to the default branch (pre-push gate passes)
- [ ] (optional) named checkpoint tag `vX.Y.Z` pushed
