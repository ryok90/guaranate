# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This repo is **single-context**: one `CONTEXT.md` and one `docs/adr/` at the repository root.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root: the glossary of domain terms.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.
- **`GUARANATE.md`**: the product spec, and the authority on intent and non-goals.
- **`PLAN.md`**: sequencing and status, with stable task IDs.
- **`AGENTS.md`**: working conventions, the `Core → CLI` architecture boundary, and
  the non-negotiables (native power APIs, mandatory assertion cleanup, stable
  `--json` shape).

If `CONTEXT.md` or `docs/adr/` don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT.md                 ← glossary (created lazily)
├── docs/
│   ├── adr/                   ← architecture decision records
│   └── agents/                ← this directory: agent-skill configuration
├── docs-website/              ← the published Astro Starlight user docs; NOT domain docs
└── Sources/
    ├── GuaranateCore/
    └── GuaranateCLI/
```

`docs/` holds documentation for contributors and agents. `docs-website/` is the
separate, self-contained Node package that builds the user-facing documentation
site. Never put agent or domain docs in `docs-website/` — they would become
published pages — and never put user-facing guide content in `docs/`.

Should this repo ever split into multiple bounded contexts, the layout becomes a
root `CONTEXT-MAP.md` pointing at one `CONTEXT.md` per context, with
context-scoped ADRs under `Sources/<Target>/docs/adr/` and system-wide ones still
in `docs/adr/`. Until a `CONTEXT-MAP.md` exists, treat the repo as single-context.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

Domain vocabulary already fixed by the code and spec — prefer these exact terms:
**assertion**, **session**, **lease**, **deadline**, **display sleep** vs
**system sleep**, **reason**. `PowerAsserting` is the seam every non-IOKit type
depends on.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_

The same applies to `GUARANATE.md`: if a change conflicts with the spec or its
non-goals, raise the conflict rather than silently diverging.
