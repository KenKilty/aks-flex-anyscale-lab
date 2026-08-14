---
name: "Browser-Led Student Lab"
description: "Test the rendered AKS Flex Node and Anyscale lab as a first-time student using the integrated browser, remediate observed defects, chronicle evidence, and verify teardown."
argument-hint: "Optional: target profile, suspected regression, CPU/GPU scope, or other acceptance criteria"
agent: "agent"
---
# Browser-Led Student Lab

Run this repository's lab end to end as a first-time student. Treat the rendered Docusaurus site as the only runbook and fix the source whenever observed behavior differs from the page. Honor invocation arguments as additional acceptance criteria. If an argument conflicts with this prompt's safety or teardown rules, follow the safer rule and report the conflict.

## Non-negotiable student boundary

- Enter **student mode** after the two credential preflights below. In student mode, the rendered Docusaurus pages are the only deployment runbook. Ignore prior repository knowledge and do not pre-read Markdown, MDX, scripts, Terraform, workload code, tests, generated files, or Git history.
- Use only commands, values, links, decisions, and recovery steps that a rendered student page presents. Do not use `scripts/run-lab-e2e.sh`, test harnesses, undocumented helpers, remembered commands, or a source-code search to make progress.
- You may inspect a file in the temporary student workspace only when the rendered page explicitly tells the student to open, edit, or inspect that file. This permission does not extend to the source checkout.
- The only cloud or account checks allowed before student mode are the Azure account preflight and cached Anyscale credential preflight defined below. Local journal creation, source-worktree bookkeeping, temporary-workspace creation, and Docusaurus startup are test-harness setup, not deployment guidance.
- Leave student mode and inspect implementation or documentation source only after an observed command error, an observed result that contradicts the rendered expected result, or a rendered instruction that cannot be followed because it is materially unclear or incorrect. Follow the remediation loop exactly, then return to student mode.
- Work autonomously through the rendered setup, deployment, proof, and teardown. Ask only when the rendered lab requires a choice that cannot be inferred, the two preflights fail, or a destructive action could affect resources not clearly owned by this lab.
- Preserve pre-existing changes. Never reset or overwrite work you did not create. Do not commit, push, merge, stage files, or close pull requests unless the user explicitly asks in the current conversation.
- Never expose tokens, credential files, kubeconfigs, private keys, signed URLs, complete environment files, or secret-bearing command output in chat, screenshots, or `LABTEST.md`.

## Browser and workspace rules

- Use only the VS Code integrated browser for browser actions. Start it with `Browser: Open Integrated Browser`, then use `run_playwright_code` for navigation, rendered-page reading, scrolling, clicking, typing, waiting, and screenshots.
- Keep the Docusaurus page open for the full run. Use another page in the same integrated browser only when a rendered lab link requires it. Do not launch a system browser, browser profile, URL handler, or external Playwright/Chromium process.
- If the integrated browser or `run_playwright_code` is unavailable, record the blocker in `LABTEST.md` and stop. Raw source, `curl`, terminal-rendered HTML, and an external browser are not substitutes for the student view.
- Keep the repository checkout as the source-fix workspace. Create an empty temporary parent directory for the student run, then execute the rendered clone/setup instructions there. Run every student command from that temporary clone unless the rendered page explicitly says otherwise.
- Read one rendered module from top to bottom before running its commands. Do not pre-scan later modules. Use the rendered Next link, then wait for the page title and main heading before continuing.
- Behave like a careful first-time student: copy commands as rendered, make only stated substitutions, inspect the complete output, compare it with the page, and stop when the result is unclear. Do not silently improve or reinterpret a command.

## Required workflow

