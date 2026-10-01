# Exercise 2 — Recover the `FREEPDB1` training datafile

**Estimated time:** 30 minutes  
**Assessment weight:** 25%

A dedicated training datafile in `FREEPDB1` will be deliberately removed from the EC2 host path beneath `/u01/oradata`. Because that host directory is bind-mounted at `/opt/oracle/oradata` in the Oracle container, the file will also become unavailable to Oracle. Diagnose the mapping and use RMAN inside the still-running container to restore and recover only the affected datafile.

Exercise 2 is independently attemptable and independently scored. Run `/opt/lab/inject-ex2.sh` regardless of whether you completed Exercise 1. The injector does not require an Exercise 1 state file or a successful Exercise 1 recovery.

> [!Important]
> This is a task-based assessment. You receive objectives, constraints, evidence locations, and outcome checks—not a completed recovery command sequence.

## Objectives

In this exercise, you will:

- Connect to the EC2 managed node through AWS Systems Manager Session Manager.
- Dynamically identify the one running `oracle-free` container without hardcoding its container ID.
- Run `/opt/lab/inject-ex2.sh`, which establishes an independent recovery safeguard when required and then safely removes only the training datafile from its host bind-mount path.
- Correlate the host path, container path, `FREEPDB1` metadata, diagnostic evidence, and RMAN repository.
- Restore and recover only the missing `FREEPDB1` training datafile from `/u02/backup`.
- Return the PDB, tablespace, and datafile to the expected state and prove data integrity.

## Independent-injection safeguard

`/opt/lab/inject-ex2.sh` requires only general lab readiness, mounted backup storage, and exactly one healthy running `oracle-free` container.

When you run it, the script:

1. Continues even if Exercise 1 is incomplete, unsuccessful, or has no state file.
2. If Exercise 1 evidence exists but the script cannot prove successful PITR and `RESETLOGS`, writes a warning to stderr and the protected injection audit log, then continues.
3. Determines the current database incarnation and resetlogs SCN.
4. Checks RMAN metadata and physical backup pieces for a usable whole-CDB level 0 backup in that **current incarnation**.
5. If no such backup is usable, creates and verifies a fresh level 0 whole-CDB safety backup, archived redo, and control-file/SPFILE protection before injecting the file loss. Injection aborts if this safeguard cannot be completed.
6. Records whether the usable backup was learner-created or injector-created, then captures the training datafile identity and checksum before removing only its safely mapped host file.

> [!Important]
> An injector-created safety backup exists only to keep Exercise 2 recoverable. It earns **no Exercise 1 credit** and does not prove that you created Exercise 1's level 0/level 1 chain, performed whole-CDB PITR, opened with `RESETLOGS`, or made the required post-resetlogs backup. Exercise 1 and Exercise 2 validators score those outcomes separately.

## Assessment constraints

You must observe all of these constraints:

- Run the supplied fault-injection script exactly once unless it reports that the fault is already active.
- Do not edit `/opt/lab/inject-ex2.sh`, its protected audit log, or protected incident state under `/opt/lab/state`.
- Do not run `rm`, `mv`, `touch`, `truncate`, or `dd` against Oracle files. The supplied script performs the controlled host-path removal.
- Do not stop, restart, remove, rename, or recreate the `oracle-free` container.
- Do not hardcode a Docker container ID. Resolve the running container again after any database state transition.
- Do not manually recreate the missing datafile or reseed the training rows.
- Do not perform a whole-CDB restore, whole-CDB point-in-time recovery, or `OPEN RESETLOGS`.
- Do not restore or recover root/system files, `SYSTEM`, `SYSAUX`, undo, temp files, control files, redo logs, or unrelated application datafiles.
- Retain authentic SQL and RMAN output. Fabricated evidence or hardcoded success does not receive credit.

## Task 1 — Sign in and connect through Session Manager

1. Open the AWS sign-in URL: <inject key="AwsConsoleUrl"></inject>
2. Sign in with:
   - **IAM user name:** <inject key="IamUserName"></inject>
   - **Password:** <inject key="IamUserPassword"></inject>
3. Confirm that the console shows:
   - **AWS account:** <inject key="AwsAccountId"></inject>
   - **Region:** <inject key="AwsRegion"></inject>
