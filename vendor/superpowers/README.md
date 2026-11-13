# Superpowers (vendored)

Two skills copied from [obra/superpowers](https://github.com/obra/superpowers) (MIT, see `LICENSE`) at commit
`22f0b463e7a5e579904dd6211a520321035526f7` (2026-11-03), read before inclusion, then patched for the kit, into
`global/skills/`: **brainstorming** (vague ideas only) and **writing-plans** (writes `docs/plan.md`).
Every change from upstream is in `PATCHES.md`.

The nine other skills (executing-plans, subagent-driven-development, dispatching-parallel-agents,
requesting-code-review, receiving-code-review, systematic-debugging, test-driven-development,
verification-before-completion, finishing-a-development-branch) were removed in lot 2f of the v2 plan: they stay in
the `legacy/v1` branch and upstream. The Superpowers plugin is not installed (`PLUGINS.md`).

Why vendored: these skills ship scripts that agents run (the brainstorming visual companion); copying a reviewed commit
pins them (no automatic update from upstream on every machine and cloud session). Not kept: using-superpowers,
diagnosing-superpowers, writing-skills, using-git-worktrees, and the plugin hooks.

Notes from the review:
- the brainstorming visual companion loads a remote logo (its author calls it telemetry); it can be turned off with
  `SUPERPOWERS_DISABLE_TELEMETRY=1` if the user wants to (not set by the kit);
- its doc suggests `--host 0.0.0.0` for remote use: never outside a disposable container (skill `opsec`).

Update: shallow-clone the upstream at a newer release, diff `brainstorming` and `writing-plans` against these, read the
changes (scripts first), copy, re-apply the patches of `PATCHES.md`, update the commit above and `PATCHES.md`, run
`scripts/context-budget.sh` (Superpowers path <= 4000 words), open a pull request.
