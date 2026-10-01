# Facilitator Solution — Oracle Backup, Recovery & Diagnostics

## Scope and operating contract

This guide implements **plan v5**. The runtime is Oracle Database Free in Docker on Amazon Linux 2023, not a native Oracle installation on the EC2 host. Award equivalent commands only when they produce equivalent Oracle/RMAN evidence.

The approved image is:

```text
container-registry.oracle.com/database/free:23.9.0.0
sha256:66296e93ffe793012d424439db5771617491e94c782196953d993ffd869c3eb0
```

The tag is pinned; `latest` is not an acceptable substitute. Bootstrap must pull the pinned tag, inspect the resolved repository digest, record it in `/opt/oracle-image-digest.txt`, and fail on a digest mismatch. A fresh registry pull test is required before publication because registry tags can be republished or retired.

The container must remain present and running throughout the lab. Oracle shutdown, startup, mount, restore, recover, and open operations occur inside that container. Candidates must not stop, remove, recreate, or replace `oracle-free`, delete persistent database directories, or recreate rows instead of performing RMAN recovery.

Every host script and validator dynamically resolves exactly one intended running container:

```bash
ids=$(docker ps --filter name=oracle-free --filter status=running -q)
count=$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l)
test "$count" -eq 1
CONTAINER_ID=$(printf '%s\n' "$ids" | sed '/^$/d')
```

A hard-coded container ID is not acceptable. The stable name may be used after the uniqueness check. The AWR/ASH-style reports are explicitly simulated evidence; do not describe them as Oracle-generated licensed AWR/ASH.

## AWS and host readiness

The AWS checks below use standard CloudFormation, EC2, and Systems Manager APIs. Always specify the deployment Region. `send-command` is asynchronous; poll `get-command-invocation` to a terminal status before judging the guest result.

```bash
export AWS_REGION=us-east-1
export STACK=lab-stack-name
INSTANCE_ID=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
BACKUP_VOLUME_ID=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`BackupVolumeId`].OutputValue' --output text)

aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
  --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}' --output json
aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone}' --output table
aws ec2 describe-volumes --region "$AWS_REGION" --volume-ids "$BACKUP_VOLUME_ID" \
  --query 'Volumes[0].{Id:VolumeId,Type:VolumeType,GiB:Size,Encrypted:Encrypted,State:State,Attachments:Attachments}' --output json
aws ssm describe-instance-information --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].{Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}' --output table
```

Expected control-plane evidence is an attached, in-use, encrypted, 30-GiB `gp3` backup volume and an EC2 instance of the deployed type (default `t3.large`). Guest evidence must additionally show `/u02/backup` mounted from that volume, `/u01/oradata` available, numeric ownership `54321:54321`, Docker active, exactly one running `oracle-free`, and a healthy CDB/PDB.

Use SSM for guest checks; do not infer readiness from EC2 `running` alone:

```bash
COMMAND_ID=$(aws ssm send-command --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --parameters 'commands=["set -eu","findmnt /u02/backup","findmnt /u01/oradata || true","systemctl is-active docker","systemctl is-active amazon-ssm-agent","cat /opt/oracle-image-digest.txt","docker ps --filter name=oracle-free --filter status=running","test -f /opt/lab/.ready"]' \
  --query 'Command.CommandId' --output text)
for i in $(seq 1 18); do
  status=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text)
  case "$status" in Success|Failed|Cancelled|TimedOut|Cancelling) break;; esac
  sleep 10
done
aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' --output json
```

The EC2 role should contain `AmazonSSMManagedInstanceCore`. AL2023 is expected to provide SSM Agent and `/opt/aws/bin/cfn-signal`; bootstrap verifies rather than installs them. CloudFormation success requires the readiness signal, not merely an instance launch.

## Common command contract

```bash
docker exec -it oracle-free sqlplus / as sysdba
docker exec -it oracle-free rman target /
```

Use `/u02/backup` for RMAN paths inside the container. Use `/u01/oradata` only when inspecting the host-side bind mount. Capture `V$DATABASE`, `V$PDBS`, `V$DATAFILE`, `V$RECOVER_FILE`, RMAN metadata, physical files, and protected injection evidence rather than relying on a single assertion.

# Exercise 1 — Full/incremental backup and whole-CDB PITR (35%)

## Task 1 — Baseline and RMAN configuration

**Expected end state:** CDB identity, current SCN, `ARCHIVELOG` mode, open `FREEPDB1`, datafile status, `/u02/backup` mount, Docker bind mounts, and RMAN configuration are recorded. Control-file autobackup is enabled and RMAN disk output is under `/u02/backup`.

