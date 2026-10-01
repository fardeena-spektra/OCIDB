# Facilitator Solution — Oracle Backup, Recovery & Diagnostics

## Use of this guide

This is the facilitator key for plan v3. It is intentionally outcome-oriented: candidates may use equivalent RMAN, SQL*Plus, Linux, systemd, or cron commands. Accept evidence only when it is reproducible and tied to the provisioned instance and `FREEPDB1`; pasted output, recreated rows, or hard-coded verification results do not earn credit.

The environment is Oracle Database Free on an EC2 `t3.large`. The seeded AWR/ASH-style files are simulations and must be described as such. Oracle Database Free does not provide licensed AWR/ASH generation. Live corroboration must use execution plans, elapsed/runtime observations, SQL and dynamic performance views, and RMAN output.

## Facilitator readiness and AWS checks

Before a session, confirm the stack is in `us-east-1`, the EC2 instance is running, the SSM agent is online, and the separate backup volume is attached and mounted. AWS CLI commands below use the documented AWS CLI form: region is explicit, `describe-volumes` is a direct EC2 call, and guest commands use Systems Manager Run Command. Replace local shell variables; do not place credentials in the guide or in SSM command strings.

```bash
export AWS_REGION=us-east-1
export STACK=your-stack-name
export INSTANCE_ID=$(aws cloudformation describe-stacks --region "$AWS_REGION" \
  --stack-name "$STACK" --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
  --output text)

aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK" \
  --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}' --output json
aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,Subnet:SubnetId}'
aws ssm describe-instance-information --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].{Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}'
aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
            "Name=tag:Name,Values=*backup*" \
  --query 'Volumes[].{Id:VolumeId,Type:VolumeType,GiB:Size,Encrypted:Encrypted,State:State,Attachments:Attachments}' \
  --output json
```

If the volume has no identifying tag, discover it by the CloudFormation output/resource or by `describe-volumes` filtered on the instance attachment, then inspect all returned volumes. The expected result is one separate in-use encrypted `gp3`, 30-GiB volume. `describe-volumes` is deliberately run directly from the validator/facilitator shell, not through SSM.

A guest check can be sent with Run Command. `send-command` returns a command ID; it is not synchronous, so poll `get-command-invocation` until a terminal status. The instance role needs `AmazonSSMManagedInstanceCore`; the caller needs the relevant SSM actions.

```bash
CMD=$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["set -eu","findmnt /u02/backup","df -h /u02/backup","systemctl is-active amazon-ssm-agent"]' \
  --query 'Command.CommandId' --output text)
aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$CMD" --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}'
```

For a slow or `Pending` result, poll rather than declaring failure. An instance can be `running` before bootstrap, Oracle listener, or SSM registration is ready. A missing SSM target is not fixed by repeatedly sending commands; inspect the agent service, instance profile, route/egress, DNS, and IAM propagation.

## Expected evidence package

At minimum, collect these artifacts under the lab evidence location and preserve the original injection records:

- RMAN `SHOW ALL`, `LIST BACKUP SUMMARY`, `LIST BACKUP OF DATABASE`, archived-log listing, `CROSSCHECK`, and validation output.
- Level 0 and level 1 piece names, sizes, completion times, archived redo coverage, and control-file/SPFILE protection.
- Exercise 1 target SCN/time, injected transaction marker, `RESETLOGS` output, new incarnation, post-resetlogs backup, and SQL showing the bad row absent while pre-target rows remain.
- Exercise 2 injection record, `v$datafile`/`v$recover_file`/`v$recovery_status` evidence with container context, RMAN restore/recover transcript, and row/checksum comparison.
- Exercise 3 seeded report references, baseline and post-statistics plans/metrics, object statistics timestamps, checksum output, and the verification script, schedule, and successful log.

Exact filenames may vary. Evidence must include UTC timestamps, database identity, PDB name, and enough command text to establish provenance.

# Exercise 1 — Full/incremental backup and whole-CDB SCN PITR

## Task 1: establish baseline

**Expected answer/end state.** The candidate connects to the CDB as an authorized recovery user, confirms `ARCHIVELOG`, confirms `FREEPDB1` is open or can be opened, verifies `/u02/backup` is the separate writable filesystem, and records the RMAN configuration. The database and PDB are healthy before injection.

Accept equivalent checks using `v$database`, `v$pdbs`, `v$datafile`, `v$log`, `df`, `findmnt`, and RMAN `SHOW ALL`. The backup destination must be deterministic and point to `/u02/backup`; control-file autobackup must be enabled.

