# Local patches to Superpowers

Upstream: [obra/superpowers](https://github.com/obra/superpowers) at commit `22f0b463e7a5e579904dd6211a520321035526f7`
(2026-11-03). The kit keeps two skills, both modified here. Every change is listed so that an upstream update can be
merged by hand: re-apply these patches after copying a newer release, then re-measure with `scripts/context-budget.sh`
(budget: Superpowers on the `/new-project` path <= 4000 words).

## Removed (lot 2f)

The other nine skills are no longer in `global/skills/`: `executing-plans`, `subagent-driven-development`,
`dispatching-parallel-agents`, `requesting-code-review`, `receiving-code-review`, `systematic-debugging`,
`test-driven-development`, `verification-before-completion`, `finishing-a-development-branch`.

Why: they add up to about 10 000 words on the project start path in v1 and steer the work toward one subagent and
one review per task, the opposite of the v2 method (one agent per lot, reviewers by project size, checks by the main
thread). They stay available in the `legacy/v1` branch of this repository and upstream. The Superpowers plugin is not
installed either (`PLUGINS.md`): it would bring all the skills back, with a startup hook.

## `brainstorming` (`global/skills/brainstorming/`)

| Part | Upstream | Here | Why |
|---|---|---|---|
| `description` | "You MUST use this before any creative work…" | French, limited to a vague idea ("Clarifier une idée floue…"), 20 words | the upstream trigger fired on every feature and added a design phase to clear requests |
| Handoff (opening list, HARD-GATE) | invoke `superpowers:writing-plans` and no other skill | hand over to `writing-plans` (size S) or the `architect` agent (M, L) | the skills it chained to are removed; M and L plans come from `architect` |
| Design document | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` | `docs/brief.md`, same content plus an Approaches part | one brief per project, read by every agent |
| Builder check | a fresh subagent runs `builder-check-prompt.md` | the main thread reads the document as that builder, same three piles of questions | one fewer subagent; `builder-check-prompt.md` deleted |
| HARD-GATE wording | "invoking an implementation skill" | "starting an implementation lot" | no implementation skill left |
| Header | none | one line saying the skill is patched | traceability |

Unchanged: the conversation method, playback, sizing, red flags, the visual companion (`visual-companion.md` and
`scripts/`, started only if the user accepts the offer).

## `writing-plans` (`global/skills/writing-plans/`)

Rewritten (1 639 words upstream, about 670 here), keeping the upstream principles (a plan holds the decisions the
implementer cannot make alone; signatures and test names rather than bodies; self-review; proportion).

| Part | Upstream | Here | Why |
|---|---|---|---|
| `description` | "Use when you have a spec…" | French, "écrire le plan … en lots dans docs/plan.md", 24 words | matches the harness language and the v2 plan format |
| Output file | `docs/superpowers/plans/YYYY-MM-DD-<feature>.md` | `docs/plan.md`, lots with checkboxes, `Agent / Parallel with / Done when` line per lot, `Équipe` table | `docs/plan.md` is the only task list |
| Unit of work | bite-sized TDD steps, one subagent per task | one lot = one agent, tasks are checkable results | v2: one subagent per lot |
| Plan header | "REQUIRED SUB-SKILL: use superpowers:subagent-driven-development or executing-plans" | removed | those skills are removed |
| Context line | worktree "created via `superpowers:using-git-worktrees`" | removed | that skill is not kept either |
| Task right-sizing | "worth a fresh reviewer's gate" | no review gate per task; reviewers after a lot, size L or on request | v2 review policy |
| Review Focus section, Global Constraints, Spec header | required | dropped (constraints and pinned values go into each lot) | proportion |
| Execution handoff | ask the user to choose subagent-driven or native | one validation (the plan), then lots run in order | v2: two validations only |
| Announcement | "I'm using the writing-plans skill…" | removed | noise |

## Not kept from the start

`using-superpowers`, `diagnosing-superpowers`, `writing-skills`, `using-git-worktrees`, and the plugin hooks
(see `README.md`).