```bash
docker exec -i oracle-free sqlplus -s / as sysdba <<'SQL'
set pages 100 lines 200
select dbid,name,log_mode,open_mode,current_scn from v$database;
select con_id,name,open_mode,restricted from v$pdbs order by con_id;
select con_id,file#,name,status,enabled from v$datafile order by con_id,file#;
exit
SQL
docker exec -i oracle-free rman target / <<'RMAN'
show all;
report schema;
exit
RMAN
findmnt /u02/backup
docker inspect oracle-free --format '{{json .Mounts}}'
```

**Rubric:** Full (2%): all health, storage, bind-mount, archive-mode, and RMAN facts are evidenced. Partial (1%): database is healthy but one category is missing. No credit for beginning recovery without a baseline.

**Pitfalls:** checking only `CDB$ROOT`; confusing a directory on the root disk with the EBS mount; using host RMAN; using a relative or container-layer backup destination.

## Task 2 — Level 0, level 1, and redo protection

**Expected end state:** a whole-CDB level 0, a later whole-CDB level 1, archived redo spanning the exercise, and control-file/SPFILE protection exist physically under `/u02/backup` and in RMAN metadata. Equivalent tags are valid.

```bash
docker exec -i oracle-free rman target / <<'RMAN'
configure controlfile autobackup on;
configure channel device type disk format '/u02/backup/rman_%U';
backup database plus archivelog tag 'LAB_L0';
list backup summary;
exit
RMAN
# After a workload change:
docker exec -i oracle-free rman target / <<'RMAN'
backup incremental level 1 database plus archivelog tag 'LAB_L1';
backup current controlfile tag 'LAB_CONTROLFILE';
backup spfile tag 'LAB_SPFILE';
list backup summary;
list backup of archivelog all;
exit
RMAN
```

**Rubric:** Full (12%): level 0 (4%), level 1 (4%), spanning redo (2%), control-file/SPFILE protection plus physical pieces (2%). Partial (6–9%): a usable backup exists but one chain component is unproven. SQL exports, filesystem copies, and clones do not earn RMAN-chain credit.

**Pitfalls:** level 1 before level 0; no archived redo; `DELETE INPUT`; writing to the container writable layer; assuming `LIST BACKUP` proves files are present without `CROSSCHECK`; filling the 30-GiB volume.

## Task 3 — Inject and preserve the target SCN

**Expected end state:** the candidate runs `sudo /opt/lab/inject-ex1.sh` once, preserves the protected target SCN and UTC timestamp, and proves the unique bad transaction exists in `FREEPDB1`. The state file is not edited.

**Rubric:** Full (3%): target SCN, time, PDB, and marker provenance are independently shown. Partial (1–2%): target is identifiable but corroboration is incomplete.

**Pitfalls:** running as a non-root user; recording the SCN after the transaction; querying the marker while still in root; rerunning or modifying the injection record.

## Task 4 — Whole-CDB PITR and RESETLOGS

**Expected end state:** using the recorded SCN, the candidate performs CDB-level restore and recovery inside the still-running container, then opens with `RESETLOGS`. The bad marker is absent while pre-target committed data remains.

```bash
docker exec -it oracle-free rman target /
```

Expected RMAN/SQL sequence (with the protected SCN substituted):

```text
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
RUN {
  SET UNTIL SCN <target_scn>;
  RESTORE DATABASE;
  RECOVER DATABASE;
}
ALTER DATABASE OPEN RESETLOGS;
```

```bash
docker ps --filter name=oracle-free --filter status=running
docker exec -i oracle-free sqlplus -s / as sysdba <<'SQL'
select name,open_mode,resetlogs_change#,resetlogs_time from v$database;
select con_id,name,open_mode from v$pdbs;
alter pluggable database FREEPDB1 open read write;
alter pluggable database FREEPDB1 save state;
exit
SQL
```

**Rubric:** Full (15%): target SCN (3%), CDB-level restore/recover (5%), `RESETLOGS` (3%), container continuity (2%), PDB/data assertions (2%). Partial (8–12%): valid recovery with missing proof, a time target, or incorrect granularity. Deleting the marker, recreating rows, or stopping/removing the container earns no recovery credit.

**Pitfalls:** running RMAN on the host; forgetting MOUNT; using a current SCN; missing redo; opening without `RESETLOGS`; confusing a stopped listener with a stopped container.

## Task 5 — New incarnation and post-resetlogs backup

**Expected end state:** `LIST INCARNATION` shows the current post-`RESETLOGS` incarnation, and a fresh post-resetlogs database/redo/control-file backup is usable.