4. Use deployment identifier <inject key="DeploymentID"></inject> to distinguish this lab's stack and instance from other resources.
5. In the AWS Management Console, open **CloudFormation**, choose **Stacks**, and select the lab stack associated with the deployment identifier.
6. Open **Outputs** and copy the EC2 instance ID from the instance/SSM target output.
7. Open **EC2**, choose **Instances**, and select the instance whose ID matches the stack output.
8. Choose **Connect**, select the **Session Manager** tab, and choose **Connect**.

> [!Note]
> Session Manager requires a managed node with SSM Agent connectivity and suitable instance permissions. The lab instance profile includes `AmazonSSMManagedInstanceCore`, which provides the instance-side core permissions, and bootstrap verifies and starts SSM Agent. If the Session Manager tab is unavailable, first recheck the account, Region, instance ID, instance status, and lab readiness. Do not replace the instance profile or reinstall the agent.

Session Manager supports a browser shell through the Amazon EC2 or Systems Manager console. If you instead use `aws ssm start-session` from a separate computer, that computer must also have the Session Manager plugin. Supply the instance ID from the stack output and explicitly select the lab Region.

After the shell opens, verify that you reached the intended host:

```bash
hostname
sudo test -f /opt/lab/.ready && echo "Lab bootstrap is ready"
sudo systemctl is-active amazon-ssm-agent
```

## Task 2 — Create evidence storage and discover the container

1. Create a learner-owned host evidence directory and begin a transcript:

   ```bash
   mkdir -p "$HOME/lab-evidence/exercise-02"
   script -a "$HOME/lab-evidence/exercise-02/session.typescript"
   date -u
   ```

2. Dynamically discover the intended running container. The first command gathers all matches; the count check prevents an ambiguous target; the final command follows the lab-wide discovery contract:

   ```bash
   MATCHES=$(sudo docker ps --filter name=oracle-free --filter status=running -q)
   test "$(printf '%s\n' "$MATCHES" | sed '/^$/d' | wc -l)" -eq 1 || {
     echo "Expected exactly one running oracle-free container" >&2
     exit 1
   }
   CONTAINER_ID=$(sudo docker ps --filter name=oracle-free --filter status=running -q | head -n 1)
   export CONTAINER_ID
   sudo docker inspect --format '{{.Name}} {{.State.Status}} {{.Config.Image}}' "$CONTAINER_ID"
   ```

3. Inspect the bind mounts and save the result:

   ```bash
   sudo docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
     "$CONTAINER_ID" | tee "$HOME/lab-evidence/exercise-02/docker-mounts.txt"
   ```

4. Confirm that the output contains these mappings:

   - Host `/u01/oradata` to container `/opt/oracle/oradata`
   - Host `/u02/backup` to container `/u02/backup`

> [!Important]
> `/u01/oradata` is on the EC2 root EBS volume and contains persistent Oracle data. `/u02/backup` is the separate encrypted 30 GiB gp3 backup volume. Do not confuse the source data path with the RMAN backup destination.

## Task 3 — Inject and inspect the controlled file-loss incident

1. Do **not** test for or attempt to repair Exercise 1 first. Exercise 2 is intentionally independent.
2. Run the protected script and capture both standard output and warnings from standard error:

   ```bash
   sudo /opt/lab/inject-ex2.sh 2>&1 | tee "$HOME/lab-evidence/exercise-02/injection-output.txt"
   ```

   Allow the script to finish. Creating and verifying a current-incarnation level 0 safety backup can take several minutes.

3. Interpret the result:

   - A warning about missing or unproven Exercise 1 PITR/`RESETLOGS` is informational for Exercise 2; the injector logs it and continues.
   - A message that a current-incarnation level 0 already exists means that backup was accepted as the recovery safeguard.
   - A message that the injector created a safety backup means no usable current-incarnation level 0 was found. This permits Exercise 2 but earns no Exercise 1 credit.
   - A fatal safety-backup error stops injection; do not remove a datafile manually.

4. Read the protected state without changing it:

   ```bash
   sudo cat /opt/lab/state/ex2.env | tee "$HOME/lab-evidence/exercise-02/incident-state.txt"
   sudo stat /opt/lab/state/ex2.env
   ```

