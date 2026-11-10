# Superpowers (vendored)

Skills copied from [obra/superpowers](https://github.com/obra/superpowers) (MIT, see `LICENSE`) at commit
`22f0b463e7a5e579904dd6211a520321035526f7` (2026-11-03), read before inclusion, into `global/skills/`:

brainstorming, writing-plans, executing-plans, subagent-driven-development, dispatching-parallel-agents,
requesting-code-review, receiving-code-review, systematic-debugging, test-driven-development,
verification-before-completion, finishing-a-development-branch.

Why vendored: these skills ship scripts that agents run; copying a reviewed commit pins them (no automatic update from
upstream on every machine and cloud session). Not kept: using-superpowers, diagnosing-superpowers, writing-skills,
using-git-worktrees, and the plugin hooks.

Notes from the review:
- the brainstorming visual companion loads a remote logo: off with `SUPERPOWERS_DISABLE_TELEMETRY=1` (kit settings);
- its doc suggests `--host 0.0.0.0` for remote use: never outside a disposable container (skill `opsec`).

Update: shallow-clone the upstream at a newer release, diff the 11 folders against these, read the changes (scripts
first), copy, update the commit above, open a pull request.
