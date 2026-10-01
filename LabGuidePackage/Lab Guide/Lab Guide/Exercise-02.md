# Exercise 2 — Recover a `FREEPDB1` training datafile

**Estimated time:** 30 minutes  
**Assessment weight:** 25%

A dedicated training datafile in `FREEPDB1` has been removed. Your task is to diagnose the failure and use RMAN to restore and recover only the affected PDB datafile. You must preserve committed data, avoid unnecessary CDB-wide disruption, and retain evidence of file and data integrity.

> [!Important]
> This is a task-based assessment. The guide identifies objectives, constraints, useful evidence sources, and outcome checks, but it does not provide the completed RMAN recovery command sequence.

## Objectives

In this exercise, you will:

- Run the protected `/opt/lab/inject-ex2.sh` fault-injection script.
- Identify the missing training datafile and prove that it belongs to `FREEPDB1`.
- Correlate container-aware Oracle views, RMAN metadata, Oracle diagnostic logs, and filesystem state.
- Restore and recover only the affected datafile in the correct PDB context.
- Return the affected tablespace and `FREEPDB1` to their required online/open states.
- Prove that no file still needs media recovery and that the seeded row/checksum markers are unchanged.

## Assessment constraints

You must observe all of the following constraints:

- Run the supplied injection script exactly once unless it reports that the fault is already active.
- Do not edit, move, truncate, replace, or change permissions on the protected injection record under `/opt/lab`.
- Do not recreate the missing datafile manually and do not recreate the seeded rows.
- Do not perform a whole-CDB restore, whole-CDB point-in-time recovery, or another `OPEN RESETLOGS` operation.
- Do not restore or recover `CDB$ROOT`, `SYSTEM`, `SYSAUX`, undo, temp files, control files, online redo logs, or unrelated application datafiles.
- Limit downtime to the affected `FREEPDB1` tablespace/datafile and only close the PDB if your selected recovery method requires it.
- Save command output and RMAN logs. Fabricated evidence or hard-coded success does not receive credit.

## Task 1 — Sign in and connect to the managed node

1. Open the AWS sign-in URL: <inject key="AwsConsoleUrl"></inject>
2. Sign in with:
   - **IAM user name:** <inject key="IamUserName"></inject>
   - **Password:** <inject key="IamUserPassword"></inject>
3. Confirm that the console is showing:
   - **AWS account:** <inject key="AwsAccountId"></inject>
   - **Region:** <inject key="AwsRegion"></inject>
4. For this deployment, use the deployment identifier <inject key="DeploymentID"></inject> when distinguishing the lab stack from other stacks.
5. In the AWS Management Console, open **CloudFormation** and choose **Stacks**.
6. Select the lab stack associated with the deployment identifier, open **Outputs**, and copy the EC2 instance ID shown by the instance/SSM target output.
7. Open **Systems Manager**. In the navigation pane, choose **Session Manager**, and then choose **Start session**.
8. Select the managed node whose instance ID matches the CloudFormation output, and choose **Start session**.

> [!Note]
> Session Manager requires the instance to be registered as a managed node. The lab bootstrap installs and starts SSM Agent and attaches an instance profile with `AmazonSSMManagedInstanceCore`. If the instance is not listed, first recheck the Region and instance ID; do not alter the instance role or reinstall the agent during the assessment.

### Optional AWS CLI connection

The CLI `start-session` command is interactive and requires the Session Manager plugin on the computer where the command runs. Set `AWS_REGION` to the AWS Region displayed above and `INSTANCE_ID` to the CloudFormation instance output, then run:

```bash
aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
```

After the session opens, verify the target and readiness marker:

```bash
hostname
sudo test -f /opt/lab/.ready && echo "Lab bootstrap is ready"
sudo systemctl is-active amazon-ssm-agent
```

## Task 2 — Start an evidence transcript and inject the fault

1. In the Session Manager shell, create a learner-owned evidence directory and begin a terminal transcript:

   ```bash
   mkdir -p "$HOME/lab-evidence/exercise-02"
   script -a "$HOME/lab-evidence/exercise-02/session.typescript"
   date -u
   ```

2. Confirm that Exercise 1 has been completed successfully. At minimum, the CDB must be in its post-`RESETLOGS` incarnation, `FREEPDB1` must be healthy before injection, and a usable post-`RESETLOGS` backup must exist. The injection script checks these prerequisites and creates that backup only when it is missing.
3. Run the fault injection:

   ```bash
   sudo /opt/lab/inject-ex2.sh
   ```

4. Record the script's reported training tablespace, datafile identity, file path, and pre-loss integrity markers in your evidence. Do not modify the protected source record.
5. If the script refuses to proceed, read its message and correct only the stated prerequisite. Do not bypass its checks. If it reports an already-active Exercise 2 fault, diagnose the existing fault rather than running or editing the script again.

## Task 3 — Diagnose the missing datafile

Build a container-aware diagnosis before performing any restore. Save the results as `$HOME/lab-evidence/exercise-02/diagnosis.txt` or capture equivalent output in the session transcript.

### 3.1 Establish container and database state

Connect to Oracle with the lab's operating-system authentication and determine:

- The CDB name, current incarnation, open mode, and log mode.
- The name and open mode of `FREEPDB1`.
- The container ID for `FREEPDB1`.
- The affected tablespace and exact datafile number/name.
- Whether the affected file is offline and whether Oracle reports that it needs media recovery.

Useful container-aware sources include `V$DATABASE`, `V$PDBS`, `CDB_DATA_FILES`, `V$DATAFILE`, `V$TABLESPACE`, `V$RECOVER_FILE`, and their container identifiers. Explicitly show which rows belong to `FREEPDB1`; do not infer PDB ownership from the pathname alone.

> [!Tip]
> A Session Manager shell commonly starts as `ssm-user`. Use the approved `sudo` path to become the Oracle software owner before using SQL*Plus or RMAN. Record `show con_name` or equivalent container evidence whenever the active container affects interpretation of a query.

### 3.2 Correlate four evidence sources

Your diagnosis must correlate all four of these sources:

1. **Oracle views:** file status, tablespace status, PDB open mode, and media-recovery requirement.
2. **Oracle diagnostic evidence:** relevant alert-log or ADR entries that show the inaccessible/missing file condition. Use `adrci` or the configured diagnostic destination; do not edit the log.
3. **RMAN repository:** `REPORT SCHEMA`, backup listings for the affected file/PDB, and a non-destructive preview or equivalent evidence showing that RMAN can locate a usable backup and redo path.
4. **Filesystem:** confirm that the recorded datafile path is absent while unrelated Oracle datafiles and `/u02/backup` remain present. Do not create an empty placeholder at the missing path.

Before recovery, answer these questions in `$HOME/lab-evidence/exercise-02/rationale.md`:

- Why does the evidence identify a single `FREEPDB1` training datafile rather than a CDB-wide failure?
- Why is targeted PDB/datafile recovery preferable to a whole-CDB restore in this incident?
- Which backup and redo evidence supports recovery of this file through the current point in time?
- What is the minimum service disruption required for your chosen method?

<question id="3"></question>

## Task 4 — Perform scoped RMAN restore and recovery

Design and run the RMAN sequence that satisfies all of these requirements:

1. Connect to the correct target database and make the container context explicit.
2. Confirm the affected datafile identifier against the injection output and Oracle metadata immediately before the restore.
3. Place only the necessary `FREEPDB1` datafile or tablespace into the state required by your recovery approach.
4. Restore only the missing training datafile from a usable backup in `/u02/backup`.
5. Recover only that datafile by applying the required archived redo.
6. Return the affected file/tablespace online.
7. Ensure `FREEPDB1` is open in its expected mode and save its state if your recovery workflow changed it.

Spool RMAN output to:

`$HOME/lab-evidence/exercise-02/rman-recovery.log`

Your log must make the targeted scope clear. A command that restores the entire database or all of `FREEPDB1` does not satisfy the objective when only the recorded training datafile is missing.

> [!Caution]
> Stop and recheck the current container, datafile number, and full datafile path before executing a mutating RMAN or SQL command. Do not substitute a similarly named file from `CDB$ROOT` or another tablespace.

## Task 5 — Prove recovery and data integrity

Create `$HOME/lab-evidence/exercise-02/integrity.txt` and capture evidence for every check below:

1. `FREEPDB1` is open in the expected read/write mode.
2. The recovered file exists at the recorded path and is an Oracle datafile, not an empty replacement.
3. The recovered training datafile and its tablespace are online.
4. All required `FREEPDB1` datafiles are present and online.
5. `V$RECOVER_FILE`, interpreted in the correct container context, shows that no required file still needs media recovery.
6. A final RMAN schema/report check recognizes the recovered datafile.
7. The seeded training objects are queryable in `FREEPDB1`.
8. Row counts and checksum markers match the pre-loss values captured by the injection script.
9. Previously committed data outside the recovered training file remains available.
10. The CDB incarnation has not changed during this exercise.

Use the supplied expected-result material under `/opt/lab` and the protected injection record as read-only references. Do not copy a recorded checksum into a fabricated result; retain the live query output that produced the matching value.

Finish the terminal transcript when all evidence has been saved:

```bash
exit
```

## Task 6 — Validate the outcome

Before running validation, confirm that these files contain your actual output:

- `$HOME/lab-evidence/exercise-02/session.typescript`
- `$HOME/lab-evidence/exercise-02/diagnosis.txt`
- `$HOME/lab-evidence/exercise-02/rationale.md`
- `$HOME/lab-evidence/exercise-02/rman-recovery.log`
- `$HOME/lab-evidence/exercise-02/integrity.txt`

Then run the Exercise 2 validation from the lab interface.

<validation step="2"></validation>

The validation checks the protected injection identity, `FREEPDB1` open state, required datafile presence/status, absence of outstanding media recovery, row/checksum markers, and evidence of targeted datafile recovery rather than whole-CDB replacement.

## Completion criteria

You have completed this exercise when:

- The deliberately removed `FREEPDB1` training datafile has been restored and recovered through RMAN.
- Recovery was limited to the affected datafile/PDB scope.
- The affected tablespace and all required `FREEPDB1` datafiles are online.
- No required file needs media recovery.
- The PDB opens correctly and the live row/checksum results match the pre-loss markers.
- The database incarnation is unchanged and no committed data was lost.
- Validation 2 succeeds and your evidence files remain available for review.
