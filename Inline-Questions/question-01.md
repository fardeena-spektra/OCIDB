## MetaData
Question Type : Single Choice

## Question
Which backup pieces and redo are required to perform the Exercise 1 whole-CDB point-in-time recovery to the SCN recorded by `inject-ex1.sh`?

## Options
Option 1 : The latest level 1 incremental backup only; archived redo and the level 0 backup are unnecessary because RMAN reconstructs them from the control file.
Option 2 : The CDB level 0 backup as the base, the level 1 incremental backup, and the archived redo needed through the target SCN, with control-file/SPFILE protection available for the recovery.
Option 3 : A backup of only the affected `FREEPDB1` datafile and the online redo logs; a whole-CDB backup would prevent recovery to an SCN.
Option 4 : The post-`RESETLOGS` backup created after recovery, plus archived redo generated after the target SCN; earlier backups cannot be used for point-in-time recovery.

## Answers
Option 2

## Correct Answer Feedback
Option 2 is correct because the level 0 backup provides the base for the CDB, the level 1 incremental reduces the amount of data to restore, and archived redo applies changes through the recorded target SCN. Control-file and SPFILE protection also preserves the recovery metadata and instance configuration needed to complete the operation.

## Incorrect Answer Feedback
Selected Option is not correct. Option 2 is the correct answer: use the level 0 base, the level 1 incremental, and archived redo through the target SCN, with control-file/SPFILE protection available.

## Number of Retries
1