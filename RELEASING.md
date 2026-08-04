# Releasing `reinaldo-open-plugins`

How to cut releases of this plugin marketplace.

## Versioning model

- **Per-plugin version** — `plugins/<name>/.claude-plugin/plugin.json` → `"version"`
  (semver). This is what Claude Code compares to decide "is there a newer version of this
  plugin?" on auto-update. Resolution order: `plugin.json version` → `marketplace.json`
  entry version → git commit SHA, so **the `plugin.json` version is authoritative**. Bump it
  and auto-update carries the change to everyone tracking the branch.
- **Tags (`vX.Y.Z`)** — publish them. This catalog is public, and a consumer who pins
  `"ref"` to review changes before they land is doing a sensible thing, not a wrong one.
  Tags are also the changelog anchor for your own reproducibility.

## How consumers install it

Tracking the branch, with auto-update:

```json
"extraKnownMarketplaces": {
  "reinaldo-open-plugins": {
    "source": { "source": "git", "url": "https://github.com/reinaldomendes/claude-plugins.git" },
    "autoUpdate": true
  }
}
```

Updates land next session after a short randomized delay. Add `"ref": "v1.2.3"` inside
`source` to freeze on a tag instead — updates then arrive only when the ref is moved.

## Version-bump tooling

**Forgetting to bump a changed plugin's version means nobody ever re-fetches it** — a
silent non-release. Two pieces guard against that:

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
   The pre-push gate passes because the version was bumped; consumers tracking the branch
   pick it up on their next session. (Forget the bump and the gate stops you.)
5. **Tag the release** — consumers who pin depend on these existing:
   ```bash
   git tag -a vX.Y.Z -m "reinaldo-open-plugins vX.Y.Z" && git push --follow-tags
   ```

## Conventions

- The **`plugin.json` version is the release unit**; bump it for every user-visible change.
  A tag marks the same point for anyone pinning to it.
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
- [ ] tag `vX.Y.Z` pushed (what pinned consumers resolve against)
