## MetaData
Question Type : Single Choice

## Question
The seeded AWR/ASH-style evidence for the dominant `FREEPDB1` reporting SQL shows a large estimated-versus-actual row mismatch at a join, elevated `db file scattered read` time and physical reads, stale or missing statistics on the affected objects, modest CPU consumption, and no meaningful `enq:` or row-lock wait time. Which diagnosis is best supported?

## Options
Option 1 : The regression is primarily cardinality-driven I/O: stale or missing statistics caused an inaccurate row estimate and an inefficient access path, leading to excessive physical reads.
Option 2 : The regression is primarily CPU pressure: the query has accurate cardinality estimates, but insufficient CPU is causing the optimizer to choose a slower plan.
Option 3 : The regression is primarily locking contention: another session is holding row locks, and the physical reads are a secondary symptom of blocked transactions.
Option 4 : The regression is primarily redo or commit contention: the reporting query is waiting on log synchronization, so gathering object statistics would not address the problem.

## Answers
Option 1

## Correct Answer Feedback
Option 1 is correct answer, because the row-estimate mismatch, stale or missing object statistics, physical-read-heavy wait profile, and low CPU and locking signals together support a cardinality-driven I/O problem rather than CPU or contention pressure.

## Incorrect Answer Feedback
Selected Option is not correct Option 1 is the correct answer. The evidence points to inaccurate cardinality estimates and excessive physical reads, while CPU, locking, and commit-related pressure are not dominant.

## Number of Retries
1