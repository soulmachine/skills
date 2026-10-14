---
name: distill-prompt
description: Distill the current session into one paste-ready prompt that takes a fresh session to the same final outcome in one pass. Use when the user asks to distill, replay or turn this conversation into a reusable prompt.
---

# distill-prompt

The reader of your output is a **fresh session**: an agent with the same tools and host, and no memory of this conversation. Your job is to hand it the shortest path to where this session ended, minus the detours.

## Steps

1. **Read the whole session**, from the first user message to the last. Include tool results, interruptions and any compaction summary. Done when you can name the final state the session reached: what exists now, what changed, what was decided.
2. **Name the goal.** Write one sentence: the outcome the user wanted and the problem it solves. Derive it from what the user kept steering toward, which can differ from their first request. Done when the user would read the sentence and say "yes, that".
3. **Harvest the requirements.** Walk the session again and collect:
   - **Rules.** Every constraint, preference and correction the user gave, stated as a present-tense rule.
   - **Dead ends.** Every approach that failed, stated as the approach that works. Name the failed one only where a fresh session would reach for it first.
   - **Anchors.** Exact paths, hosts, repos, accounts, tool names and commands the outcome depends on.
   - **Acceptance check.** The observable result that proves the work is done: a command and its output, a file that exists, a page that renders.

   Done when every user correction in the session maps to a rule, or you have judged it a one-off that a fresh session would never repeat.
4. **Write the prompt.** One paragraph, imperative, addressed to the agent: the goal first, then rules, anchors and the acceptance check. Keep only what changes the fresh session's behaviour. The order of events, the exploration and names coined during the session stay out.
5. **Cold read.** Read the prompt as the fresh session would. Every reference resolves without this conversation. Following it reaches the goal with no detour this session took. Fix and repeat until both hold.

## Output

The prompt in a single fenced code block, ready to paste. After it, one line listing anything deliberately left out that the user might expect to see.
