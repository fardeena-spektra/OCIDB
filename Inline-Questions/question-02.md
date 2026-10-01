## MetaData
Question Type : Single Choice

## Question
How does `OPEN RESETLOGS` affect the CDB incarnation, and why should you create a new RMAN backup immediately afterward?

## Options
Option 1 : `OPEN RESETLOGS` creates a new database incarnation by starting a new redo branch; a post-RESETLOGS backup establishes a recoverable baseline for the current incarnation and protects the recovered state.
Option 2 : `OPEN RESETLOGS` only renames the existing incarnation; a new backup is needed solely to reduce the size of the next archived redo log.
Option 3 : `OPEN RESETLOGS` deletes all prior RMAN metadata; a new backup is required because RMAN can no longer use any earlier backup pieces.
Option 4 : `OPEN RESETLOGS` converts the CDB to NOARCHIVELOG mode; a new backup is needed to re-enable archived redo generation.

## Answers
Option 1

## Correct Answer Feedback
Option 1 is correct answer, because OPEN RESETLOGS creates a new incarnation and begins a new redo history. A post-RESETLOGS backup provides a known-good recovery baseline for that current incarnation; the earlier backup chain remains historical and does not by itself protect the newly opened database state.

## Incorrect Answer Feedback
Selected Option is not correct Option 1 is the correct answer: RESETLOGS creates a new incarnation and redo branch, so a new backup is needed to protect the current post-recovery state and support future recovery.

## Number of Retries
1