# reinaldo-open-plugins

Open-source **Claude Code plugin marketplace**. Small, self-contained hooks and skills that
each fix one concrete gap. MIT licensed — no account, org membership, or private access
required.

Everything here is general-purpose tooling that improves as it changes, so it is installed
**once per machine and tracks latest**. Nothing here should be pinned per project.

## Plugins

Each plugin documents itself. Follow the link for behavior, configuration, and troubleshooting.

| Plugin | What it does | Activates | Docs |
|--------|--------------|-----------|------|
| **claudeignore-guard** | Makes `.claudeignore` actually work — Claude Code has no native support for it, so a `.claudeignore` listing `.env` protects nothing today. Enforces it with full gitignore syntax and names the rule that blocked. | automatically | [docs](plugins/claudeignore-guard/docs/README.md) |

All hooks require `bash` and `jq`, and scope their work to `$CLAUDE_PROJECT_DIR` so they
never touch an unrelated repo.

## Install

Add to your **user** settings, `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "reinaldo-open-plugins": {
      "source": { "source": "git", "url": "https://github.com/reinaldomendes/reinaldo-open-plugins.git" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": {
    "claudeignore-guard@reinaldo-open-plugins": true
  }
}
```

Or interactively:

```text
/plugin marketplace add https://github.com/reinaldomendes/reinaldo-open-plugins
/plugin install claudeignore-guard@reinaldo-open-plugins
```

## Why nothing here is pinned

This catalog **floats**: consumers track the default branch and never set `source.ref`.
Everything in it is a quality gate or a convenience, so landing an improvement early is
pure upside and leaves no half-finished artifacts behind — there is nothing a consumer
needs to freeze mid-task.

The consequence is that **`plugin.json`'s `version` is the release mechanism**: consumers
only re-fetch a plugin when its version increases. Forgetting to bump it is a silent
non-release. See [RELEASING.md](RELEASING.md) — `bin/bump.sh` and the `pre-push` gate exist
to make that mistake impossible.

## Contributing

A plugin here should be:

- **Small and self-contained** — one gap, fixed well. `bash` + `jq`, no toolchain.
- **Safe to enable globally** — no-op quietly outside the projects it applies to, rather
  than misfiring. Scope every path check to `$CLAUDE_PROJECT_DIR`.
- **Honest about what it does not cover.** A guard whose limits are undocumented is worse
  than no guard, because it is trusted where it doesn't apply.
- **Tested** — add cases to [`test/run-tests.sh`](test/run-tests.sh); it must stay green.

Layout for a new plugin:

```text
plugins/<name>/
  .claude-plugin/plugin.json   # name, version, description
  hooks/hooks.json             # or skills/<name>/SKILL.md
  docs/README.md               # what it does, scope, config, troubleshooting
```

Then add it to [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) and the
table above.

## Development

```bash
git config core.hooksPath .githooks   # once per clone — enables the version-bump gate
bash test/run-tests.sh                # deterministic tests; must be green before pushing
bin/bump.sh <plugin> [patch|minor|major] [--commit]
```

## License

[MIT](LICENSE).
