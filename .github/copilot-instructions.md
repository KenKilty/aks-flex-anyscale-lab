# Copilot Instructions

## Lab Writing Style Comes First

When editing Markdown or MDX in this repository, load and follow `.github/skills/lab-writing-style/SKILL.md` before drafting or revising text.

This applies to README text, Docusaurus module pages, shared Markdown components, workload README files, troubleshooting notes, and developer docs.

Use the skill to keep lab prose student-friendly, concrete, evidence-led, and free of promotional or AI-pattern filler. Keep exact commands, expected output, resource names, and API names technically precise.

Before finishing doc work, check that the edited text explains why the step matters, what the student should see, and what command or artifact proves it.

## Docs development workflow

Always use `scripts/docs-dev.sh` to start or restart the local Docusaurus dev server.
This script kills any stale process on port 3000, clears the Docusaurus cache (`docusaurus clear`), and starts fresh so stale builds do not trigger `@generated` module errors.

```bash
scripts/docs-dev.sh
```

Never suggest `npm start` directly for local docs development.
Use `npm run build` to validate the production build before committing.

## Repository structure

- `docs/`: Docusaurus workshop content. All new workshop pages go in `docs/ai-workloads-on-aks/`.
- `infra/terraform/`: AKS, networking, storage, and Flex host infrastructure.
- `scripts/`: Operator entrypoints, lint commands, workload helpers, and docs helpers.
- `workloads/`: Workload proof packages and validation helpers.
- `src/`: Docusaurus React components and CSS.

## Code style and quality

Run `scripts/lint.sh` before committing. It covers:

- Python (ruff format + ruff check)
- Shell (shellcheck)
- Markdown and MDX (markdownlint-cli2)
- TypeScript (tsc --noEmit)
- npm security audit (scripts/audit-npm.sh)
- Terraform (fmt + validate)

## Deployment

- Use `.env-template` as the base for local `.env` files.
- Use `ANYSCALE_AKS_ENV_FILE=<file> ./scripts/anyscale-aks.sh <command>` for alternate profiles.
- Never commit `.env` files.