```bash
docker exec -i oracle-free rman target / <<'RMAN'
list incarnation;
backup database plus archivelog tag 'LAB_POST_RESETLOGS';
backup current controlfile tag 'LAB_POSTRESET_CONTROLFILE';
list backup summary;
exit
RMAN
```

**Rubric:** Full (8%): new incarnation and usable post-resetlogs protection. Partial (3–5%): resetlogs occurred but the new recovery base is missing or unexplained.

**Pitfalls:** relying only on pre-resetlogs pieces; failing to crosscheck; confusing PDB open state with an RMAN incarnation.

# Exercise 2 — Independent FREEPDB1 datafile recovery (25%)

## Independence, warning, and safety behavior

Exercise 2 is independently attemptable. `sudo /opt/lab/inject-ex2.sh` requires only general readiness, mounted backup storage, and one healthy dynamically resolved container. It must not require Exercise 1 success or even an Exercise 1 state file.

If Exercise 1 evidence exists but PITR/`RESETLOGS` cannot be proven, the injector records a warning to stderr and the protected injection audit log, then continues. This warning is not an Exercise 1 failure adjudication and must not prevent Exercise 2.

Before deleting the training datafile, the injector determines the current incarnation and checks RMAN metadata and physical pieces for a usable current-incarnation whole-CDB level 0. If none exists, it creates and verifies an independent **safety level 0**, archived redo, and control-file/SPFILE protection. Failure to create that safety backup aborts the injection before file deletion. The safety backup is a recovery precondition, not candidate work.

The evidence must identify provenance, for example `learner-created` versus `injector-created`. Do not award Exercise 1 backup or PITR points for an injector-created safety level 0. Score Exercise 2 recovery separately and accept either a pre-existing usable current-incarnation level 0 or the injector-created safety level 0.

The injector offlines and removes only the dedicated training datafile in `FREEPDB1`; it never targets system, root, undo, temp, control, redo, or unrelated application files.

## Task 1 — Diagnose and establish scope

**Expected end state:** after `sudo /opt/lab/inject-ex2.sh`, the candidate reads `/opt/lab/evidence/ex2`, identifies the exact file number, PDB, checksum, Oracle path, host bind path, incarnation, and backup provenance, and corroborates the loss through Oracle and RMAN views.

```bash
sudo find /opt/lab/evidence/ex2 -maxdepth 2 -type f -ls
docker exec -i oracle-free sqlplus -s / as sysdba <<'SQL'
select con_id,file#,name,status,enabled from v$datafile order by con_id,file#;
select con_id,file#,error,online_status from v$recover_file;
select con_id,name,open_mode from v$pdbs;
alter session set container=FREEPDB1;
select tablespace_name,file_name,online_status from dba_data_files;
exit
SQL
docker exec -i oracle-free rman target / <<'RMAN'
list incarnation;
report schema;
list backup of database;
exit
RMAN
findmnt /u01/oradata
```

**Rubric:** Full (8%): exact file/PDB, missing state, current-incarnation backup/provenance, checksum, and least-disruptive scope. Partial (4–6%): file identified but path or scope rationale is weak.

**Pitfalls:** querying only root without `CON_ID`; guessing paths; treating loss as a dropped tablespace; restoring the whole CDB; changing protected evidence; confusing the safety backup with candidate Exercise 1 work.

## Task 2 — Targeted restore and recovery

**Expected end state:** RMAN inside the running container restores and recovers only the recorded training datafile, using a current-incarnation usable backup. The candidate brings only the affected datafile/tablespace online in the correct PDB context.

```bash
docker exec -it oracle-free rman target /
```

```text
LIST BACKUP OF DATAFILE <training_file_number>;
RUN {
  RESTORE DATAFILE <training_file_number>;
  RECOVER DATAFILE <training_file_number>;
}
```

**Rubric:** Full (12%): targeted restore (5%), targeted media recovery (4%), correct PDB/file context and no replacement of the database (3%). Partial (6–9%): data returns but scope is weak or unnecessary broader interruption occurs. No credit for `CREATE DATAFILE`, copying a file, or recreating rows.

**Pitfalls:** obsolete incarnation; wrong file number; missing redo; host path supplied to RMAN; bringing the file online before recovery; stopping Docker.

## Task 3 — Integrity and service restoration

**Expected end state:** the restored file exists at the expected bind mount, is online, `FREEPDB1` is read/write, `V$RECOVER_FILE` has no pending requirement for it, RMAN validation succeeds, and the checksum matches the protected pre-loss evidence. Injection records remain unchanged.