5. Record the datafile number, container path, pre-loss checksum, current incarnation/resetlogs evidence, backup provenance, and UTC timestamp reported by the script/state.
6. Derive the host path only by applying the verified bind mapping:

   - Remove the container prefix `/opt/oracle/oradata`.
   - Append the remaining suffix to host prefix `/u01/oradata`.
   - Reject the result unless its canonical parent remains beneath `/u01/oradata`.

7. Prove the incident from both sides of the bind mount:

   - The recorded container path is beneath `/opt/oracle/oradata`.
   - Its corresponding host path is beneath `/u01/oradata`.
   - The targeted host file is absent.
   - Other Oracle files beneath `/u01/oradata` remain present.
   - `/u02/backup` remains mounted and contains RMAN backup material.

> [!Caution]
> Do not repeat the removal. If the script reports an already-active incident, diagnose the existing state. If it aborts because it cannot establish the safety backup or safely identify the target, do not bypass its checks.

## Task 4 — Diagnose the `FREEPDB1` failure

Save diagnosis output in `$HOME/lab-evidence/exercise-02/diagnosis.txt` or ensure it is visible in your session transcript.

### 4.1 Correlate Oracle ownership and file state

Re-resolve the container, then open SQL*Plus inside it:

```bash
CONTAINER_ID=$(sudo docker ps --filter name=oracle-free --filter status=running -q | head -n 1)
sudo docker exec -it "$CONTAINER_ID" sqlplus / as sysdba
```

Use container-aware Oracle metadata to establish:

- CDB identity, open mode, log mode, current SCN, and current incarnation/resetlogs identity.
- `FREEPDB1` container ID and open mode.
- The training tablespace name and exact datafile number/name.
- The datafile's status and whether it requires media recovery.
- Explicit proof that the file belongs to `FREEPDB1`, rather than an inference based only on its path.

Useful sources include `V$DATABASE`, `V$PDBS`, `V$CONTAINERS`, `CDB_DATA_FILES`, `V$DATAFILE`, `V$TABLESPACE`, and `V$RECOVER_FILE`. Record the active container with `SHOW CON_NAME` whenever context affects a query.

### 4.2 Correlate four evidence sources

Your diagnosis must include all four sources:

1. **Oracle views:** PDB open mode, tablespace/file status, and media-recovery requirement.
2. **Oracle diagnostics:** relevant alert-log or ADR entries for the missing/inaccessible file. Read the log inside the container; do not edit it.
3. **RMAN repository:** `REPORT SCHEMA`, backup metadata for the recorded file, and non-destructive preview or equivalent evidence that a usable backup and redo path exist in the current incarnation.
4. **Host and container filesystems:** the exact bind mapping, absence of only the targeted host file beneath `/u01/oradata`, and availability of backup pieces beneath `/u02/backup`.

Create `$HOME/lab-evidence/exercise-02/rationale.md` and answer:

- Why does the evidence identify a single `FREEPDB1` training datafile failure?
- Why is targeted datafile recovery preferable to restoring the entire CDB?
- Which backup pieces and redo can bring the file to the required point?
- What is the minimum service disruption for your selected method?
- If the injector created the safety backup, why does that not satisfy Exercise 1's independently scored tasks?

<question id="3"></question>

## Task 5 — Restore and recover only the targeted datafile

1. Confirm the Docker container is still running and dynamically resolve its ID again.
2. Start RMAN **inside the running container** and write the RMAN transcript to the backup bind mount, which is visible at the same path on the host and in the container:

   ```bash
   CONTAINER_ID=$(sudo docker ps --filter name=oracle-free --filter status=running -q | head -n 1)
   sudo docker exec -it "$CONTAINER_ID" rman target / \
     log=/u02/backup/logs/ex2-rman-recovery.log append
   ```

3. Design and run a recovery sequence that:

   - Makes the intended `FREEPDB1` scope explicit.
   - Reconfirms the recorded datafile number/name immediately before mutation.
   - Places only the required training file or tablespace in the state needed by your method.
   - Restores only that datafile from `/u02/backup`.
   - Recovers only that datafile with the required archived redo.
   - Returns the file and training tablespace online.
   - Leaves `FREEPDB1` open read/write and saves its open state if your workflow changed it.

