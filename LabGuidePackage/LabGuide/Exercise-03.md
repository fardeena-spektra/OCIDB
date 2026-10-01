# Exercise 3 — Diagnose SQL regression and automate RMAN verification

## Scenario

A reporting query became slower after bulk data changes. You must form a hypothesis from supplied incident clues, test it against the live `FREEPDB1` workload, make a narrowly scoped optimizer-statistics change, and prove that the result is both faster and correct. You will then implement recurring RMAN verification on the Amazon Linux host while every Oracle command runs inside the long-running database container.

> [!Important]
> The supplied **AWR-style** and **ASH-style** reports are **simulated training reports**. Oracle Database Free did not generate AWR or ASH data. Do not represent these files as Oracle-generated reports. Use them only as clues, and corroborate the hypothesis with live execution plans, repeated runtime measurements, result checksums, and dynamic performance views available in this lab.

## Objectives

In this exercise, you will:

- Diagnose the regression using simulated clues and live non-AWR evidence.
- Capture reproducible before-and-after plans and objective metrics from `FREEPDB1`.
- Gather targeted `DBMS_STATS` statistics for only the affected application objects.
- Prove that the tuned query returns identical results.
- Build a Docker-aware RMAN verification script with overlap prevention and truthful failure propagation.
- Enable a recurring systemd timer or cron schedule and retain an authentic successful run.

## Sign in and connect

1. Open <inject key="AwsConsoleUrl"></inject> and sign in using:
   - **User name:** <inject key="IamUserName"></inject>
   - **Password:** <inject key="IamUserPassword"></inject>

2. Confirm that the console shows AWS account <inject key="AwsAccountId"></inject> and Region <inject key="AwsRegion"></inject>.

3. On the workstation with your configured AWS CLI profile, set variables from the displayed values. The deployment ID is <inject key="DeploymentID"></inject>, and the Region is <inject key="AwsRegion"></inject>.

   ```bash
   export DEPLOYMENT_ID='paste-the-displayed-deployment-id'
   export AWS_REGION='paste-the-displayed-region'
   aws sts get-caller-identity
   ```

4. Resolve exactly one running instance from its CloudFormation stack-name tag.

   ```bash
   INSTANCE_ID=$(aws ec2 describe-instances \
     --region "$AWS_REGION" \
     --filters \
       "Name=tag:aws:cloudformation:stack-name,Values=*$DEPLOYMENT_ID*" \
       "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].InstanceId' \
     --output text)

   printf 'Instance: %s\n' "$INSTANCE_ID"
   test -n "$INSTANCE_ID" && test "$(wc -w <<<"$INSTANCE_ID")" -eq 1
   ```

5. Start an AWS Systems Manager Session Manager session. The AWS CLI command is interactive and requires the Session Manager plugin on the local workstation.

   ```bash
   aws ssm start-session --region "$AWS_REGION" --target "$INSTANCE_ID"
   ```

6. In the managed-node shell, obtain a root login shell and verify readiness.

   ```bash
   sudo -i
   test -f /opt/lab/.ready
   systemctl is-active amazon-ssm-agent
   systemctl is-active docker
   findmnt /u02/backup
   ```

> [!Note]
> If the local Session Manager plugin is unavailable, in the AWS console open **AWS Systems Manager → Node Management → Session Manager**, choose **Start session**, select the lab managed node, and start the session. Do not open additional inbound ports to work around a local client issue.

## Docker command contract

Oracle Database Free runs inside Docker; SQL*Plus and RMAN are not host-installed tools. Dynamically resolve the intended running container before each task or script run:

```bash
mapfile -t CONTAINERS < <(docker ps \
  --filter name=oracle-free \
  --filter status=running \
  --format '{{.ID}}')

if (( ${#CONTAINERS[@]} != 1 )); then
  printf 'Expected exactly one running oracle-free container; found %d\n' \
    "${#CONTAINERS[@]}" >&2
  exit 1
fi

CONTAINER_ID=${CONTAINERS[0]}
printf 'Oracle container: %s\n' "$CONTAINER_ID"
docker ps --filter "id=$CONTAINER_ID"
```

The required discovery expression at the core of your automation is:

```bash
CONTAINER_ID=$(docker ps --filter name=oracle-free --filter status=running -q | head -n 1)
```

The `head` expression alone is not sufficient: your script must also count the matches and fail unless exactly one intended container is running. Never hardcode a container ID. Database state operations affect the Oracle instance inside the container; they must not stop or remove the container itself. Do not run `docker stop`, `docker rm`, or `docker compose down`.

## Task 1 — Form a hypothesis from simulated evidence

Create the evidence directory without modifying the seeded diagnostics.

```bash
install -d -m 0755 /opt/lab/evidence/ex3
script -q -a /opt/lab/evidence/ex3/diagnosis-session.txt
```

Review these concrete files:

- `/opt/lab/diagnostics/simulated-awr-style.txt` — **simulated, not Oracle-generated AWR**
- `/opt/lab/diagnostics/simulated-ash-style.txt` — **simulated, not Oracle-generated ASH**
- `/opt/lab/workload/reporting-query.sql`
- `/opt/lab/expected/reporting-query.sha256`

