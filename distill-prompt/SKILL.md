---
name: distill-prompt
description: Distill this conversation's underlying goal into one reusable prompt that reaches the same final outcome in a fresh session.
disable-model-invocation: true
---

Read this whole conversation, then write one prompt that a fresh session, with no memory of it, can run to reach the same final outcome.

The prompt states **what**. Models are strong enough to find the how, so spend the words on the goal and on taste:

- **Outcome.** The end state the user wanted, as they finally steered it, and how to tell it is reached. The first request can differ from it.
- **Taste.** The quality bar the user enforced, from their preferences and corrections, each stated as a rule. Taste separates a good result from one that merely works.
- **Facts it cannot discover.** A path, host, account or name that the fresh session could not find by looking. Name a secret by where it is stored, never by its value.

Steps, commands and the route this session took are the how: leave them to the fresh session. Add a why only where the outcome cannot be judged without it.

Before you answer, read the prompt as the fresh session would. Every word must make sense without this conversation.

Output the prompt in one fenced code block and nothing else.
