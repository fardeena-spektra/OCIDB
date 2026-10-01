# Exercise 1 — Build a backup chain and perform whole-CDB SCN recovery

**Estimated time:** 35 minutes  
**Scope:** Docker-aware Oracle CDB backup and recovery, RMAN level 0/1 backups, archived redo, SCN point-in-time recovery, `RESETLOGS`, and post-recovery protection

## Scenario

A failed release introduces a committed bad transaction into `FREEPDB1`. You must first establish a usable RMAN backup chain. You will then run the supplied injection, recover the **whole CDB** to the recorded system change number (SCN), and prove that the unwanted transaction is absent while valid earlier data remains.

Oracle Database Free runs inside the long-lived Docker container named `oracle-free`. Database shutdown, mount, restore, recovery, and open operations affect the Oracle instance **inside** that container. They must not stop or remove the container itself.

This is a task-based assessment. The commands below establish the required Docker transport and safety checks; you remain responsible for interpreting Oracle state, selecting the correct recovery target, reviewing RMAN output, and proving the outcome.

## Objectives

In this exercise, you will:

- Verify the host mounts, Docker service, dynamically discovered `oracle-free` container, CDB/PDB state, and RMAN configuration.
- Create a whole-CDB level 0 backup with archived redo and control-file/SPFILE protection.
- Apply the supplied `FREEPDB1` workload change and create a level 1 backup.
- Run `/opt/lab/inject-ex1.sh` and preserve its target SCN and marker.
- Shut down, mount, restore, and recover the whole CDB inside the still-running container.
- Open the CDB with `RESETLOGS`, reopen/save `FREEPDB1`, and prove the container remained running.
- Verify the logical data outcome, record the new incarnation, and create a post-`RESETLOGS` backup.

## Task 1 — Sign in and connect with Session Manager

1. Open the AWS sign-in page: <inject key="AwsConsoleUrl"></inject>
2. Sign in with:
   - **User name:** <inject key="IamUserName"></inject>
   - **Password:** <inject key="IamUserPassword"></inject>
3. Confirm account <inject key="AwsAccountId"></inject> and Region <inject key="AwsRegion"></inject>.
4. Open **CloudFormation** > **Stacks**, and find the stack for deployment <inject key="DeploymentID"></inject>.
5. On **Outputs**, note the instance ID or SSM target.
6. Open **EC2** > **Instances**, select the lab instance, and choose **Connect**.
7. For the connection method, choose **Session Manager**, and then choose **Connect**.

AWS documents this path as **EC2 > Instances > select instance > Connect > Session Manager > Connect**. The instance must be a Systems Manager managed node, and your identity must have permission to start the session. See [Start a session](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html).

8. Verify bootstrap readiness and the services used by this exercise:

```bash
sudo test -f /opt/lab/.ready && echo "Lab is ready" || echo "Bootstrap is not complete"
sudo systemctl is-active amazon-ssm-agent
sudo systemctl is-active docker
```

Do not continue unless the readiness marker exists and both services are active.

## Task 2 — Discover the running database container safely

Do not copy a container ID from an earlier command and assume it remains valid. Define this helper in your Session Manager shell. It filters for running containers and then requires exactly one result whose name is exactly `oracle-free`:

```bash
resolve_container() {
  local rows
  mapfile -t rows < <(
    sudo docker ps \
      --filter name=oracle-free \
      --filter status=running \
      --format '{{.ID}} {{.Names}}' |
      awk '$2 == "oracle-free" {print $1}'
  )

  if (( ${#rows[@]} != 1 )); then
    echo "Expected exactly one running container named oracle-free; found ${#rows[@]}." >&2
    return 1
  fi

  CONTAINER_ID="${rows[0]}"
  export CONTAINER_ID
}

resolve_container
sudo docker inspect \
  --format 'name={{.Name}} id={{.Id}} status={{.State.Status}} running={{.State.Running}}' \
  "$CONTAINER_ID"
```

Expected evidence includes `name=/oracle-free`, `status=running`, and `running=true`. Stop if discovery is ambiguous. Do not use `docker stop`, `docker restart`, `docker rm`, or `docker compose down` anywhere in this exercise.

