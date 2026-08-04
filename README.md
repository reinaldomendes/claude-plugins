# reinaldo-open-plugins

Open-source **Claude Code plugin marketplace**. Small, self-contained hooks and skills that
each fix one concrete gap. MIT licensed — no account, org membership, or private access
required.

Everything here is general-purpose tooling, so it is normally installed **once per machine**
in your user settings rather than per project.

## Plugins

Each plugin documents itself. Follow the link for behavior, configuration, and troubleshooting.

| Plugin | What it does | Activates | Docs |
|--------|--------------|-----------|------|
| **claudeignore-guard** | Makes `.claudeignore` actually work — Claude Code has no native support for it — and enforces your `.gitignore` alongside it by default, so a repo that already guards its secrets needs no setup. Denials name the exact rule and the `!` line that would allow it. **Context hygiene, not a security boundary:** covers `Read`/`Edit`/`Write`, not `Bash` or `Grep` — `permissions.deny` is the boundary. | automatically | [docs](plugins/claudeignore-guard/docs/README.md) |

All hooks require `bash` and `jq`, and scope their work to `$CLAUDE_PROJECT_DIR` so they
never touch an unrelated repo.

## Install

Add to your **user** settings, `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "reinaldo-open-plugins": {
      "source": { "source": "git", "url": "https://github.com/reinaldomendes/claude-plugins.git" },
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
/plugin marketplace add https://github.com/reinaldomendes/claude-plugins
/plugin install claudeignore-guard@reinaldo-open-plugins
```

## Versions

**`plugin.json`'s `version` is the release mechanism.** With `autoUpdate` on, a plugin is
re-fetched only when its version increases — so a change shipped without a bump reaches
nobody, silently. [`bin/bump.sh`](bin/bump.sh) and the `pre-push` gate exist to make that
mistake impossible; see [RELEASING.md](RELEASING.md).

Pin to a tag with `"ref"` if you'd rather review changes before they land — that's a
reasonable thing to want from a third-party marketplace, and tags are published for it.

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
