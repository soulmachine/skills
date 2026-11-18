# spec_bench.jsonl

Derived from Spec-Bench (https://github.com/hemingkx/Spec-Bench), file `data/spec_bench/question.jsonl`
at commit `fd2c1cd7d2201ef71db4c5f4e455008f017967bf`. Copyright the Spec-Bench authors, licensed under
the Apache License 2.0; a copy is in `SPEC_BENCH_LICENSE`.

Changes: each of the 480 questions keeps only its first turn, reformatted for the `custom` loader of
`sglang.bench_serving` (`conversations` = the user turn plus an empty assistant turn) with its
`category` and `question_id`. Rebuild with `scripts/spec.py convert question.jsonl > spec_bench.jsonl`.
