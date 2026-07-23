# auto-code

Bash script suite that turns GitHub issues into pull requests using Claude Code.

For each issue it: clones the repo locally (if missing), creates a branch, plans, codes,
reviews its own code up to N times (fixing between reviews), pushes, and opens a PR.
You review and merge the PR manually — that is the human control point.

## Requirements

- `git`
- [`gh`](https://cli.github.com/) authenticated (`gh auth status` should be green)
- [`claude`](https://docs.claude.com/en/docs/claude-code) authenticated
- `jq`, `envsubst` (part of gettext)
- Bash ≥ 4 or zsh

## Install

```bash
cd /path/to/automatedcodingscripts
./install.sh
```

This symlinks `~/.local/bin/auto-code → auto-code.sh` and prepares
`~/.config/autocoding/`. Add `~/.local/bin` to your `PATH` if it isn't already.

Edit defaults in `~/.config/autocoding/config.env` if you want.

## Usage

```bash
auto-code <owner/repo> [options]
```

### Issue selection (mutually exclusive, default `--oldest`)

| Flag | Effect |
| --- | --- |
| `--oldest` | Oldest open issue |
| `--issue N` | Specific issue |
| `--issues N,M,...` | Multiple specific issues, sequentially |
| `--n-oldest N` | N oldest issues, sequentially |
| `--all` | All open issues, sequentially |

### Behavior

| Flag | Default | Effect |
| --- | --- | --- |
| `--max-reviews N` | 3 | Max review→fix loops before opening the PR anyway |
| `--base-branch NAME` | `main` | PR target |
| `--repos-dir PATH` | `~/Projekte` | Where repos are cloned |
| `--watch` | off | After a cycle, sleep and repeat |
| `--interval DUR` | `15m` | Watch interval (`30s`, `5m`, `1h`) |
| `--retry` | off | Reprocess issue even if state says done/errored |
| `--dry-run` | off | Render prompts and stop before the first Claude call |
| `--verbose` | off | Stream Claude session output live |

### Examples

```bash
# One shot: oldest open issue in owner/repo
auto-code myuser/myrepo

# Watch mode: every 10 min, take up to the 3 oldest new issues per pass
auto-code myuser/myrepo --n-oldest 3 --watch --interval 10m

# Fix issue #42 with only 2 review passes and live output
auto-code myuser/myrepo --issue 42 --max-reviews 2 --verbose

# Dry run to inspect prompts before spending API credits
auto-code myuser/myrepo --issue 42 --dry-run --verbose
```

## Layout

### In this repo (the tooling)

```
auto-code.sh         # Entry-point + arg parsing + watch loop
lib/
  config.sh          # Defaults + $HOME/.config/autocoding/config.env overrides
  logging.sh         # Colored, timestamped logs (stderr + file)
  github.sh          # gh wrappers: issue list/get, clone, PR create
  state.sh           # JSON state per repo (~/.config/autocoding/state/)
  claude.sh          # claude_run() — headless invocation with retry/backoff
  context.sh         # ensure_claude_md, update_claude_md
  workflow.sh        # process_issue: plan → code → review×N → PR
prompts/             # envsubst templates (edit to tune tone/rigor)
```

### On your machine (created by auto-code)

```
~/.config/autocoding/
  config.env         # Your defaults
  state/*.json       # Per-repo processed/errors record
  logs/<repo>/       # Per-issue rendered prompts, session JSONs, log files

~/Projekte/<repo>/   # Auto-cloned target repos
```

### Inside each target repo (auto-generated, committed)

```
CLAUDE.md                              # Project context, generated on first run
.claude/context/
  issue-N-plan.md                      # Plan from the plan session
  issue-N-review-<i>.md                # Reviews from each review pass
  issue-N-summary.md                   # PR body source
```

## How a cycle works

1. **Preflight** — fetch issue, check state
2. **Repo sync** — clone if missing, else `git fetch && git checkout $BASE_BRANCH && git pull --ff-only`
3. **Context** — if `CLAUDE.md` is missing, run the project-init session and push it to `$BASE_BRANCH`
4. **Branch** — `git checkout -b auto/issue-<N>-<slug>`
5. **Plan** — Claude writes `.claude/context/issue-N-plan.md` (no code)
6. **Code** — Claude implements; wrapper commits `Implement issue #N: <title>`
7. **Review loop** — up to `--max-reviews` iterations of review + fix + commit
8. **PR body** — assembled from plan + review MDs, saved as `issue-N-summary.md`
9. **Push + PR** — `git push -u`, then `gh pr create`
10. **Post-PR context update** — Claude decides if `CLAUDE.md` needs additions; if yes, a separate commit lands on `$BASE_BRANCH`

Errors during any Claude session retry 3× with 5s/15s/45s backoff. Persistent failures
mark the issue as errored in state and skip further Claude calls. No half-finished PR is opened.

## Config file

Copy [`examples/config.env.example`](examples/config.env.example) to
`~/.config/autocoding/config.env` and adjust. Every value is optional.

## Tips & Troubleshooting

- **Dirty working tree in a target repo** — `auto-code` refuses to touch it. Commit or stash first.
- **Reset an issue's state** — delete or edit `~/.config/autocoding/state/<owner>__<repo>.json`, or pass `--retry`.
- **Iterating on prompts** — edit files under `prompts/`; changes take effect on the next run.
- **Watching what Claude does** — `--verbose` streams tokens; alternatively `tail -f ~/.config/autocoding/logs/<repo>/issue-*.log`.
- **Cost control** — set `CLAUDE_MAX_BUDGET_USD=2.00` in your config; each Claude call gets `--max-budget-usd` accordingly.
- **Multiple issues → PR conflicts** — when running with `--all` or `--n-oldest`, all PRs branch off `$BASE_BRANCH`. If they touch the same files, resolve conflicts in the merge order you prefer.

## Known limitations (v1)

- Sequential only — no parallel issues
- Not integrated with Notion/other trackers
- No PR-comment feedback loop (bot doesn't react to human review comments)
- Assumes `$BASE_BRANCH` already exists on the remote and has at least an initial commit
