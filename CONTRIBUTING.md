# Contributing to This Lab

This repository follows the contribution model used by [AKS Labs](https://azure-samples.github.io/aks-labs/contributing/).

## Contribution Goals

Changes should keep the workshop:

- self-contained,
- documentation-first,
- accessible to a broad AKS audience,
- structured using Docusaurus-compatible docs and assets, and
- focused on end-to-end integration scenarios rather than re-documenting core AKS basics already covered in Microsoft Learn.

## Authoring guidance

When adding or changing workshop content:

- place workshop pages under `docs/<category>/` using lowercase hyphenated file names,
- add frontmatter with at least `title` and `sidebar_position`,
- keep the workshop self-contained and scoped to a practical lab,
- prefer end-to-end AKS integration scenarios,
- co-locate workshop assets under `docs/<category>/assets/<workshop-slug>/`, and
- keep implementation artifacts in `infra/`, `scripts/`, and `workloads/` rather than embedding large code blocks directly in docs.

## Local validation

Run the repository quality gate before proposing changes:

```bash
scripts/lint.sh
```

If this repository is initialized as a Git repository, you can also point hooks at the bundled hook path:

```bash
git config core.hooksPath .githooks
```

## Documentation expectations

Workshop pages should include:

- an objective section,
- prerequisites,
- clearly sequenced lab steps,
- cleanup guidance,
- accessible image descriptions when screenshots are used, and
- resource-conscious defaults when paid Azure services are involved.

## Review Alignment

Before proposing changes, verify that:

- the workshop topic is not already covered in `aks-labs`,
- the documentation can render cleanly in Docusaurus,
- asset placement follows the category-local `assets/` convention, and
- the lab can be completed without hidden environmental assumptions.
