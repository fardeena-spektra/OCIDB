## MetaData
Question Type : Single Choice

## Question
What evidence most convincingly proves that targeted optimizer statistics improved the `FREEPDB1` reporting query rather than merely changing its execution plan?

## Options
Option 1 : The post-statistics plan hash value is different from the baseline plan hash value.
Option 2 : The query returns the same checksum and result set while comparable executions show an improved access path and measured resource or runtime metrics, with the affected object statistics confirmed fresh.
Option 3 : An `EXPLAIN PLAN` output contains a lower estimated cost after statistics are gathered.
Option 4 : The query completes quickly once immediately after statistics are gathered, regardless of its returned data and execution metrics.

## Answers
Option 2

## Correct Answer Feedback
Option 2 is correct because it combines correctness evidence, a measurable improvement under comparable executions, a better access path, and confirmation that the targeted statistics are fresh. A changed plan or lower estimated cost alone does not prove a real workload improvement.

## Incorrect Answer Feedback
Selected Option is not correct Option 2 is the correct answer. A plan hash, estimated cost, or one uncorroborated fast execution does not by itself prove improved runtime behavior while preserving query correctness.

## Number of Retries
1