---
name: lab-writing-style
description: 'Use when writing or revising this repository''s lab docs, README, module MDX, student instructions, proof narratives, troubleshooting notes, or developer docs. Keep the lab voice concrete, student-friendly, evidence-led, active, and free of promotional or AI-pattern filler.'
---

# Lab Writing Style

Use this skill when editing lab-facing Markdown or MDX in this repository.

## Goal

Write like an instructor who has run the lab and knows where students get stuck. The text should explain why a step matters, what the student should see, and what evidence proves the system behaved correctly.

## Voice

- Start with the point of the exercise, not a broad technology claim.
- Use active verbs. Prefer "Terraform creates the cluster" over "the cluster is created."
- Use concrete nouns from this lab: AKS, Flex host, Anyscale Job, Ray worker pod, Azure Blob Storage, Terraform state, resource group.
- Name the evidence students will collect. A proof summary, pod placement JSON, a Kubernetes label, and a deleted resource group are better than generic success language.
- Keep caveats when they help students avoid wasted time. If a stale Anyscale cloud can remain in the console, say so plainly.
- Use contractions in narrative text when they make the sentence less stiff. Keep commands and expected output exact.

## Structure

- Prefer short paragraphs over long bullet stacks when explaining the purpose of the lab.
- Use tables for module maps, configuration values, and expected outputs where scanning matters.
- Avoid repeating three-item patterns. If a list naturally has two, four, or six items, leave it that way.
- Vary sentence length without making the text choppy.
- Put the why before the command when a student might otherwise treat the command as magic.
- Let sections end when the useful information is done. Do not add recap paragraphs that repeat the heading.

## Avoid

- Marketing language: seamless, robust, powerful, cutting-edge, transformative, world-class, game-changing.
- Empty process language: leverage, utilize, streamline, unlock, empower, dive deep, take a closer look.
- Broad openers: "In today's world," "In an era of," "As organizations..."
- Formulaic contrasts: "not only X but also Y," "it is not just X, it is Y," "from X to Y" unless it is a real range.
- Unsupported claims such as "research shows," "industry experts say," or "best practice" without a named source or lab result.
- Cheerleading. Confidence should come from proof artifacts and clear checks.
- Em dashes and decorative punctuation in lab prose. Use commas, periods, or parentheses.

## Rewrite Patterns

- Replace "leverage" with "use," then check whether the sentence still says anything useful.
- Replace "ensure" with the concrete action: "verify," "create," "wait for," "label," or "delete."
- Replace "plays a key role" with the actual behavior.
- Replace "proof of successful deployment" with the specific file, command output, or Kubernetes placement evidence.
- Replace passive gate descriptions with student actions: "Run the gate" or "The gate checks..."

## Lab-Specific Checks

Before finishing a doc change, confirm the text answers these questions when they apply:

- Why is the student doing this module?
- What Azure or Anyscale object should exist after the step?
- Which command proves it?
- Which artifact should the student keep?
- Does the CPU path stay cheap and repeatable?
- Does the GPU path prove the Ray worker landed on Flex, not on an AKS managed GPU node pool?
- Does teardown prove both Azure resources and Terraform state are gone?

## Final Pass

Read the edited section aloud once. Remove filler, fix stiff passive wording, and keep exact technical names intact.