Write `/opt/lab/evidence/ex3/diagnosis.md`. Identify:

1. The dominant SQL identifier or statement signature in the simulation.
2. The simulated wait class/event pattern and whether it suggests I/O, CPU, or locking.
3. The affected table or index.
4. The clue suggesting stale, missing, or unrepresentative statistics.
5. A testable prediction about the baseline access path and estimated-versus-actual rows.
6. The live measurements that could falsify your prediction.

Do not treat a simulated wait event as proof of current database behavior.

<question path="Inline-Questions/question-04.md" />

## Task 2 — Capture the live `FREEPDB1` baseline through Docker

Resolve the container again. Start SQL*Plus inside that container rather than on the Amazon Linux host.

```bash
mapfile -t CONTAINERS < <(docker ps --filter name=oracle-free --filter status=running -q)
(( ${#CONTAINERS[@]} == 1 )) || { echo 'Container discovery failed' >&2; exit 1; }
CONTAINER_ID=${CONTAINERS[0]}
docker exec -it "$CONTAINER_ID" sqlplus / as sysdba
```

Within SQL*Plus, switch to `FREEPDB1` and verify the active container with `SYS_CONTEXT('USERENV','CON_NAME')`. Use SQL*Plus spooling to create `/opt/lab/evidence/ex3/baseline-plan.txt`. Because `/opt/lab/evidence` is visible in the container, confirm the spool file appears on the host after exiting SQL*Plus.

The baseline evidence must contain:

- The unmodified query from `/opt/lab/workload/reporting-query.sql`.
- One warm-up execution followed by at least three measured executions, retaining every value.
- A displayed cursor plan with runtime row-source statistics, predicates, estimated rows, actual rows, buffers, and elapsed time.
- Relevant table, column, and index statistics metadata for the implicated objects.
- A live observation from `V$SQL` or an available session/system wait view that supports or challenges the simulated clue.
- The returned row count and deterministic checksum compared with `/opt/lab/expected/reporting-query.sha256`.

Use non-AWR facilities such as SQL*Plus timing and `DBMS_XPLAN.DISPLAY_CURSOR`. Enable runtime row-source statistics for the measured statement without changing its business predicates or projection.

At the end of `/opt/lab/evidence/ex3/baseline-plan.txt`, include a concise machine-readable summary using these labels:

```text
container=FREEPDB1
object=OWNER.TABLE_NAME
PLAN_HASH_VALUE=<numeric value>
checksum=<deterministic value>
buffer_gets=<numeric value>
elapsed_ms=<numeric value>
```

Replace the placeholders with measured values. The plan body must also show real operations such as `TABLE ACCESS`, `INDEX ... SCAN`, `HASH JOIN`, or `NESTED LOOPS`.

> [!Caution]
> Do not flush the shared pool, restart the database, create an index, add a hint, change an initialization parameter, or gather schema-wide or database-wide statistics. Those changes would invalidate the comparison.

## Task 3 — Gather targeted statistics and prove improvement

From SQL*Plus inside the dynamically discovered container, use `DBMS_STATS` in `FREEPDB1` to gather only the statistics required for the affected application object or objects. Select options that address the observed cardinality problem. Do not gather all schemas or the whole database.

Retain:

- `/opt/lab/evidence/ex3/stats-change.sql` — the exact targeted PL/SQL call.
- `/opt/lab/evidence/ex3/stats-before-after.txt` — before/after `LAST_ANALYZED` and relevant table, column, histogram, or index metadata.
- `/opt/lab/evidence/ex3/after-plan.txt` — the repeated post-change workload and live plan.
- `/opt/lab/evidence/ex3/tuning-summary.md` — your interpretation and comparison.

Use the same query text, inputs, warm-up procedure, and number of measured executions. The post-change evidence must prove:

- The current Oracle container is `FREEPDB1`.
- The checksum is identical to both the baseline and expected checksum.
- The targeted object's statistics are fresh.
- Estimated and actual cardinalities align more closely at the problematic operation.
- The access path changes as predicted.
- The median of at least three post-change runs improves, or a more stable metric such as buffer gets improves materially.

End `/opt/lab/evidence/ex3/after-plan.txt` with the same machine-readable labels used in the baseline. Use the same `object=OWNER.TABLE_NAME` and checksum values, but record the new numeric plan hash and measured metrics. The validator expects a genuine changed plan and at least a 20 percent improvement in `buffer_gets` or `elapsed_ms`; do not fabricate evidence.

In `/opt/lab/evidence/ex3/tuning-summary.md`, list all measured runtimes, both medians, both plan hashes, access paths, estimated and actual row counts, buffer gets, checksums, and the targeted statistics operation. A `t3.large` can show cache and CPU-credit variation, so a single fast execution is not sufficient.

<question path="Inline-Questions/question-05.md" />

## Task 4 — Build a Docker-aware RMAN verifier

Return to the host root shell. Create the executable host program `/usr/local/sbin/rman-verify.sh`. The host script must invoke RMAN with `docker exec`; it must not look for host copies of `rman`, `sqlplus`, `ORACLE_HOME`, or `/etc/oratab`.

