# Exercise 1 — Build a backup chain and perform whole-CDB SCN recovery

**Estimated time:** 35 minutes  
**Scope:** Oracle CDB level 0 and level 1 backups, archived redo, whole-CDB point-in-time recovery, `RESETLOGS`, and post-recovery protection

## Scenario

A failed application release has introduced a committed bad transaction into `FREEPDB1`. Before the failure is injected, you must establish and inspect a recoverable RMAN backup chain. You will then run the supplied fault-injection script, recover the **entire CDB** to the recorded system change number (SCN), and prove that the unwanted transaction is absent while valid earlier data remains.

This is a task-based assessment. The required outcomes, constraints, evidence locations, and checks are provided, but you must choose the appropriate Oracle SQL, RMAN, and Linux commands.

## Objectives

In this exercise, you will:

- Verify that the CDB, `FREEPDB1`, archive logging, RMAN configuration, and `/u02/backup` are ready.
- Create an RMAN level 0 CDB backup with archived redo and control-file/SPFILE protection.
- Apply the supplied workload change and create a level 1 incremental backup.
- Inspect RMAN metadata and retain evidence of the backup chain.
- Run `/opt/lab/inject-ex1.sh` and record its recovery target SCN and bad-transaction marker.
- Perform whole-CDB point-in-time recovery to that SCN.
- Open the CDB with `RESETLOGS`, restore the required `FREEPDB1` open state, and verify the data outcome.
- Record the new database incarnation and create a post-`RESETLOGS` CDB backup.

## Task 1 — Sign in and connect to the learner VM

1. Open the AWS sign-in page: <inject key="AwsConsoleUrl"></inject>
2. Sign in with these assigned credentials:
   - **User name:** <inject key="IamUserName"></inject>
   - **Password:** <inject key="IamUserPassword"></inject>
3. Confirm that the console is showing AWS account <inject key="AwsAccountId"></inject> and Region <inject key="AwsRegion"></inject>.
4. Open **CloudFormation** and choose **Stacks**. Find the stack associated with deployment <inject key="DeploymentID"></inject>.
5. On the stack's **Outputs** tab, note the EC2 instance ID or SSM target output.
6. Open **EC2** > **Instances**, select that instance, and choose **Connect**.
7. On the **Session Manager** tab, choose **Connect**.

> [!Note]
> AWS documents this console path as **EC2 > Instances > select the instance > Connect > Session Manager > Connect**. Session Manager requires the node to be managed by Systems Manager and the signed-in identity to have session permissions. The lab provisions and verifies SSM Agent and attaches the required instance role during bootstrap.

8. Confirm that bootstrap completed before changing the database:

```bash
sudo test -f /opt/lab/.ready && echo "Lab is ready" || echo "Bootstrap is not complete"
sudo systemctl is-active amazon-ssm-agent
```

Do not continue unless the readiness marker exists and the agent is active. Keep this Session Manager shell open throughout the exercise.

## Task 2 — Establish the pre-change baseline

Create an evidence directory for this exercise if the deployment has not already created it, and review the available assets:

```bash
sudo install -d -o oracle -g oinstall -m 0750 /opt/lab/evidence/ex1
sudo find /opt/lab -maxdepth 2 -type f -printf '%M %u:%g %p\n' | sort
sudo ls -ld /u02/backup /opt/lab/evidence/ex1
lsblk -f
findmnt /u02/backup
df -h /u02/backup
```

Save your observations in `/opt/lab/evidence/ex1/preflight.txt`. Your evidence must show all of the following:

- The database role and open mode are appropriate for taking the planned backups.
- `FREEPDB1` is open and its saved state is understood.
- The database is in `ARCHIVELOG` mode.
- RMAN control-file autobackup and disk-channel settings protect backup material under `/u02/backup`.
- `/u02/backup` is a separate mounted filesystem, has sufficient free capacity, and is writable by the Oracle software owner.
- The expected data is in `FREEPDB1`, not `CDB$ROOT`.

> [!Important]
> Stop and investigate any failed preflight check. Do not change the database identifier, recreate the database, disable archive logging, move backup files to the root volume, or alter the protected injection scripts.

## Task 3 — Create and inspect the RMAN backup chain

1. As the Oracle software owner, create a **level 0 incremental backup of the whole CDB** under `/u02/backup`.
2. Include sufficient archived redo to make the backup recoverable. Ensure that the control file and SPFILE are protected in accordance with the configured autobackup policy.
3. Run the supplied, exercise-tagged `FREEPDB1` workload-change asset found under `/opt/lab`. Review it before execution and confirm that it connects to `FREEPDB1` rather than `CDB$ROOT`.
4. Force or capture the redo needed after the workload change, then create a **level 1 incremental backup** of the whole CDB.
5. Inspect the RMAN repository and physical files. Save readable evidence to `/opt/lab/evidence/ex1/backup-chain.txt`.

Your evidence should make it possible to identify:

- Completion time and status of both backup jobs.
- The level 0 and level 1 datafile backup sets and pieces.
- Archived redo coverage between the backups and through the required recovery window.
- Control-file and SPFILE protection.
- The physical backup-piece locations on `/u02/backup`.

