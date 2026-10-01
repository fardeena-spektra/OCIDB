# Exercise 3 — Diagnose SQL regression and automate backup verification

## Scenario

A reporting query became slower after bulk data changes. You must use the supplied evidence to form a hypothesis, test it against the live `FREEPDB1` workload, make a narrowly scoped optimizer-statistics change, and prove that the result is both faster and correct. You will then operationalize RMAN backup verification.

> [!Important]
> The files named **AWR-style** and **ASH-style** in this exercise are seeded simulations. Oracle Database Free did **not** generate AWR or ASH data. Treat the reports as incident clues, then corroborate them with live execution plans, elapsed-time measurements, row-source statistics, checksums, and dynamic performance views that are available in the lab.

## Objectives

In this exercise, you will:

- Identify the dominant SQL, wait pattern, affected object, and stale or missing statistics indicated by the simulated reports.
- Reproduce the regression in `FREEPDB1` and preserve a defensible baseline.
- Gather statistics only for the affected application object or objects.
- Demonstrate a better access path or stable objective metric without changing the result checksum.
- Build and schedule a safe RMAN verification program with timestamped logs, overlap protection, and meaningful exit status.

## Sign in and connect to the lab instance

1. Open <inject key="AwsConsoleUrl"></inject> and sign in with:
   - **User name:** <inject key="IamUserName"></inject>
   - **Password:** <inject key="IamUserPassword"></inject>

2. Confirm that the console is using AWS account <inject key="AwsAccountId"></inject> and Region <inject key="AwsRegion"></inject>.

3. On the workstation that has your preconfigured AWS CLI profile, assign these displayed lab values to shell variables. Your deployment ID is <inject key="DeploymentID"></inject>, and your Region is <inject key="AwsRegion"></inject>.

   ```bash
   export DEPLOYMENT_ID='paste-the-displayed-deployment-id'
   export AWS_REGION='paste-the-displayed-region'
   aws sts get-caller-identity
   ```

4. Locate the running lab instance by its CloudFormation stack-name tag. Keep the filter narrow so you do not connect to another candidate's instance.

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

5. Start an AWS Systems Manager Session Manager shell. AWS requires the Session Manager plugin when `start-session` is invoked from the CLI.

   ```bash
   aws ssm start-session --region "$AWS_REGION" --target "$INSTANCE_ID"
   ```

6. In the managed-node shell, obtain a root login shell and confirm that bootstrap completed. Do not print credential files or place passwords in evidence.

   ```bash
   sudo -i
   test -f /opt/lab/.ready
   findmnt /u02/backup
   systemctl is-active amazon-ssm-agent
   ```

> [!Note]
> If CLI Session Manager is unavailable, use **AWS Systems Manager → Node Management → Session Manager → Start session**, select the lab managed node, and choose **Start session**. Do not weaken the security group to work around an SSM client problem.

## Task 1 — Build a diagnosis from the simulated evidence

Create the evidence directory and preserve a session transcript. Do not alter the supplied reports.

```bash
install -d -o oracle -g oinstall /opt/lab/evidence/ex3
script -q -a /opt/lab/evidence/ex3/diagnosis-session.txt
```

Review these seeded files:

- `/opt/lab/diagnostics/simulated-awr-style.txt`
- `/opt/lab/diagnostics/simulated-ash-style.txt`
- `/opt/lab/workload/reporting-query.sql`
- `/opt/lab/expected/reporting-query.sha256`

Record your findings in `/opt/lab/evidence/ex3/diagnosis.md`. Your diagnosis must identify:

1. The dominant SQL identifier or statement signature.
2. The dominant wait class/event pattern and whether it points primarily to I/O, CPU, or locking.
3. The table or index implicated by the evidence.
4. The evidence for stale, missing, or unrepresentative optimizer statistics.
5. A testable prediction for the baseline plan and estimated-versus-actual rows.

Do not cite the simulated reports as proof of live behavior. Use them only to select what you will measure next.

<question path="Inline-Questions/question-04.md" />

## Task 2 — Reproduce and capture a live baseline in `FREEPDB1`

Work as the Oracle software owner and connect explicitly to `FREEPDB1`. Before running the workload, prove the container context and spool all output.

```bash
sudo -iu oracle
export ORACLE_SID=FREE
mkdir -p /opt/lab/evidence/ex3
sqlplus / as sysdba
```

Inside SQL*Plus, set the container to `FREEPDB1`, confirm it with `SYS_CONTEXT('USERENV','CON_NAME')`, and capture the baseline in `/opt/lab/evidence/ex3/baseline.txt`.

Your baseline must contain all of the following:

- The unmodified SQL from `/opt/lab/workload/reporting-query.sql`.
- At least three timed executions after one warm-up execution; retain every measured value rather than only the best run.
- The displayed cursor plan with runtime row-source statistics, including predicates, estimated rows, actual rows, buffers, and elapsed time.
- Relevant optimizer-statistics metadata for the implicated application objects in `FREEPDB1`.
- A live dynamic-performance-view observation that supports or challenges the simulated wait evidence.
- The returned row count and deterministic checksum, compared with `/opt/lab/expected/reporting-query.sha256`.

Use non-AWR facilities such as SQL*Plus timing, `DBMS_XPLAN.DISPLAY_CURSOR`, `V$SQL`, and available session/system wait views. Ensure the statement gathers runtime row-source statistics, but do not edit its business predicates or result projection.