Before implementation, verify the boundary:

```bash
sudo -i
findmnt /u02/backup
systemctl is-active docker
mapfile -t CONTAINERS < <(docker ps --filter name=oracle-free --filter status=running -q)
(( ${#CONTAINERS[@]} == 1 ))
CONTAINER_ID=${CONTAINERS[0]}
docker exec "$CONTAINER_ID" sh -lc 'command -v rman && command -v sqlplus'
install -d -m 0750 /u02/backup/verification
```

Your host script must:

1. Use strict Bash error handling and propagate a nonzero status from Docker, RMAN, log checks, or setup failures.
2. Acquire a nonblocking `flock` lock and fail if another run holds it.
3. Dynamically discover `oracle-free` on every invocation using the required Docker filters.
4. Count matches and fail unless exactly one intended running container exists.
5. Create a unique UTC timestamped log under `/u02/backup/verification/` and capture standard output and standard error.
6. Record UTC start/end times, host, discovered container ID, database, and final exit status without exposing credentials.
7. Run RMAN inside the discovered container with `docker exec`, connecting locally with operating-system authentication.
8. Perform real `CROSSCHECK BACKUP`, archived-log crosscheck, and a non-destructive `RESTORE DATABASE VALIDATE` or equivalent database restore validation.
9. Detect and report unacceptable expired/missing artifacts after crosscheck.
10. Avoid writes to live restored datafiles and never stop or remove the container.
11. Avoid `|| true`, unconditional success text, or any wrapper that hides RMAN's exit status.

Ensure the literal RMAN operations are present in the executable script so validation can inspect them. Use input redirection or a quoted here-document carefully so the RMAN command text reaches RMAN inside the container rather than being interpreted by the host shell.

Run `/usr/local/sbin/rman-verify.sh` manually and retain its successful timestamped log. Test one controlled failure, such as contention on the lock, and verify a nonzero exit status. Correct the condition afterward; do not damage backup files or leave RMAN metadata in a failed state.

Confirm the Oracle instance and container remain available:

```bash
docker ps --filter name=oracle-free --filter status=running
docker exec "$CONTAINER_ID" sqlplus -s / as sysdba <<'SQL'
set heading off feedback off pages 0
select instance_name || ':' || status from v$instance;
exit
SQL
```

## Task 5 — Schedule and verify the host program

Choose one supported host scheduler:

- **systemd:** `/etc/systemd/system/rman-verify.service` and `/etc/systemd/system/rman-verify.timer`
- **cron:** `/etc/cron.d/rman-verify`

Schedule the host program with sufficient permission to access the Docker socket and `/u02/backup`. In this lab, use root for the system service or cron entry; Oracle authentication remains local inside the container. Use absolute paths and do not embed Oracle or AWS passwords.

For systemd, reload units, enable and start the timer, inspect its next run, then start the oneshot service once. Verify the service result rather than assuming that an active timer proves the command succeeded. For cron, inspect the non-comment entry and wait for or trigger an equivalent execution; merely showing that `crond` is active is insufficient.

Save schedule evidence in `/opt/lab/evidence/ex3/schedule.txt`. It must show:

- The installed unit or cron definition.
- An enabled/active timer or installed recurring cron entry.
- The next scheduled run when the scheduler exposes it.
- A completed invocation and its exit result.
- A recent authentic RMAN log under `/u02/backup/verification/`.
- The dynamically discovered container remained running.

## Check your work

```bash
sudo chmod -R a+rX /opt/lab/evidence/ex3
sudo find /opt/lab/evidence/ex3 -maxdepth 1 -type f \
  -printf '%f %s bytes\n' | sort
sudo find /u02/backup/verification -maxdepth 1 -type f \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %f %s bytes\n' | sort | tail
sudo test -x /usr/local/sbin/rman-verify.sh
sudo grep -E 'docker ps|CROSSCHECK|RESTORE.*VALIDATE|flock' \
  /usr/local/sbin/rman-verify.sh
```

Your evidence must support all of these conclusions:

- The reports were clearly treated as simulated AWR/ASH-style clues, not Oracle-generated diagnostics.
- Live `FREEPDB1` measurements corroborated or corrected the initial hypothesis.
- Fresh targeted statistics improved the plan and a deterministic metric.
- Baseline and tuned checksums are identical.
- The host verifier dynamically discovers exactly one running container.
- RMAN crosscheck and non-destructive restore validation run inside that container.
- The schedule is enabled and has a recent authentic successful log.

Validation step 3 is backed by the exact package path `Validations/FREEPDB1 Plan and RMAN Schedule.sh`. The external validator uses AWS Systems Manager Run Command to inspect host, container, Oracle, evidence, scheduler, and log state; allow time for Systems Manager's eventual consistency.

<validation step="682f7e85-022d-4536-a772-1a73a5b94584" />

## Exercise summary

You diagnosed a query regression without claiming that Oracle Database Free generated AWR or ASH. You used repeatable live measurements, corrected only the relevant optimizer statistics, and proved result integrity. You also converted ad hoc RMAN checks into a Docker-aware scheduled control with exclusive execution, durable logs, and truthful failure propagation.
