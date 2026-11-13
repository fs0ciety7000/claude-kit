---
name: writing-plans
description: Écrire le plan d'un projet ou d'une fonctionnalité en lots dans docs/plan.md, une fois le périmètre connu et avant de toucher au code.
---

# Writing Plans

Patched for claude-kit (see `vendor/superpowers/PATCHES.md`): the plan is `docs/plan.md`, organised in lots, one agent per lot.

## Overview

Write the plan for an engineer who has not seen this codebase or this brief. They write idiomatic code once they know the exact interface and the exact test, and they make a reasonable choice wherever the plan leaves one open. What they cannot know is what you decided: which files, which names and signatures, which values from the brief, which checks prove a lot is done. Document those, nothing else. DRY. YAGNI.

**Read first:** `docs/brief.md`, `docs/memory/stack.md`, `project.yaml` (size), the code that exists.
**Save to:** `docs/plan.md` (a roadmap the project already keeps stays the reference: the plan then links to it).

## Scope Check

If the brief covers several independent subsystems, make one plan per subsystem, in an order you state. Each lot must leave working, testable software.

## Lots and tasks

- **A lot is the unit of delegation: one agent runs one lot**, with a complete brief. Draw lot boundaries where the files, the agent or the delivery change. Independent lots can run in parallel; say which.
- Small project (size S): at most 3 lots and about a dozen tasks. Larger projects: as many lots as the work needs, each deliverable on its own.
- A task is one checkable result inside a lot, not one action. Fold setup, configuration and documentation into the task whose deliverable needs them.
- Map the files first: which are created or modified, and what each is responsible for. Follow the patterns of the codebase; split by responsibility, not by technical layer.
- No review gate per task. Reviewers run after a lot, only for size L or on request.

## Format of `docs/plan.md`

```markdown
# Plan

## Lot 1 — <title>

Agent: `<agent>` · Parallel with: <lot or none> · Done when: <checkable outcome of the lot>

- [ ] <task> — fini quand : <check>
- [ ] <task> — fini quand : <check>

## Lot 2 — <title>
...

## Équipe

| Agent | Rôle dans ce projet | Modèle / effort | Source |
|---|---|---|---|
```

Per lot, add what the agent cannot guess: exact paths, the signatures and test names it must produce, the values the brief pins (copy them verbatim), the command that proves it ("`npm test`: all green"). A code body appears only for an algorithm the signature and tests do not determine.

## What a task contains

A task is done when the implementer can write exactly one reasonable thing from it. Unambiguous, not complete:

- **Test:** the test's name and its assertions, with the brief's exact values.
- **Code:** the signature (name, parameters, return type), the file, the values the brief pins.
- **Verification:** the command to run and the output that means it passed.
- **Reference to another lot:** what it produces that this one consumes (names and types).

Lines that decide nothing ("TBD", "handle edge cases", "add appropriate validation", a function no task defines) are a gap. A plan longer than the code it describes has written the code instead.

## Self-Review

Run this yourself, once, after writing the plan:

1. **Coverage:** can you point to a task for each requirement of the brief? Add the missing ones.
2. **Consistency:** names, signatures and file paths match from one lot to the next.
3. **Proportion:** a plan several times longer than the brief is a transcript of the program. Cut bodies down to signatures and checks.
4. **Risks:** data migrations, security, exposure, anything to validate with the user, each in one line.

Fix issues inline and move on.

## Handoff

Link `docs/plan.md` and ask for one validation (the plan). Then run the lots in order: one agent per lot, your own check of diff, tests and build after each, the lot's boxes ticked in `docs/plan.md`.
