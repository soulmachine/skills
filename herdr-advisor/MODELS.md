# Advisor models

Ground truth for which model an advisor runs. Ranked by DeepSWE v1.1
(<https://deepswe.datacurve.ai/>, 113 tasks, board generated 2026-09-03), one
row per model at its best-scoring effort; Pass@1 is that configuration's. The
harness a model runs in is a separate choice: `HARNESS-CLIS.md`.

**Rules.** The advisor's rank must be at or above the worker's; among eligible
rows prefer another family, then the higher rank. A worker whose own model is
unreadable assumes it is the top row of its family. When the chosen model is at
its usage limit (`You've hit your usage limit` in the advisor pane, sometimes
with a silent downgrade), take the next eligible row and restore the first
pairing once the quota resets. Launch with the row's effort; where the CLI
tops out lower, use its top rung.

| Rank | Model | Family | Effort | Pass@1 |
|---:|---|---|---|---:|
| 1 | `gpt-6-astra` | openai | xhigh | 74.1 |
| 2 | `gemini-3-8-flash` | gemini | high | 73.8 |
| 3 | `claude-fable-5-1` † | claude | max | — |
| 4 | `claude-opus-5` | claude | max | 73.6 |
| 5 | `gpt-5-6-sol` | openai | max | 72.7 |
| 6 | `claude-fable-5` | claude | xhigh | 69.9 |
| 7 | `gpt-5-6-terra` | openai | max | 69.6 |
| 8 | `glm-5-3` | glm | max | 69.0 |
| 9 | `kimi-k3` | kimi | max | 68.5 |
| 10 | `grok-4-6` | grok | medium | 67.5 |
| 11 | `gpt-5-6-luna` | openai | max | 67.2 |
| 12 | `gpt-5-5` | openai | xhigh | 67.0 |
| 13 | `gemini-3-7-flash` | gemini | medium | 65.5 |
| 14 | `glm-5-3-flash` | glm | max | 63.4 |
| 15 | `deepseek-v4-pro` | deepseek | max | 62.8 |
| 16 | `claude-opus-4-8` | claude | max | 59.0 |
| 17 | `qwen3-8-max` | qwen | xhigh | 57.5 |
| 18 | `muse-spark-1-2` | muse-spark | xhigh | 54.9 |
| 19 | `claude-sonnet-5` | claude | max | 53.8 |
| 20 | `grok-4-5` | grok | high | 53.8 |
| 21 | `deepseek-v4-flash` | deepseek | max | 53.3 |
| 22 | `muse-spark-1-1` | muse-spark | xhigh | 53.3 |
| 23 | `gpt-5-4` | openai | xhigh | 51.8 |
| 24 | `gemini-3-6-flash` | gemini | high | 46.7 |
| 25 | `glm-5-2` | glm | max | 43.8 |
| 26 | `gemini-3-5-flash` | gemini | high | 36.1 |
| 27 | `kimi-k2-7-code` | kimi | — | 30.5 |
| 28 | `claude-sonnet-4-6` | claude | high | 29.9 |
| 29 | `gemini-3-1-pro-preview` | gemini | high | 11.7 |

† Not on the board. Placed above `claude-opus-5` by fiat as the newer, more
capable model of the same family; move it to its measured row when DeepSWE
scores it. On `claude`, launch it as `claude-fable-5-1[1m]`: the bare id is the
200k-context variant, and the catalog listing only the bare id is not evidence
against the suffix.

Model ids are the board's. A harness may spell one differently (`k3`,
`opus`, `claude-opus-5-xhigh`): `HARNESS-CLIS.md` says how.