**Rubric.** Full credit: all health, mode, mount, capacity, write, and configuration evidence is captured (2%). Partial: database health is shown but archive mode, mount identity, or RMAN settings are missing (1%). No credit: work starts without establishing the baseline.

**Common pitfalls.** Checking only `CDB$ROOT`; confusing a directory on the root EBS volume with the backup EBS; using a relative RMAN format; proceeding while `FREEPDB1` is mounted or the listener is not ready.

## Task 2: create the backup chain

**Expected answer/end state.** The candidate creates a CDB level 0 backup to `/u02/backup`, includes archived redo and control-file/SPFILE protection, then runs the supplied workload change and creates a level 1 incremental with enough archived redo. A valid, physical chain is visible both in RMAN metadata and on disk.

A valid pattern is conceptually:

```text
RMAN TARGET /
CONFIGURE CONTROLFILE AUTOBACKUP ON;
BACKUP DATABASE PLUS ARCHIVELOG TAG 'LAB_L0';
-- run the supplied workload change
BACKUP INCREMENTAL LEVEL 1 DATABASE PLUS ARCHIVELOG TAG 'LAB_L1';
LIST BACKUP SUMMARY;
LIST BACKUP OF DATABASE;
LIST BACKUP OF ARCHIVELOG ALL;
```

The candidate may use explicit `FORMAT '/u02/backup/...%U'`, `BACKUP CURRENT CONTROLFILE`, and `BACKUP SPFILE` instead of relying on configuration, provided the resulting chain is usable. Do not require a particular backup-set count or tag.

**Rubric.** Full: level 0, level 1, redo, control file/SPFILE, and usable physical pieces are proven (12%). Partial: a database backup exists but the incremental, redo coverage, or control-file protection is not proven (6–9%). A database copy or SQL export is not an RMAN chain.

**Common pitfalls.** Running the level 1 before the level 0; omitting archived redo; putting pieces on `/`; confusing `BACKUP DATABASE` with `BACKUP CDB`; not checking free space; using `DELETE INPUT` and destroying evidence; assuming `LIST BACKUP` proves files still exist without `CROSSCHECK`.

## Task 3: inject and identify the recovery target

**Expected answer/end state.** `sudo /opt/lab/inject-ex1.sh` is run once. The facilitator must see the script's target SCN and unique bad-transaction marker in the protected audit record. The candidate verifies the marker in `FREEPDB1`, after the target SCN was recorded. The target is an SCN, not merely a wall-clock guess.

**Rubric.** Full: target, UTC time, PDB, and marker are preserved and independently verified (3%). Partial: target exists but marker or PDB context is absent (1–2%). No credit for modifying the injection log.

**Common pitfalls.** Running the script as a non-root user; running it twice; connecting to `CDB$ROOT` and querying the application schema without changing container; selecting the SCN after the bad transaction.

## Task 4: perform whole-CDB SCN PITR

**Expected answer/end state.** The candidate uses RMAN connected to the CDB, restores/recover the whole database to the recorded SCN, and opens the CDB with `RESETLOGS`. A typical sequence is equivalent to:

```text
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
RUN {
  SET UNTIL SCN target_scn_from_injection_record;
  RESTORE DATABASE;
  RECOVER DATABASE;
}
ALTER DATABASE OPEN RESETLOGS;
```

If the candidate uses `SET UNTIL TIME` only, award at most partial credit: the task target is the recorded SCN. After opening, the candidate opens `FREEPDB1` read/write as appropriate, saves its state, verifies the bad transaction is absent, and verifies earlier committed data remains. The entire CDB, not just the PDB, is recovered; all datafiles are consistent with the target.

**Rubric.** Full: correct target SCN, CDB-level restore/recovery, `RESETLOGS`, PDB health, and data assertions (15%). Partial: correct recovery but time-based or PDB-only procedure, or missing data assertions (8–12%). No credit for deleting the bad row manually, recreating data, or restoring only the application schema.

**Common pitfalls.** Forgetting `STARTUP MOUNT`; recovering only `FREEPDB1`; using the current SCN instead of the recorded one; not restoring archived redo; opening normally after incomplete recovery; using a post-target backup without explaining why; not checking the alert log after `RESETLOGS`.

## Task 5: prove incarnation handling and create a new backup

**Expected answer/end state.** RMAN `LIST INCARNATION` shows a new current incarnation after `OPEN RESETLOGS`. The candidate creates a new usable CDB backup after resetlogs, preferably including archived redo and control-file/SPFILE protection. The post-resetlogs backup is not optional operationally: it establishes a recovery base for the new incarnation.