Do not delete archive logs merely to reduce disk use, and do not mark missing backups as available. If an RMAN command reports an error, preserve the output, determine the cause, and correct the backup operation before proceeding.

<question id="1"/>

## Task 4 — Inject and verify the unwanted transaction

> [!Warning]
> Run the injection only after you have inspected a usable level 0/level 1 chain. The script is intentionally learner-run; deployment does not run it for you. Do not edit it or invoke it more than once.

1. Confirm the script is owned by root and is not world-writable:

```bash
sudo stat -c '%A %U:%G %n' /opt/lab/inject-ex1.sh
```

2. Run the supplied injection:

```bash
sudo /opt/lab/inject-ex1.sh
```

3. Immediately copy the emitted **target SCN**, UTC timestamp, and unique bad-transaction marker into `/opt/lab/evidence/ex1/injection-target.txt`.
4. Locate the protected injection record and compare it with the values you copied. Do not modify that record.
5. Connect explicitly to `FREEPDB1` and prove that the bad-transaction marker is currently visible and committed. Also capture the provided pre-target row/checksum marker so that you can prove valid earlier data survives recovery.

Before continuing, state the recovery boundary in your notes: the operation is **whole-CDB PITR to the recorded SCN**, not PDB-only PITR and not a targeted datafile restore.

## Task 5 — Recover the entire CDB to the target SCN

Plan and carry out the recovery using RMAN and SQL*Plus. Your procedure must satisfy these constraints:

- Shut down the CDB cleanly where possible and place it in the state required for whole-database restore and recovery.
- Use the SCN emitted by `/opt/lab/inject-ex1.sh` as the recovery boundary.
- Restore and recover the **whole CDB**, using the level 0/level 1 chain and required archived redo.
- Do not substitute a PDB-only recovery, table-level repair, flashback operation, manual row deletion, schema recreation, or database recreation.
- Review RMAN's selected backup pieces and recovery messages. Resolve errors rather than bypassing them.
- Open the recovered CDB with `RESETLOGS` only after incomplete recovery has completed successfully.
- Open `FREEPDB1` and save its required open state after the CDB is available.

Capture the terminal transcript or equivalent RMAN and SQL evidence in `/opt/lab/evidence/ex1/pitr.txt`. The evidence must show the requested target SCN, whole-CDB scope, successful restore/recovery, and the `RESETLOGS` open.

> [!Tip]
> Before issuing any destructive or state-changing command, verify your current Oracle environment, database state, container, and recovery target. A correct command issued against the wrong container or at the wrong stage does not meet the objective.

## Task 6 — Prove the recovery outcome

After the database is open:

1. Verify the CDB is open in the expected mode and `FREEPDB1` is open read/write.
2. Connect explicitly to `FREEPDB1`.
3. Prove that the unique bad-transaction marker is absent.
4. Prove that the supplied pre-target row/checksum marker remains correct.
5. Inspect the database incarnation history and identify the current incarnation created by `RESETLOGS`.
6. Save these results to `/opt/lab/evidence/ex1/recovery-outcome.txt`.

A successful startup alone is insufficient. The data checks must demonstrate that recovery reached the intended logical point.

<question id="2"/>

## Task 7 — Protect the new incarnation

Create a new, usable CDB backup after `RESETLOGS`, including the archived redo and control-file/SPFILE protection required by the lab's RMAN policy. Do not assume that the pre-resetlogs chain is an adequate operational baseline for all future restore work.

Save repository and physical-file evidence to `/opt/lab/evidence/ex1/post-resetlogs-backup.txt`. Your evidence must correlate the backup with the current incarnation and show that its pieces exist under `/u02/backup`.

In two or three sentences in the same file, explain:

- How `OPEN RESETLOGS` changes the database incarnation and redo stream.
- Why taking a prompt backup of the new incarnation reduces recovery risk and simplifies subsequent work, including Exercise 2.

## Review and validation

Before running validation, confirm that your evidence directory contains at least:

```text
/opt/lab/evidence/ex1/preflight.txt
/opt/lab/evidence/ex1/backup-chain.txt
/opt/lab/evidence/ex1/injection-target.txt
/opt/lab/evidence/ex1/pitr.txt
/opt/lab/evidence/ex1/recovery-outcome.txt
/opt/lab/evidence/ex1/post-resetlogs-backup.txt
```

Your completed environment should satisfy these outcome checks:

- A valid level 0 and level 1 whole-CDB backup chain exists, with archived redo and control-file/SPFILE protection.
- The protected injection record exists and has not been modified.
- Whole-CDB PITR used the injected target SCN.
- The CDB was opened with `RESETLOGS`, and the new incarnation is recorded.
- `FREEPDB1` is open, the bad transaction is absent, and pre-target data remains correct.
- A usable CDB backup exists in the current post-`RESETLOGS` incarnation.
- Backup pieces remain on the separate `/u02/backup` filesystem.

<validation step="1"/>

## Completion

You have established an RMAN incremental backup chain, recovered the complete container database to a known SCN, verified the `FREEPDB1` business outcome, and protected the new incarnation. Leave the CDB and `FREEPDB1` open and healthy for Exercise 2.