```bash
docker exec -i oracle-free sqlplus -s / as sysdba <<'SQL'
select con_id,file#,name,status,enabled from v$datafile order by con_id,file#;
select con_id,file#,error,online_status from v$recover_file;
select con_id,name,open_mode from v$pdbs;
exit
SQL
docker exec -i oracle-free rman target / <<'RMAN'
crosscheck datafile <training_file_number>;
validate datafile <training_file_number>;
exit
RMAN
```

**Rubric:** Full (5%): file/PDB state, no media recovery pending, checksum/row integrity, RMAN validation, and preserved evidence. Partial (2–3%): rows appear but state or checksum is missing.

**Pitfalls:** checking only a filename; accepting read-only PDB state; validating a different file; treating row count alone as checksum integrity.

# Exercise 3 — Diagnose, tune, and automate (30%)

## Task 1 — Diagnose the regression

**Expected end state:** the candidate identifies the seeded SQL, dominant object, cardinality error, and excess logical/physical I/O; labels the supplied report simulated; and corroborates it in live `FREEPDB1` execution.

Acceptable evidence includes an executed cursor and `DBMS_XPLAN.DISPLAY_CURSOR(NULL,NULL,'ALLSTATS LAST +PEEKED_BINDS')`, plus `V$SQL`, `V$SQL_PLAN_STATISTICS_ALL`, and PDB-local table statistics. `EXPLAIN PLAN` alone is insufficient.

**Rubric:** Full (8%): simulated provenance (2%), SQL/object and cardinality mechanism (3%), live plan/runtime/I/O evidence (3%). Partial (4–6%): stale statistics is asserted without live correlation.

**Pitfalls:** calling simulated reports AWR; blaming CPU or locking without wait evidence; changing inputs between runs; running in root; relying on one noisy elapsed measurement.

## Task 2 — Targeted statistics and measurable improvement

**Expected end state:** in `FREEPDB1`, statistics are gathered only for the evidenced owner/table and justified related columns/indexes. Before/after plans, statistics timestamps, identical inputs/results, checksum, and a stable resource improvement are retained.

```sql
ALTER SESSION SET CONTAINER=FREEPDB1;
BEGIN
  DBMS_STATS.GATHER_TABLE_STATS(
    ownname=>'<seeded_owner>', tabname=>'<affected_table>',
    estimate_percent=>DBMS_STATS.AUTO_SAMPLE_SIZE,
    method_opt=>'FOR ALL COLUMNS SIZE AUTO',
    cascade=>DBMS_STATS.AUTO_CASCADE);
END;
/
```

**Rubric:** Full (12%): correct PDB/object scope (4%), fresh targeted statistics (2%), measured access-path/resource improvement (4%), identical result checksum (2%). Partial (4–8%): fresh statistics and plan change without stable measurement/checksum, or unnecessarily broad collection. A changed plan hash alone is not improvement.

**Pitfalls:** gathering CDB-wide statistics; wrong owner; changing binds; cold/warm comparison; hints or undocumented parameters; data modification; cosmetic plan change.

## Task 3 — Scheduled RMAN verification