> [!Caution]
> Do not flush the shared pool, restart the database, create an index, add a hint, change an initialization parameter, or gather schema-wide/database-wide statistics. Those changes would confound the required comparison.

## Task 3 — Gather targeted statistics and prove improvement

Based on your baseline, use `DBMS_STATS` in `FREEPDB1` to gather only the statistics needed for the affected application object or objects. Select options that address the cardinality problem you observed; do not gather all schemas or the whole database.

Save the exact PL/SQL call and before/after statistics metadata in:

- `/opt/lab/evidence/ex3/stats-change.sql`
- `/opt/lab/evidence/ex3/stats-before-after.txt`

Re-run the same workload under the same measurement procedure and spool `/opt/lab/evidence/ex3/after-stats.txt`. Your comparison must show:

- The container is still `FREEPDB1`.
- The SQL text and bind/literal inputs are unchanged.
- The checksum exactly matches the baseline and expected checksum.
- Statistics timestamps and relevant column/index/table metadata reflect the targeted operation.
- Estimated and actual cardinalities are better aligned at the problematic operation.
- The access path improves in the way predicted by your diagnosis.
- The median of at least three measured post-change executions improves, or another stable plan metric such as buffer gets improves materially.

Summarize the comparison in `/opt/lab/evidence/ex3/tuning-summary.md`. Include the before/after plan hash values, access paths, estimated-versus-actual row counts, buffer gets, all measured runtimes, medians, and checksums. CPU-credit and cache variation on a `t3.large` can affect wall-clock time, so do not rely on a single fast execution.

<question path="Inline-Questions/question-05.md" />

## Task 4 — Implement safe RMAN verification

Return to a root shell and create the executable program `/usr/local/sbin/rman-verify.sh`. It must perform real checks rather than print a predetermined success message.

Your program must:

1. Enable strict Bash error handling and propagate a nonzero exit code when any required RMAN operation or post-check fails.
2. Prevent overlapping runs with an advisory lock, and treat inability to acquire that lock as a failure.
3. Create a new UTC timestamped log below `/u02/backup/verification/` for each run.
4. Run RMAN `CROSSCHECK` for the backup and archived-log records used by this lab.
5. Report expired or missing artifacts after crosscheck and fail if unacceptable artifacts remain.
6. Run restore validation without writing restored database files or overwriting backup pieces.
7. Capture both standard output and standard error in the run log.
8. Record start time, end time, host, database, and final exit status without exposing credentials.

Keep the Oracle environment explicit because systemd and cron do not inherit your interactive shell. Before scheduling, inspect the configured Oracle home and RMAN path rather than assuming them.

```bash
sudo -i
readlink -f "$(command -v rman || true)"
grep -v '^[[:space:]]*#' /etc/oratab
findmnt /u02/backup
install -d -m 0750 -o oracle -g oinstall /u02/backup/verification
```

Run the program manually once and preserve the resulting successful log. Verify that the log contains the RMAN crosscheck, expired/missing-artifact assessment, restore validation, and final status. Also test at least one controlled failure path, then correct it; do not leave the schedule or backup catalog in a failed state.

## Task 5 — Schedule and verify the program

Choose **systemd** or **cron**. For systemd, use these concrete unit paths:

- `/etc/systemd/system/rman-verify.service`
- `/etc/systemd/system/rman-verify.timer`

For cron, use `/etc/cron.d/rman-verify`. In either case, run as the Oracle software owner, use absolute paths, and schedule recurring execution. Do not embed database or AWS passwords.

After enabling the schedule, trigger one execution and retain proof in `/opt/lab/evidence/ex3/schedule.txt`. The proof must show:

- The schedule is installed and enabled or active as appropriate.
- The next scheduled run is visible.
- A manual scheduled invocation completed successfully.
- A recent timestamped successful log exists under `/u02/backup/verification/`.
- The program itself, not a wrapper with hard-coded output, produced that log.

If you selected systemd, inspect the service's exit result and timer state. If you selected cron, inspect the installed crontab entry and the resulting program log; merely showing that the cron daemon is active is insufficient.

## Check your work

Confirm that your evidence set is complete and readable without modifying the seeded reports:

```bash
sudo find /opt/lab/evidence/ex3 -maxdepth 1 -type f -printf '%f %s bytes\n' | sort
sudo find /u02/backup/verification -maxdepth 1 -type f -printf '%TY-%Tm-%TdT%TH:%TM:%TS %f %s bytes\n' | sort | tail
sudo test -x /usr/local/sbin/rman-verify.sh
```

Your final evidence must support these conclusions:

- The simulated AWR/ASH-style clues led to a diagnosis that live non-AWR observations corroborated.
- Targeted statistics improved cardinality estimates and the access path or a stable objective metric.
- The result checksum did not change.
- RMAN crosscheck and restore validation execute safely, report real failures, and do not restore over live files.
- Recurring verification is enabled and has produced a recent successful timestamped log.

Validation 3 is backed by the exact script path `Validations/FREEPDB1 Plan and RMAN Schedule.sh`.

<validation step="3" />

## Exercise summary

You diagnosed a reporting regression without claiming that Oracle Database Free generated AWR or ASH. You compared repeatable live measurements, corrected only the relevant optimizer statistics, and proved both performance improvement and result integrity. You also converted ad hoc RMAN checks into a scheduled verification control with overlap prevention, durable logs, and truthful failure propagation.