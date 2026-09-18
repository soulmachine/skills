#!/bin/sh
# Retired: watchdog.sh replaced this Stop hook (DECISIONS.md Q47). Every fleet
# host still renders ~/.agents/hooks/Stop.toml into its Claude Code and Codex
# hook files, so this stub answers those calls with a no-op until that file is
# gone everywhere; then delete this too.
printf '{}\n'