**Rubric.** Full: new incarnation and post-resetlogs backup are both independently evidenced (8%). Partial: `RESETLOGS` occurred but no usable new backup, or the candidate cannot explain incarnation selection (3–5%).

**Common pitfalls.** Continuing to rely only on pre-resetlogs pieces; not cataloging or crosschecking the post-resetlogs pieces; confusing database incarnation with PDB open state; deleting the only usable post-resetlogs backup.

# Exercise 2 — FREEPDB1 training datafile recovery

## Task 1: diagnose the incident and choose scope

**Expected answer/end state.** After `sudo /opt/lab/inject-ex2.sh`, the candidate identifies the exact training datafile from the protected injection record, container-aware views, alert/log evidence, and the filesystem. They explain that only a dedicated `FREEPDB1` training file was removed. PDB/datafile-scoped recovery is preferable because it minimizes outage and avoids replacing healthy root, system, undo, temp, and application files.

Useful evidence includes `CDB_DATA_FILES`/`V$DATAFILE` with `CON_ID`, `V$RECOVER_FILE`, `V$DATABASE`, `V$PDBS`, RMAN `REPORT SCHEMA`, `LIST BACKUP OF DATAFILE`, alert log entries, and `findmnt`/`ls` output. SQL must be executed in the correct PDB or use explicit `CON_ID` filtering.

**Rubric.** Full: exact file, PDB, offline/missing status, backup availability, and least-disruptive scope are proven (8%). Partial: file is found but container identity or scope rationale is weak (4–6%). **Common pitfalls.** Treating an OS-missing file as a dropped tablespace; querying only root views and overlooking `CON_ID`; restoring every database file; attempting to recover `SYSTEM`, `SYSAUX`, or undo; editing or recreating the file with SQL instead of RMAN.

## Task 2: restore and recover only the training file

**Expected answer/end state.** The candidate sets RMAN context for the affected PDB/datafile, restores the named file from the post-resetlogs-compatible backup, and recovers it with archived redo. Equivalent approaches using RMAN `SET PDB`, `RESTORE DATAFILE`, `RECOVER DATAFILE`, or a correctly scoped `ALTER SESSION SET CONTAINER` plus RMAN syntax are acceptable. The tablespace/PDB is returned online/open without unnecessary CDB restore.

The exact file number and path are intentionally instance-specific. Do not award for a guessed path. The transcript must show the actual file selected from the injection record and RMAN metadata.

**Rubric.** Full: targeted restore and recovery complete, correct PDB context is explicit, and only necessary disruption occurs (12%). Partial: file is restored and data is present but scope/context is not demonstrated, or the candidate unnecessarily takes the whole CDB down (6–9%). No credit for manual file creation or copying a datafile outside RMAN.

**Common pitfalls.** Restoring from the obsolete pre-`RESETLOGS` incarnation; forgetting archived redo; running RMAN while the wrong PDB is selected; bringing a file online before media recovery; confusing `RECOVER DATABASE` with targeted `RECOVER DATAFILE`.

## Task 3: prove integrity and return to service

**Expected answer/end state.** The training datafile is present and online, `FREEPDB1` opens correctly, `V$RECOVER_FILE` is empty for required files, and the seeded row/checksum markers match the pre-loss values. The injection record remains unchanged. Evidence includes before/after file identity, RMAN restore/recover output, PDB state, and deterministic SQL checks.

**Rubric.** Full: online/no-media-recovery-needed, PDB-open, data/checksum, and preserved-record evidence (5%). Partial: PDB opens and rows appear but no no-recovery-needed or checksum proof (2–3%). **Common pitfalls.** Verifying only that the filename exists; overlooking read-only/open state; accepting a row count alone when the expected checksum is available; modifying the protected marker to make it match.

# Exercise 3 — SQL regression and automated backup verification

## Task 1: diagnose the regression

**Expected answer/end state.** The candidate identifies the dominant seeded SQL and distinguishes the seeded AWR/ASH-style observations: poor cardinality estimates/stale or missing statistics on affected `FREEPDB1` objects, disproportionate logical/physical I/O, and a suboptimal access path. They do not claim the reports were generated by Oracle Database Free.

A defensible diagnosis correlates report SQL ID/object/wait information with a live reproduction in `FREEPDB1`, `DBMS_XPLAN.DISPLAY_CURSOR` or equivalent plan output, elapsed time/buffer statistics, row estimates versus actual rows, and dynamic views. CPU-only, locking, or latch pressure must not be asserted unless live evidence supports it.

