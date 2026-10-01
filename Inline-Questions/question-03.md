## MetaData
Question Type : Single Choice

## Question
Why is recovering only the missing `FREEPDB1` training datafile preferable to restoring the whole CDB for Exercise 2?

## Options
Option 1 : It limits the operation to the affected PDB/datafile, minimizes disruption, and preserves committed data in unaffected CDB and PDB files.
Option 2 : It recreates the missing datafile from the PDB control file without requiring an RMAN backup or archived redo.
Option 3 : It automatically performs a whole-CDB point-in-time recovery while keeping every PDB open throughout the operation.
Option 4 : It avoids the need to place the affected tablespace or PDB in an appropriate recovery state because datafile recovery is online in every case.

## Answers
Option 1

## Correct Answer Feedback
Option 1 is correct because the incident is isolated to a dedicated `FREEPDB1` datafile. A container-aware, datafile-scoped RMAN restore and recovery limits disruption and avoids replacing or rolling back unaffected CDB and PDB data; archived redo and a usable backup are still required.

## Incorrect Answer Feedback
Selected Option is not correct. Option 1 is the correct answer: restore and recover only the affected `FREEPDB1` datafile with the proper PDB/container context, preserving unaffected data and avoiding unnecessary whole-CDB recovery.

## Number of Retries
1