> [!Note]
> For an interactive session, the supported patterns are `sudo docker exec -it "$CONTAINER_ID" rman target /` and `sudo docker exec -it "$CONTAINER_ID" bash -lc 'sqlplus / as sysdba'`. Noninteractive examples below use `-i` so that here-documents can be captured as evidence.

## Task 3 — Establish and preserve the baseline

1. Prepare the host evidence directory without changing the protected injection state:

```bash
sudo install -d -m 0770 /opt/lab/evidence/ex1
findmnt /u02/backup
findmnt /u01/oradata || true
df -h /u01/oradata /u02/backup
sudo stat -c '%u:%g %a %n' /u01/oradata /u02/backup
sudo docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "$CONTAINER_ID"
```

The expected design uses persistent Oracle data under `/u01/oradata` and a separate backup filesystem mounted at `/u02/backup`. Both paths use numeric owner UID/GID `54321`. The container must expose the Oracle data mount and `/u02/backup`.

2. Query the CDB through the dynamically resolved container:

```bash
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba' <<'SQL' |
  sudo tee /opt/lab/evidence/ex1/preflight-database.txt
whenever sqlerror exit failure
set lines 200 pages 100
show con_name
select name, db_unique_name, open_mode, database_role, log_mode,
       current_scn, resetlogs_change#
from v$database;
select name, open_mode, restricted from v$pdbs order by con_id;
select con_name, instance_name, status from v$instance;
exit
SQL
```

3. Inspect RMAN configuration from inside the same running container:

```bash
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'rman target /' <<'RMAN' |
  sudo tee /opt/lab/evidence/ex1/preflight-rman.txt
SHOW ALL;
LIST INCARNATION OF DATABASE;
EXIT;
RMAN
```

Your baseline must establish `ARCHIVELOG`, a suitable CDB/PDB open state, control-file autobackup, and disk output under `/u02/backup`. Resolve any failed preflight check before taking backups.

## Task 4 — Create and inspect the backup chain

1. Use RMAN **inside** the container to create a tagged level 0 whole-CDB backup, archived-redo protection, and explicit control-file/SPFILE protection. The configured disk channel determines the physical format under `/u02/backup`.

```bash
set -o pipefail
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'rman target /' <<'RMAN' 2>&1 |
  sudo tee /opt/lab/evidence/ex1/level0-rman.txt
RUN {
  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
  BACKUP INCREMENTAL LEVEL 0 DATABASE TAG 'CL_EX1_L0';
  BACKUP ARCHIVELOG ALL NOT BACKED UP 1 TIMES TAG 'CL_EX1_L0_ARC';
  BACKUP CURRENT CONTROLFILE TAG 'CL_EX1_L0_CTL';
  BACKUP SPFILE TAG 'CL_EX1_L0_SPFILE';
}
LIST BACKUP SUMMARY;
EXIT;
RMAN
```

Review the transcript for RMAN errors and completed pieces. Do not proceed merely because the pipeline created a text file.

2. Review the supplied workload asset, confirm that it changes `FREEPDB1`, and then feed that exact host file to SQL*Plus inside the container:

```bash
sudo sed -n '1,220p' /opt/lab/workload/change.sql
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba' \
  < /opt/lab/workload/change.sql 2>&1 |
  sudo tee /opt/lab/evidence/ex1/workload-change.txt
```

3. Create the whole-CDB level 1 backup and capture redo generated through this point:

```bash
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'rman target /' <<'RMAN' 2>&1 |
  sudo tee /opt/lab/evidence/ex1/level1-rman.txt
RUN {
  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
  BACKUP INCREMENTAL LEVEL 1 DATABASE TAG 'CL_EX1_L1';
  BACKUP ARCHIVELOG ALL NOT BACKED UP 1 TIMES TAG 'CL_EX1_L1_ARC';
}
LIST BACKUP SUMMARY;
LIST BACKUP OF DATABASE;
LIST BACKUP OF ARCHIVELOG ALL;
EXIT;
RMAN
```

4. Correlate RMAN metadata with physical files:

```bash
sudo find /u02/backup -xdev -type f -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' |
  sort | sudo tee /opt/lab/evidence/ex1/backup-files.txt
```

Your evidence must identify completed level 0 and level 1 datafile backups, archived redo covering the recovery window, control-file/SPFILE protection, and physical pieces under `/u02/backup`.

<question id="1"/>

## Task 5 — Inject and record the recovery boundary