**Rubric.** Full: report findings are clearly labeled simulated, dominant SQL and object are identified, cardinality/I/O mechanism is explained, and live corroboration is supplied (8%). Partial: stale statistics and a bad plan are named but no live correlation, or waits are misclassified (4–6%). **Common pitfalls.** Calling a simulated report “AWR”; tuning from elapsed time alone on a noisy `t3.large`; blaming locks because a wait appears in a report; using root-owned objects; changing SQL text or adding hints before testing statistics.

## Task 2: gather targeted statistics and prove improvement

**Expected answer/end state.** The candidate gathers targeted optimizer statistics only for the affected objects in `FREEPDB1`, using appropriate `DBMS_STATS` calls and a justified method/degree/sample. They capture before and after `DBA_TAB_STATISTICS`/`ALL_TAB_STATISTICS` timestamps and plan output. The query returns the same checksum/result while showing a measurably better access path and stable improvement metric such as buffers or logical reads; absolute elapsed thresholds should account for instance variance.

An acceptable pattern is a PDB-local connection followed by `DBMS_STATS.GATHER_TABLE_STATS` for the identified owner/table and, where justified, index statistics or column/histogram statistics. Gathering statistics for the entire CDB, using undocumented optimizer changes, or changing application data is not targeted tuning.

**Rubric.** Full: correct PDB scope/object scope (4%), plan/access-path improvement with measured support (4%), result checksum preserved (2%), and before/after statistics evidence (2%). Partial: statistics are fresh and plan changes but no stable metric/checksum, or broad statistics collection was used (4–8%). No credit for a cosmetic plan change with a changed result.

**Common pitfalls.** Gathering stats in `CDB$ROOT`; gathering the wrong owner/table; comparing different bind values; trusting `EXPLAIN PLAN` without an executed cursor; treating a changed plan as proof of improvement; changing schema/data or forcing a hint.

## Task 3: build and schedule verification automation

**Expected answer/end state.** The executable Bash program under an approved location performs RMAN `CROSSCHECK`, reports expired/missing pieces, runs a non-destructive restore validation such as `RESTORE ... VALIDATE`/`VALIDATE BACKUPSET`, writes timestamped logs under `/u02/backup`, exits nonzero on any failure, prevents overlap with `flock` or an equivalent lock, and never emits a hard-coded success. It does not overwrite backup pieces or evidence.

A robust implementation has `set -Eeuo pipefail`, an absolute Oracle environment, a lock file, a unique log name, tee/redirected output, explicit RMAN error handling, and a final status derived from command results. A systemd service plus timer or a cron entry is acceptable. The candidate runs it once manually and proves a recent successful log and an enabled schedule.

**Rubric.** Full: crosscheck (2%), restore validation (2%), timestamped protected logs and no overwrite (2%), failure propagation (2%), overlap prevention (1%), enabled schedule and successful run (1%). Partial: script works once but lacks locking, nonzero propagation, or scheduling (3–7%). No credit for `echo SUCCESS` without RMAN result inspection.

**Common pitfalls.** Running RMAN as the wrong OS user; relying on a login shell for `ORACLE_SID`/`ORACLE_HOME`; using a log path on the root filesystem; cron’s minimal `PATH`; overlapping long validations; swallowing RMAN status with `|| true`; validating only metadata rather than backup contents; writing logs world-writable.

# Overall rubric and adjudication

| Area | Full-credit standard | Weight |
|---|---|---:|
| Exercise 1 | Valid CDB level 0/incremental chain (12%), correct whole-CDB SCN PITR and data result (15%), `RESETLOGS`/incarnation and new backup (8%) | 35% |
| Exercise 2 | PDB-aware diagnosis and scope (8%), targeted file restore/recovery (12%), integrity/no-media-recovery evidence (5%) | 25% |
| Exercise 3 | Defensible diagnosis (8%), targeted statistics and measured correct improvement (12%), robust scheduled verification (10%) | 30% |
| Operational quality | Safe commands, preserved evidence, least privilege/security awareness, no protected-control bypass | 10% |

A passing submission must pass all three validators. Fabricated evidence, manual data recreation in place of RMAN, disabled controls, or hard-coded success is a fail condition regardless of raw score. Deduct operational-quality credit for widening SSH ingress, exposing credentials in logs/commands, changing root-owned injection scripts, or altering IAM guardrails. Do not deduct for equivalent valid syntax or a different but demonstrably safe schedule.