**Expected end state:** an executable host Bash job dynamically finds exactly one running container, prevents overlap, logs under `/u02/backup`, runs RMAN crosscheck and non-destructive validation, propagates failures, and is enabled on a schedule with an authentic successful run.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec 9>/u02/backup/.rman-verify.lock
flock -n 9 || exit 75
log=/u02/backup/verify-$(date -u +%Y%m%dT%H%M%SZ).log
exec > >(tee -a "$log") 2>&1
ids=$(docker ps --filter name=oracle-free --filter status=running -q)
test "$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l)" -eq 1
docker exec -i oracle-free rman target / <<'RMAN'
set echo on;
crosscheck backup;
restore database validate;
validate backup;
exit
RMAN
echo "verification succeeded $(date -u +%FT%TZ)"
```

**Rubric:** Full (10%): discovery (2%), crosscheck (2%), non-destructive validation (2%), logs/failure propagation (2%), lock (1%), enabled schedule and successful run (1%). Partial (3–7%): manual run works but schedule, lock, or exit propagation is absent. No credit for hard-coded success or container ID.

**Pitfalls:** host RMAN; cron PATH differences; root-disk logs; `|| true`; swallowed `docker exec` failure; overlapping jobs; destructive restore; metadata-only validation.

# Scoring, provenance, and fail conditions

| Area | Weight |
|---|---:|
| Exercise 1: chain, whole-CDB SCN PITR, incarnation, post-resetlogs backup | 35% |
| Exercise 2: diagnosis, targeted datafile recovery, integrity | 25% |
| Exercise 3: diagnosis, targeted statistics, scheduled verification | 30% |
| Operational quality and preserved evidence | 10% |

Score each exercise from its own evidence. Exercise 2 receives its 25% even when Exercise 1 failed, provided its independent injection/recovery evidence is correct. Conversely, injector-created safety backups are never retroactively awarded Exercise 1 points. Record backup provenance explicitly (`learner-created` or `injector-created`) and keep warning/audit records separate from candidate evidence.

Fabricated or edited evidence, altered injection scripts, manual data recreation, stopping/removing the container, hard-coded IDs, hard-coded success, or widening protected access is a fail condition regardless of numerical score.

# Facilitator troubleshooting

## Bootstrap and image

- **CloudFormation waits or fails:** inspect stack events, `/var/log/cloudlabs-bootstrap.log`, cloud-init, and the EC2 system log. Common causes include Oracle Container Registry terms/authentication, DNS or HTTPS egress, device discovery timing, missing preinstalled `cfn-signal`/SSM Agent, and image digest drift. Do not manually signal success.
- **Digest mismatch:** stop publication or deployment. Confirm the exact pinned tag, architecture, registry pull result, and `/opt/oracle-image-digest.txt`; never replace the approved digest with a newly observed value silently. The pinned release-test digest is `sha256:66296e93ffe793012d424439db5771617491e94c782196953d993ffd869c3eb0`.
- **SSM `TargetNotConnected`:** verify instance-profile attachment, IAM propagation, agent service/binary, DNS, and HTTPS egress. EC2 `running`, CloudFormation completion, SSM online, Docker readiness, and `/opt/lab/.ready` are separate milestones.
- **Wrong Region:** pass `--region "$AWS_REGION"` to every AWS CLI call. A missing stack, volume, instance, or SSM target in another Region is not absence.
- **IAM denied:** inspect the action, Region, resource, `iam:PassRole`, and condition keys. Explicit identity-based denies override allows; do not remove guardrails. IAM changes can take time to propagate.

## Storage, Docker, and Oracle

- **Backup volume wrong or absent:** verify direct `aws ec2 describe-volumes` output, then `findmnt /u02/backup`, UUID, and ownership. Never format a populated device or assume `/dev/nvme1n1`.
- **No container/SQL failure:** check `systemctl is-active docker`, `docker ps -a --filter name=oracle-free`, and `docker logs --tail 100 oracle-free`. A running container does not prove Oracle listener/database readiness. Do not recreate it.
- **RMAN cannot find pieces:** distinguish host `/u01/oradata` from container `/u02/backup`; verify mount, ownership, `CROSSCHECK`, physical files, and current incarnation. Do not invent or copy pieces.
- **PITR fails:** verify target SCN, MOUNT state, archived redo, incarnation, and all-file recovery. Keep Docker running; do not force open or delete files.
- **Exercise 2 appears blocked by Exercise 1:** inspect the injector audit warning and provenance. The injector must continue after a non-proven PITR warning and create a current-incarnation level 0 only when needed. If the safety backup failed, injection must have aborted before deletion; fix readiness/storage rather than bypassing the guard.
- **PDB/datafile remains unavailable:** query `V$PDBS`, `V$DATAFILE`, and `V$RECOVER_FILE` with `CON_ID`. Confirm only the training file was targeted and that media recovery is complete.
- **Tuning result is inconclusive:** repeat identical inputs with comparable warm-up, capture executed-cursor statistics, and use buffer gets/logical reads as a stable metric. Do not accept plan hash alone.

## AWS control-plane notes

This lab uses EBS for backup storage and does not require S3 or Lambda. S3 bucket-name uniqueness and Lambda cold starts are therefore irrelevant troubleshooting branches. EC2 `running` can lag application readiness; CloudFormation completion can lag or precede SSM registration; and SSM command submission can succeed while the remote command later fails. Poll the invocation and inspect both stdout and stderr.

## Final manual acceptance

```bash
aws cloudformation describe-stack-events --region "$AWS_REGION" --stack-name "$STACK" \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' --output table
aws ec2 describe-volumes --region "$AWS_REGION" --volume-ids "$BACKUP_VOLUME_ID" \
  --query 'Volumes[0].{Type:VolumeType,GiB:Size,Encrypted:Encrypted,State:State,AZ:AvailabilityZone}' --output table
aws ssm describe-instance-information --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" --output table
```

Make the final decision from direct AWS control-plane evidence, SSM/host evidence, Oracle/RMAN evidence, protected injection provenance, and the three validator results. None substitutes for the others.