> [!Warning]
> Run the injection exactly once, only after confirming a usable backup chain. Do not edit the script or its protected state file.

1. Verify and run the root-owned script:

```bash
sudo stat -c '%A %U:%G %n' /opt/lab/inject-ex1.sh
resolve_container
sudo /opt/lab/inject-ex1.sh 2>&1 |
  sudo tee /opt/lab/evidence/ex1/injection-output.txt
```

2. Read the protected record, copy it to the evidence directory, and parse the two values needed for verification and recovery:

```bash
sudo cat /opt/lab/state/ex1.env
sudo cp --preserve=mode,timestamps /opt/lab/state/ex1.env \
  /opt/lab/evidence/ex1/injection-target.txt

TARGET_SCN=$(sudo awk -F= '$1 == "TARGET_SCN" {print $2}' /opt/lab/state/ex1.env)
BAD_MARKER=$(sudo awk -F= '$1 == "MARKER" {print $2}' /opt/lab/state/ex1.env)
[[ "$TARGET_SCN" =~ ^[0-9]+$ ]] || { echo "Invalid target SCN" >&2; exit 1; }
[[ -n "$BAD_MARKER" ]] || { echo "Missing bad marker" >&2; exit 1; }
printf 'target_scn=%s marker=%s\n' "$TARGET_SCN" "$BAD_MARKER"
```

3. Connect explicitly to `FREEPDB1` and prove the marker is committed and visible. Also preserve the supplied baseline checksum or pre-target marker for later comparison. Do not delete or update the bad row.

The required boundary is **whole-CDB PITR to `TARGET_SCN`**. PDB-only PITR, datafile-only recovery, flashback, manual row deletion, and schema recreation do not meet the objective.

## Task 6 — Perform whole-CDB PITR without stopping the container

The database instance must be shut down and mounted for whole-database restore. The Docker container must remain running throughout those Oracle state transitions.

1. Shut down only the Oracle instance:

```bash
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba' <<'SQL' 2>&1 |
  sudo tee /opt/lab/evidence/ex1/shutdown.txt
whenever sqlerror exit failure
shutdown immediate;
exit
SQL
```

2. **Immediately prove the container is still running**, then mount the CDB:

```bash
resolve_container
sudo docker ps --filter name=oracle-free --filter status=running \
  --format 'id={{.ID}} name={{.Names}} status={{.Status}}' |
  sudo tee /opt/lab/evidence/ex1/container-after-shutdown.txt

sudo docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba' <<'SQL' 2>&1 |
  sudo tee /opt/lab/evidence/ex1/startup-mount.txt
whenever sqlerror exit failure
startup mount;
select status from v$instance;
exit
SQL
```

3. Resolve the container again and prove it is running in the mounted state:

```bash
resolve_container
sudo docker inspect --format 'name={{.Name}} status={{.State.Status}} running={{.State.Running}}' \
  "$CONTAINER_ID" |
  sudo tee /opt/lab/evidence/ex1/container-at-mount.txt
```

4. Restore and recover the **whole database** to the injected SCN. Review which level 0/1 pieces and archived logs RMAN selects:

```bash
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'rman target /' <<RMAN 2>&1 |
  sudo tee /opt/lab/evidence/ex1/pitr-rman.txt
RUN {
  SET UNTIL SCN ${TARGET_SCN};
  RESTORE DATABASE;
  RECOVER DATABASE;
}
EXIT;
RMAN
```

Do not open the database if restore or recovery reports an unresolved error. Preserve the transcript and diagnose the failed piece or missing redo instead of bypassing it.

5. Confirm the container still runs, and then perform the required incomplete-recovery open:

```bash
resolve_container
sudo docker ps --filter name=oracle-free --filter status=running \
  --format 'id={{.ID}} name={{.Names}} status={{.Status}}'

sudo docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba' <<'SQL' 2>&1 |
  sudo tee /opt/lab/evidence/ex1/open-resetlogs.txt
whenever sqlerror exit failure
alter database open resetlogs;
alter pluggable database FREEPDB1 open;
alter pluggable database FREEPDB1 save state;
select name, open_mode from v$database;
select name, open_mode from v$pdbs order by con_id;
exit
SQL
```

6. Resolve and inspect the container once more. This is required evidence, not an optional health check:

```bash
resolve_container
sudo docker inspect --format 'name={{.Name}} id={{.Id}} status={{.State.Status}} running={{.State.Running}}' \
  "$CONTAINER_ID" |
  sudo tee /opt/lab/evidence/ex1/container-after-resetlogs.txt
```

The result must still show the original named container running. A recovery performed by stopping, replacing, or recreating `oracle-free` is not accepted.

## Task 7 — Prove the recovery outcome

Using SQL*Plus inside the dynamically resolved container, save evidence that:

- The CDB is open and `FREEPDB1` is `READ WRITE`.
- The unique value in `BAD_MARKER` is absent from the expected `LABAPP` table.
- The supplied pre-target row/checksum remains correct.
- `V$DATABASE_INCARNATION` identifies one current incarnation created by the `RESETLOGS` operation.
- The current resetlogs SCN is later than the baseline recorded by the injection.

Pass the marker as a SQL*Plus variable rather than manually retyping it:

```bash
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc \
  "sqlplus -s / as sysdba @/dev/stdin '$BAD_MARKER'" <<'SQL' 2>&1 |
  sudo tee /opt/lab/evidence/ex1/recovery-outcome.txt
whenever sqlerror exit failure
set lines 220 pages 100 verify off
alter session set container=FREEPDB1;
select count(*) as bad_marker_count
from LABAPP.ORDERS
where marker = '&1';
alter session set container=CDB$ROOT;
select name, open_mode, current_scn, resetlogs_change#, resetlogs_time from v$database;
select name, open_mode from v$pdbs order by con_id;
select incarnation#, resetlogs_change#, resetlogs_time, status
from v$database_incarnation
order by incarnation#;
exit
SQL
```

Add the seeded pre-target checksum query required by the protected exercise evidence. A zero bad-marker count alone is insufficient; you must also prove earlier valid data survived.

<question id="2"/>

## Task 8 — Protect the new incarnation

Create a new whole-CDB level 0 backup in the current post-`RESETLOGS` incarnation, with archived redo and control-file/SPFILE protection:

```bash
resolve_container
sudo docker exec -i "$CONTAINER_ID" bash -lc 'rman target /' <<'RMAN' 2>&1 |
  sudo tee /opt/lab/evidence/ex1/post-resetlogs-backup.txt
RUN {
  SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
  BACKUP INCREMENTAL LEVEL 0 DATABASE TAG 'CL_EX1_POST_RESETLOGS_L0';
  BACKUP ARCHIVELOG ALL NOT BACKED UP 1 TIMES TAG 'CL_EX1_POST_RESETLOGS_ARC';
  BACKUP CURRENT CONTROLFILE TAG 'CL_EX1_POST_RESETLOGS_CTL';
  BACKUP SPFILE TAG 'CL_EX1_POST_RESETLOGS_SPFILE';
}
LIST INCARNATION OF DATABASE;
LIST BACKUP SUMMARY;
EXIT;
RMAN
```

Correlate the current incarnation, completion time, and handles with files under `/u02/backup`. In your evidence, briefly explain why `OPEN RESETLOGS` creates a new incarnation/redo stream and why a prompt backup provides the baseline needed by Exercise 2.

## Review and validation

Confirm that `/opt/lab/evidence/ex1` contains your preflight, level 0/1, injection, state-transition, PITR, container-running, logical-outcome, incarnation, and post-`RESETLOGS` evidence.

Your completed environment must satisfy all of these checks:

- Exactly one intended container named `oracle-free` is running.
- A usable whole-CDB level 0/1 chain, archived redo, control-file/SPFILE protection, and physical pieces exist under `/u02/backup`.
- Whole-CDB PITR used the protected injected target SCN.
- Oracle shutdown, mount, restore, recovery, and `RESETLOGS` occurred inside the running container.
- `docker ps`/`docker inspect` evidence proves the container remained running across database state transitions.
- `FREEPDB1` is open, the bad transaction is absent, and pre-target data remains correct.
- The new incarnation is current and has a usable post-`RESETLOGS` backup.

<validation step="1"/>

## Completion

You have established an RMAN incremental chain, recovered the entire CDB to the known SCN without stopping or replacing its Docker container, verified the `FREEPDB1` business outcome, and protected the new incarnation. Leave `oracle-free`, the CDB, and `FREEPDB1` running and healthy for Exercise 2.