1. Read [the repository instructions](../copilot-instructions.md). Load [the lab writing skill](../skills/lab-writing-style/SKILL.md) only as process guidance; do not use either file as a deployment runbook.
2. Create `LABTEST.md` at the repository root before any preflight. It is a temporary, Git-ignored chronicle. Record the start time, invocation arguments, source branch and commit, initial worktree status, temporary student-workspace path, and each subsequent action. Never stage or commit it.
3. Run the two read-only authentication preflights from the source checkout before starting Docusaurus or following Module 1:

   **Azure account preflight:**

   ```bash
   az account show \
     --query '{subscriptionId:id,subscription:name,tenantId:tenantId,user:user.name}' \
     --output json \
     --only-show-errors
   ```

   Require nonempty `subscriptionId`, `subscription`, `tenantId`, and `user`. Record only those account identifiers and the pass/fail result. Do not run `az login` or change the active subscription. If the account is absent or is not the intended target, stop before deployment and ask the user to authenticate or select the account outside this test run.

   **Cached Anyscale credential preflight:**

   ```bash
   ANYSCALE_HOST=https://console.azure.anyscale.com \
     .venv/bin/anyscale cloud list \
     --json \
     --no-interactive \
     --max-items 1 >/dev/null
   ```

   Require exit code `0`. This proves the repository-local CLI can use a cached credential against the Azure Anyscale control plane without exposing the token. Do not run `anyscale login`, open an authentication page, read the credential store, print environment variables, or request a token in chat. If the CLI is missing or the command fails, record the blocker and stop before deployment so the user can cache the credential outside this test run.
4. Start or restart Docusaurus only with `scripts/docs-dev.sh`. Open the workshop overview in the integrated browser with `run_playwright_code`; record its title and URL and capture the first screenshot.
5. Enter student mode. Follow the rendered module order in the temporary clone. Run each command exactly as shown and chronicle the command, observed result, and evidence before moving to the next instruction.
6. At every module boundary, record the rendered page title, main heading, relevant artifact paths or resource identifiers, and a screenshot. Post a short progress update in chat.
7. If a step fails or the page is unclear or incorrect, run the remediation loop below. Do not skip the step, use an undocumented workaround, or continue with a guessed state.
8. Run the CPU path before an optional GPU path unless invocation arguments explicitly select GPU only. Use only the rendered readiness and proof commands. Do not claim a cross-region run passed unless the rendered checks and captured worker placement prove it.
9. Follow the rendered teardown module even after a workload failure. Use only its commands. A failed query, unreadable Terraform state, or interrupted destroy is not evidence that resources are absent.
10. If an external service or authentication failure blocks teardown, follow only the rendered recovery path, record the exact blocker, and report every resource that may remain. Never report the lab complete while billable resources are unverified.

## Remediation loop

Source access is an exception, not a parallel path through the lab.

1. Stop at the failing or unclear student step. Add a chronicle entry containing the rendered instruction, exact command or browser action, exit code, concise output or screenshot reference, and expected result.
2. Reread the current rendered section with `run_playwright_code`. If the page already contains a recovery path, follow it as a student before inspecting source.
3. If the documented recovery fails or the page is materially wrong, state one falsifiable local hypothesis. Inspect only the smallest owning source surface needed to test it: the associated MDX/Markdown page and the script, Terraform module, workload file, or test directly responsible for the observed behavior. Do not perform a general repository audit.
4. Fix the root cause in the source checkout. If code or configuration changes, update the associated student-facing lab content in the same remediation so the rendered command, explanation, expected output, and evidence remain accurate.
5. Before editing any Markdown or MDX, reread and follow [the lab writing skill](../skills/lab-writing-style/SKILL.md). Keep the correction concrete, student-facing, and evidence-led.
6. Run the narrowest executable check that can disprove the hypothesis. Then run the applicable focused tests and Markdown lint. Do not continue patching around a failed validation.
7. Let Docusaurus reload. Use `run_playwright_code` to revisit the corrected section and verify its text, links, controls, layout, and expected output in the integrated browser.
8. Mirror only the required implementation fix into the temporary student clone. Retry the original rendered student step exactly. Record the initial failure, root cause, changed files, validation, retry, and final status in `LABTEST.md`.
9. Return to student mode immediately after the retry passes. Do not keep reading source to search for adjacent improvements.

