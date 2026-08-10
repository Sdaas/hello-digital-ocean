# hello-digital-ocean — Design Overview

> The curated, end-to-end design and **key** decisions for hello-digital-ocean.
> Keep this current. Record only decisions that shape the architecture.

## Purpose

Sample setup for running a webapp + Ollama on Digital Ocean infrastructure

## Architecture

The authoritative end-to-end design for this repo was produced upstream by
`/sdlc-discovery` and `/sdlc-architecture`. Do **not** duplicate it here — see:

- Concept & use cases: [`discovery/concept.md`](../discovery/concept.md),
  [`discovery/use-cases.md`](../discovery/use-cases.md)
- Architecture overview (capability map, components, container diagram, cost):
  [`architecture/overview.md`](../architecture/overview.md)
- Feature backlog (F1–F10): [`architecture/components.md`](../architecture/components.md)
- Decision records: [`architecture/decisions/`](../architecture/decisions/) (ADRs 0001–0007)
- Phase status & build order: [`PROGRESS.md`](../PROGRESS.md)

This file remains the home for design notes that emerge during per-feature
`/sdlc-feature` design gates.

## Key Decisions

<!-- One bullet per KEY decision, with a one-line rationale. Not every decision. -->
- Stack profile: shell (cli); distribution: none.
- **Naming:** the main artifact is the **`digital-ocean`** control CLI
  (`bin/digital-ocean`); the **demo app** lives in **`demo/`** and exists to
  showcase that the CLI works. (Repo is named `hello-digital-ocean`; binary is
  `digital-ocean`.)
- Logging: leveled logging — INFO (default) and DEBUG (via `--verbose`), ERROR
  always — to **stderr** (stdout stays data-only), ISO-8601 UTC timestamps. The
  entry point ships with `log_*` / `logging` / `console` helpers demonstrating it.

## Constraints

<!-- Security / performance / scale constraints captured at project start. -->
None recorded at project start. (See `architecture/overview.md` and the ADRs
for design decisions that carry implicit constraints, e.g. cost and networking.)

## Design & Usability Considerations

<!-- Anything shaping design or UX captured at project start. -->
None recorded at project start.