4. After any Oracle shutdown, mount, or open transition, verify that the Docker container itself was never stopped:

   ```bash
   sudo docker ps --filter name=oracle-free --filter status=running
   ```

> [!Important]
> Oracle instance state and Docker container state are different. Database operations occur inside the long-running container. Do not use `docker stop`, `docker restart`, or `docker rm` as part of recovery.

Your RMAN log must clearly show targeted `RESTORE DATAFILE` and `RECOVER DATAFILE` work. Restoring the entire database or all of `FREEPDB1` does not meet the objective when only one training datafile was removed.

## Task 6 — Prove recovery and integrity

Capture live results in `$HOME/lab-evidence/exercise-02/integrity.txt`. Prove all of the following:

1. Exactly one intended `oracle-free` container is running.
2. The recovered container path maps back to the original safe host path beneath `/u01/oradata`.
3. The file exists at that host path and is not an empty placeholder.
4. `FREEPDB1` is open read/write.
5. The training tablespace and recovered datafile are online/available.
6. No required file remains in `V$RECOVER_FILE` in the correct container context.
7. RMAN recognizes the recovered file and no targeted recovery remains pending.
8. The seeded training objects are queryable in `FREEPDB1`.
9. Live row-count and checksum results match the pre-loss values in the protected incident record.
10. Unrelated committed data remains available.
11. The CDB incarnation/resetlogs identity is unchanged from the injection record.
12. `/u02/backup/logs/ex2-rman-recovery.log` contains the authentic targeted recovery transcript.

Copy the RMAN log into your learner evidence directory while retaining the original:

```bash
sudo cp /u02/backup/logs/ex2-rman-recovery.log \
  "$HOME/lab-evidence/exercise-02/rman-recovery.log"
sudo chown "$(id -u):$(id -g)" "$HOME/lab-evidence/exercise-02/rman-recovery.log"
exit
```

The final `exit` ends the `script` transcript. Do not copy a stored checksum into fabricated output; retain the SQL query that produced the matching live result.

## Task 7 — Validate the outcome

Confirm that these evidence files contain actual output:

- `$HOME/lab-evidence/exercise-02/session.typescript`
- `$HOME/lab-evidence/exercise-02/docker-mounts.txt`
- `$HOME/lab-evidence/exercise-02/injection-output.txt`
- `$HOME/lab-evidence/exercise-02/incident-state.txt`
- `$HOME/lab-evidence/exercise-02/diagnosis.txt`
- `$HOME/lab-evidence/exercise-02/rationale.md`
- `$HOME/lab-evidence/exercise-02/rman-recovery.log`
- `$HOME/lab-evidence/exercise-02/integrity.txt`

Then run Exercise 2 validation from the lab interface.

<validation step="2"></validation>

Validation 2 is independent of Validation 1. It can pass when Exercise 1 failed or was never completed, and it accepts recovery based on either a pre-existing usable current-incarnation level 0 or the safety level 0 created by `/opt/lab/inject-ex2.sh`. That acceptance applies only to Exercise 2 recovery; it does not award any Exercise 1 backup/PITR points.

The validator dynamically discovers this deployment's running EC2 instance and uses SSM Run Command for read-only host, container, and Oracle checks. Its remote payload dynamically resolves exactly one running `oracle-free` container. It verifies the protected incident identity and safe `/u01/oradata` mapping, targeted RMAN restore/recovery evidence, an online `FREEPDB1` and training datafile, no pending media recovery, matching live checksum, and an unchanged resetlogs identity. It rejects whole-CDB/PDB replacement and `OPEN RESETLOGS` evidence for this task.

## Completion criteria

You have completed this exercise when:

- The deliberately removed host file beneath `/u01/oradata` has been restored to the corresponding `/opt/oracle/oradata` container path through RMAN.
- Restore and recovery were limited to the recorded `FREEPDB1` training datafile.
- The `oracle-free` container remained running and was dynamically discovered throughout the task.
- `FREEPDB1`, the training tablespace, and all required datafiles are online, with no outstanding media recovery.
- Live row-count/checksum evidence matches the pre-loss markers and the CDB incarnation is unchanged.
- Validation 2 succeeds independently of Exercise 1, and your evidence remains available for review.
