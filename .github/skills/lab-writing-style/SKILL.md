---
name: lab-writing-style
description: 'Applies this repository''s lab voice and MDX conventions to Markdown and MDX prose: README, docs/ module pages, SharedMarkdown components, workload READMEs, troubleshooting notes, and developer docs. Produces concrete, evidence-led instructions addressed to the reader as "you", free of marketing and AI-pattern filler. Use when writing, reviewing, or revising any .md or .mdx file in this repository, or when asked to fix tone, wording, or structure in lab content.'
---

# Lab Writing Style

Write like an instructor who has run this lab end to end and knows where people
get stuck. Every section should answer: why this step, what should appear, and
what artifact proves it.

Applies to `.md` and `.mdx` prose. Does not apply to code comments, commit
messages, or the literal text of quoted command output.

## Voice

- Address the reader as **you**. Do not write about "the student" or "the user"
  in instructions. Write "You submit the workload", not "The student submits the workload".
- Use active verbs with a real subject: "Terraform creates the cluster", not
  "the cluster is created".
- Open a section with the point of the exercise, not a technology claim.
- Name a choice when you first mention it. Write "CPU-only training or
  distributed GPU training," not "the selected path" before defining the two
  options.
- Use the concrete nouns of this lab: AKS, Flex node, Anyscale Job, Ray head, Ray
  worker pod, compute config, Azure Blob Storage, Terraform state, resource group,
  gate, workload summary.
- Use **Flex node VM** for the Azure VM before it joins AKS and **Flex node**
  after it joins. Avoid generic substitutes such as "external machine" or
  "Flex machine."
- Name the result. A workload summary file, pod placement JSON, a node label, or a
  deleted resource group beats "the deployment succeeded".
- Keep the caveats that save time. If a stale Anyscale cloud can linger in the
  console after teardown, say so plainly.
- Contractions are fine in narrative text. Commands, output, resource names, and
  API names stay exact.
- US English spelling in prose: "utilization", not "utilisation".

## Structure

Reuse the module skeleton already in `docs/ai-workloads-on-aks/`. Do not invent
new section names for the same job:

| Section | Purpose |
| --- | --- |
| Intro paragraph (no heading) | What this module builds and why it matters |
| `## What You Will Do` | Two to four sentences of narrative scope |
| `## Step N: <imperative phrase>` | One action per step, why before command |
| `## Validate <result>` | The command, file, or output that confirms the module worked |
| `## Troubleshooting` | Only when a known failure mode exists |
| `## Next step` | Link forward |

Additional rules:

- Headings use sentence case after the `Step N:` prefix ("Step 5: Verify cluster
  health"). Leave the established `What You Will Do` heading as it is.
- Prefer short paragraphs over bullet stacks when explaining purpose. Use bullets
  for genuinely parallel items.
- Use tables for module maps, variable references, path comparisons, and expected
  outputs. Tables are where scanning pays off.
- Do not force three-item lists. If the real list has two or five items, leave it.
- Vary sentence length without getting choppy.
- Let a section stop when the useful information runs out. No recap paragraph
  that restates the heading.
- Introduce setup commands by naming the result, such as the files and tools the
  command prepares. Avoid mechanical lead-ins such as "this command does four
  things."
- Describe repository setup from the learner's point of view: clone the folder,
  open it in Visual Studio Code, open a terminal at the repository root, and run
  the command. Do not describe wrapper scripts as entry points or narrate how
  later modules call implementation files.

## MDX Mechanics

- Every page in `docs/` needs frontmatter with `title`, `sidebar_label`,
  `description`, `sidebar_position`, and `tags`. The `description` is a real
  sentence about what the page does, not a slogan.
- Use Docusaurus admonitions with a title: `:::info What AKS Flex Node actually
  allows`, `:::warning GPU support status`, `:::caution`, `:::tip`. Close with
  `:::`. Reserve `warning` and `caution` for things that cost money or break the
  lab.
- Reuse shared components instead of retyping their content:
  `import Prerequisites from "../../src/components/SharedMarkdown/_prerequisites.mdx";`
  and `_cleanup.mdx`.
- Code fences always carry a language (` ```bash `, ` ```json `, ` ```hcl `).
- `.markdownlint-cli2.jsonc` disables MD013 (line length) and MD033 (inline HTML).
  Everything else is enforced, so keep heading levels sequential and lists
  consistently marked.
- Never reflow or "improve" pasted command output, log lines, or JSON to match
  the prose style. Those are evidence.

## Avoid

- Marketing language: seamless, robust, powerful, cutting-edge, transformative,
  world-class, game-changing, enterprise-grade.
- Empty process verbs: leverage, utilize, streamline, unlock, empower, facilitate,
  dive deep, take a closer look, delve.
- Broad openers: "In today's world", "In an era of", "As organizations...".
- Vague references such as "the path," "the machine," "this directory name," or
  "the settings that drive the lab" when the concrete option, resource, folder,
  or Terraform variables can be named.
- Formulaic contrasts: "not only X but also Y", "it is not just X, it is Y",
  "from X to Y" unless it is a genuine range.
- Trailing significance clauses: "..., ensuring reliability", "..., making it
  easy to scale", "..., which is critical for production workloads".
- Unsupported authority: "research shows", "industry experts agree", "best
  practice" without a named source or a result from this lab.
- Unprompted cost claims for commands that only prepare local files or tools.
  Mention cost when a step creates, resizes, or leaves a billable resource.
- Cheerleading. Confidence comes from workload results and checks.
- Em dashes and decorative punctuation in prose. Use commas, periods, or
  parentheses. This rule covers prose only, not SVG assets or quoted output.
- Bold applied to whole sentences for emphasis.

## Rewrite Patterns

Before and after, drawn from the kind of text this lab attracts:

| Rejected | Replacement |
| --- | --- |
| "This module leverages Terraform to seamlessly provision robust AKS infrastructure." | "Terraform provisions the AKS cluster, the VNet, and the peering that the Flex node needs later." |
| "Ensure the node is ready." | "Run `kubectl get node "$FLEX_NODE"` and wait for `STATUS` to read `Ready`." |
| "The gate plays a key role in validating the deployment." | "Gate 3 fails if the Flex node still carries the `kubernetes.azure.com/cluster` label." |
| "You will see that the deployment succeeded." | "`workload-summary.json` lists each worker hostname and the region it ran in." |
| "The workload is submitted and results are collected." | "You submit the workload with `./scripts/run-anyscale-workload.sh --mode cpu`, then collect placement data from the job output." |
| "Cleanup is performed to remove resources." | "`terraform destroy` deletes the resource group, then you confirm the Terraform state is empty." |

General moves:

- Replace "ensure" with the action: verify, create, wait for, label, or delete.
- Replace "leverage" with "use", then check whether the sentence still says
  anything. Often it can be deleted.
- Replace a passive gate description with the reader's action or the gate's
  actual check.
- In a "Why it matters" column, name the next job the file, credential, or tool
  enables. Avoid convenience claims such as "without copying by hand" or
  implementation claims about changing the reader's system.
- When introducing `.env` or another local configuration file, explain who
  reads it and how its values reach the target tool. Do not say the file
  "drives" the lab or tell the reader to activate it when repository commands
  load it automatically.
- Explain a local configuration file once, when the lab creates or first uses
  it. Later steps should name only the values the reader must change or inspect.
- Give the reader every required value or decision in the current step before
  asking them to edit a file or run a command. Do not point to a future step for
  information required to complete the current one.
- When a configuration value depends on cloud availability or quota, put the
  read-only discovery command before the configuration edit. Carry the chosen
  value into later steps instead of asking the reader to guess and check it.
- Keep the introduction and `What You Will Do` distinct. The introduction names
  the module's decision or outcome; `What You Will Do` lists the actions. Move
  authentication, configuration, and validation details into the latter.

## Content Checks

Confirm the edited text answers these, where they apply:

- Why is this module here, and what does it unlock for the next one?
- Which Azure or Anyscale object exists after the step?
- Which command proves it, and what does correct output look like?
- Which result file should the reader keep?
- Does the CPU option stay cheap and repeatable?
- Does the GPU option show one Ray Train worker on the AKS managed GPU pool and one
  on the Flex node, both participating in the same two-rank training world?
- Does teardown show that both the Azure resources and the Terraform state are gone?
- Are all commands, paths, variable names, and labels copied from the scripts or
  Terraform rather than recalled from memory?

## Student Text Acceptance Criteria

Before you finish a student-facing text edit, confirm all of the following:

- A text-only request changes explanation, headings, callouts, expected
  evidence, or navigation only. Do not alter commands, script behavior,
  Terraform values, resource labels, timeouts, or deployment order unless the
  request explicitly requires a functional change.
- Each changed step explains why the reader runs the command before the command
  appears and identifies the stable output, check, or artifact that proves the
  result afterward.
- CPU and GPU instructions name the applicable option and say when the other
  option should skip them.
- Commands, paths, variables, labels, and expected result files come from the
  repository scripts, Terraform, or validated output. Do not invent placeholder
  resource details or fixed hardware values.
- Label command output according to what the unfiltered command prints. If a
  first run may include installation or file-creation messages, say which lines
  appear at the end instead of presenting the excerpt as the complete output.
- Shared prerequisites remain in Module 1 only. Later modules may name the
  prerequisite they rely on, but must not repeat the shared prerequisite block.
- Admonitions state a concrete decision or risk and the next safe action. Use a
  direct sentence when a callout would add no decision-making value.
- Markdown lint and the Docusaurus production build pass. If dependency or
  network limitations prevent a command, report the limitation and run the
  narrowest available validation.

## Verify Before Finishing

Run the banned-phrase sweep over what you changed:

```bash
grep -rniE "\b(leverage|utilize|seamless|robust|cutting-edge|transformative|empower|streamline|delve|dive deep|world-class|game-changing)\b" <changed-files>
grep -rn "—" <changed-files>
```

Both should return nothing for prose files. Then lint and build:

```bash
scripts/lint.sh
npm run build
```

Finally, read the changed section once from the top. If a sentence survives with
its verb removed, it was filler. Delete it.