# Troubleshooting decision tree

## Stack or instance is not ready

- **Stack `CREATE_IN_PROGRESS`:** wait for the EC2 CreationPolicy signal; inspect CloudFormation events and the instance console/system log. Do not manually signal success.
- **`CREATE_FAILED` or timeout:** inspect `/var/log/cloud-init-output.log`, bootstrap logs, and the CloudFormation failure reason. Common causes are Oracle RPM/repository drift, insufficient egress, wrong AMI mapping, disk device timing, or failure to locate the pip-installed `cfn-signal`.
- **Wrong region/no AMI:** use `--region us-east-1`; the template intentionally supports the mapped region only. Do not substitute a nonexistent SSM public AMI parameter.
- **SSM `TargetNotConnected`:** confirm instance profile attachment, `amazon-ssm-agent` installed and active, DNS/route/HTTPS egress, and IAM propagation. An EC2 `running` state does not imply SSM readiness.
- **SSH failure:** confirm the security-group ingress CIDR, public address, route/IGW, effective `sshd` configuration, and the username. Do not broaden access beyond the disposable-lab requirement.

## Backup and recovery failures

- **RMAN cannot find pieces:** run `CROSSCHECK`, inspect `/u02/backup` mount and permissions, catalog only known legitimate files, and verify the correct incarnation. Do not invent or copy pieces.
- **Missing redo:** identify the required sequence/SCN range and restore archived logs from the valid chain; check that `PLUS ARCHIVELOG` was actually taken.
- **`OPEN RESETLOGS` fails:** remain mounted, inspect RMAN/alert output, verify incomplete recovery reached the target and all required files are recovered. Never force-open by deleting files.
- **PDB will not open:** check `V$PDBS`, `V$DATAFILE`, `V$RECOVER_FILE`, alert log, and file state in the correct container. A PDB datafile incident should not trigger a whole-CDB restore.
- **Exercise 2 restores the wrong file:** stop, compare file number/path/`CON_ID` to the protected injection record and RMAN `REPORT SCHEMA`, then restart with explicit PDB/datafile scope.

## Tuning or automation failures

- **Plan changed but result differs:** reject the result, restore the intended data state if the candidate changed it, and rerun with identical binds/inputs; checksum is authoritative.
- **No improvement:** confirm stats were gathered for the actual affected owner/table in `FREEPDB1`, compare executed cursor plans and buffers, and account for cache/t3 variance. Do not require a particular plan hash if the access path and stable metric improve.
- **Cron works manually only:** set absolute `ORACLE_HOME`, `ORACLE_SID`, `PATH`, and log paths; run as the Oracle OS account; capture stderr and exit status.
- **Verification says success after RMAN failure:** inspect `set -o pipefail`, RMAN exit handling, and lock logic. A log line is not proof; the scheduler and validator must observe the nonzero status.

## AWS-specific facilitator pitfalls

- A globally unique S3 bucket name is irrelevant here: backups are EBS-only; do not add S3 permissions or silently redesign the exercise.
- IAM policy changes can take time to propagate. Retry only after inspecting the denied action, region, resource, and condition; do not remove explicit denies.
- Explicit denies override allows. If stack creation, `iam:PassRole`, `ec2:DescribeVolumes`, SSM registration, or validators fail, inspect policy conditions and the expected lab tags/path.
- EC2 state, CloudFormation state, SSM registration, listener readiness, and `.ready` are separate milestones. Treat them separately.
- Validate direct EC2 volume properties from the facilitator/validator account, not from an SSM command that could be tampered with by the guest.
- Lambda cold-start guidance is not applicable to this package; do not introduce Lambda merely to poll or validate the EC2 host.

## Final manual acceptance commands

```bash
aws cloudformation describe-stack-events --region us-east-1 --stack-name "$STACK" \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table
aws ec2 describe-volumes --region us-east-1 --volume-ids "$BACKUP_VOLUME_ID" \
  --query 'Volumes[0].{Type:VolumeType,Size:Size,Encrypted:Encrypted,State:State,AZ:AvailabilityZone}'
aws ssm describe-instance-information --region us-east-1 \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" --output table
# Use the send-command/get-command-invocation pattern above for final guest checks.
```

The final facilitator decision is based on the three validator results plus the preserved evidence set. AWS control-plane observations establish the correct instance, volume, region, attachment, encryption, and SSM path; Oracle/RMAN observations establish recovery and tuning correctness; neither evidence source substitutes for the other.