## Chronicle contract

Use `LABTEST.md` as an append-only working record during the run. Keep it concise enough to review but complete enough to reproduce the student's path.

Start with:

```markdown
# Browser-Led Student Lab Chronicle

- Started: <UTC timestamp>
- Invocation: <arguments or default CPU path>
- Source: <branch> at <commit>
- Initial worktree: <clean or concise changed-file summary>
- Student workspace: <temporary path>
- Azure preflight: <PASS or BLOCKED; account identifiers only>
- Anyscale preflight: <PASS or BLOCKED; never include token data>
```

For each action or finding, record:

```markdown
## <timestamp> | <module and step>

- Rendered instruction: <concise statement>
- Action: `<exact command>` or <Playwright browser action>
- Observed: <exit code and concise result>
- Evidence: <artifact path, resource ID, or screenshot label>
- Status: PASS | FAIL | BLOCKED | REMEDIATED
- Remediation: <root cause, source files, validation, and retry when applicable>
```

Do not clean up or rewrite earlier failures. Append retries so the chronology remains honest. Record warnings, transient failures, unexpected versions, and stale output instead of hiding them.

## Evidence checkpoints

At each boundary, add concise proof to `LABTEST.md` using only evidence produced by rendered student commands:

These checkpoints describe evidence to preserve, not permission to invent a
command. If the rendered lab does not produce a required item, record the gap as
a finding and enter the remediation loop instead of running an undocumented
check.

- **Preflight:** active Azure account identifiers and cached Anyscale credential pass/fail, with no credential material.
- **Clean start:** the rendered lab's own environment and state checks.
- **Modules 1-2:** environment checks, plan/apply result, AKS health, and bidirectional network evidence.
- **Module 3:** AKS `networkPlugin=none` profile, Unbounded-managed `/24` pod CIDRs from the configured AKS and Flex ranges, no competing CNI DaemonSet, resolved stable Flex Node tag, generated Flex join contract, matching helper/config tag, archive checksum, preflight result, bounded bootstrap result, node readiness, labels, taints, Unbounded CNI and Flex kube-proxy readiness, a scheduled workload pod, ClusterFirst DNS, HTTPS egress, and bilateral cross-site pod connectivity.
- **Modules 4-5:** extension/operator readiness, Anyscale cloud binding, Flex connectivity, and autoscaling evidence.
- **Module 6:** local smoke result, remote job status, proof summary, runtime versions, storage proof, and Kubernetes placement artifact.
- **Module 7:** stopped jobs, destroy result, both resource-group absence checks, and successful empty Terraform state output.

## Closeout

1. Review every chronicle entry against the rendered page and captured evidence. Reopen any remediation whose fix lacks executable evidence or whose expected output does not match observed output.
2. Run the lab-writing banned-phrase checks over changed prose, then run `scripts/lint.sh`, `npm run build`, and `git diff --check`. Check editor diagnostics for changed files. Report commands that could not run and preserve their errors.
3. Delete root-level `LABTEST.md` at closeout unless the user asks to retain the chronicle for review. If the run is blocked or a finding remains open, preserve its relevant contents in the completion report or a user-approved issue before deleting it.
4. Confirm the source worktree contains only intended changes and that the temporary clone and generated artifacts are not staged.

## Completion report

Summarize:

- Whether the full rendered path passed, or stopped at a documented compatibility gate.
- Whether a suspected regression from the invocation reproduced, when applicable.
- The proof job IDs and evidence artifacts.
- Every source file changed and why.
- Lint and production-build results.
- Azure resource-group and Terraform-state teardown proof.
- `LABTEST.md` disposition.
- Remaining defects, resources, costs, or external blockers.

State clearly that no commit or push was performed unless the user explicitly requested it.
