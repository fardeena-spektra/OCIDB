#!/bin/bash
set -uo pipefail

# Platform-injected vars (do NOT re-define):
#   ACCOUNT_ID    — AWS account id
#   DEPLOYMENT_ID — CloudLabs deployment id (suffix on lab resources)
#   AWS_REGION    — primary region

count=0
found=false
last_reason="the deployment instance or its SSM result was unavailable"

while [ $count -lt 3 ] && [ "$found" != "true" ]; do
  count=$((count + 1))
  set +e

  caller_account=$(aws sts get-caller-identity \
    --region "$AWS_REGION" \
    --query 'Account' \
    --output text 2>/dev/null)
  caller_rc=$?

  instance_ids=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag:aws:cloudformation:stack-name,Values=*$DEPLOYMENT_ID*" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null)
  describe_rc=$?

  instance_count=$(printf '%s\n' "$instance_ids" | awk '{for (i=1;i<=NF;i++) n++} END {print n+0}')
  if [ $caller_rc -ne 0 ] || [ "$caller_account" != "$ACCOUNT_ID" ]; then
    last_reason="the configured AWS CLI identity did not match account ${ACCOUNT_ID}"
    set -e
    if [ $count -lt 3 ]; then sleep 10; fi
    continue
  fi
  if [ $describe_rc -ne 0 ] || [ "$instance_count" -ne 1 ]; then
    last_reason="expected exactly one running EC2 instance for deployment ${DEPLOYMENT_ID}, found ${instance_count}"
    set -e
    if [ $count -lt 3 ]; then sleep 10; fi
    continue
  fi
  instance_id=$(printf '%s\n' "$instance_ids" | awk '{print $1}')

  remote_script=$(cat <<'REMOTE_SCRIPT'
#!/bin/bash
set -uo pipefail

failures=""
add_failure() {
  if [ -z "$failures" ]; then failures="$1"; else failures="$failures,$1"; fi
}

# Resolve the intended running container at validation time. A name is not used as
# the docker-exec target, and an ambiguous match is a failure.
mapfile -t container_ids < <(docker ps --filter name=oracle-free --filter status=running -q 2>/dev/null)
if [ "${#container_ids[@]}" -ne 1 ]; then
  add_failure "running_container_count_${#container_ids[@]}"
  CONTAINER_ID=""
else
  CONTAINER_ID="${container_ids[0]}"
  container_name=$(docker inspect --format '{{.Name}}' "$CONTAINER_ID" 2>/dev/null)
  [ "$container_name" = "/oracle-free" ] || add_failure "resolved_container_not_oracle_free"
fi

ex3=/opt/lab/evidence/ex3
baseline="$ex3/baseline.txt"
after="$ex3/after-stats.txt"
stats_sql="$ex3/stats-change.sql"
stats_evidence="$ex3/stats-before-after.txt"
summary="$ex3/tuning-summary.md"
diagnosis="$ex3/diagnosis.md"

for evidence in "$diagnosis" "$baseline" "$after" "$stats_sql" "$stats_evidence" "$summary"; do
  [ -s "$evidence" ] || add_failure "missing_$(basename "$evidence" | tr '.-' '__')"
done

# Require retained, live plan output rather than a learner-authored PASS token.
if [ -s "$baseline" ] && [ -s "$after" ]; then
  grep -Eiq 'FREEPDB1' "$baseline" || add_failure "baseline_not_freepdb1"
  grep -Eiq 'FREEPDB1' "$after" || add_failure "after_not_freepdb1"
  grep -Eiq 'Plan hash value|PLAN_HASH_VALUE' "$baseline" || add_failure "baseline_plan_hash_missing"
  grep -Eiq 'Plan hash value|PLAN_HASH_VALUE' "$after" || add_failure "after_plan_hash_missing"
  grep -Eiq 'E-Rows|A-Rows|Starts' "$baseline" || add_failure "baseline_runtime_rows_missing"
  grep -Eiq 'E-Rows|A-Rows|Starts' "$after" || add_failure "after_runtime_rows_missing"
  grep -Eiq 'Buffers|buffer_gets' "$baseline" || add_failure "baseline_buffers_missing"
  grep -Eiq 'Buffers|buffer_gets' "$after" || add_failure "after_buffers_missing"
  grep -Eiq 'TABLE ACCESS|INDEX .*SCAN|HASH JOIN|NESTED LOOPS' "$baseline" || add_failure "baseline_operations_missing"
  grep -Eiq 'TABLE ACCESS|INDEX .*SCAN|HASH JOIN|NESTED LOOPS' "$after" || add_failure "after_operations_missing"

  baseline_checksum=$(grep -Eio '(checksum|sha256)[[:space:]:=]+[[:alnum:]_.-]+' "$baseline" | tail -n 1 | sed -E 's/.*[[:space:]:=]+//')
  after_checksum=$(grep -Eio '(checksum|sha256)[[:space:]:=]+[[:alnum:]_.-]+' "$after" | tail -n 1 | sed -E 's/.*[[:space:]:=]+//')
  expected_checksum=$(tr -d '[:space:]' </opt/lab/expected/reporting-query.sha256 2>/dev/null | awk '{print $1}')
  if [ -z "$baseline_checksum" ] || [ -z "$after_checksum" ] || [ "$baseline_checksum" != "$after_checksum" ]; then
    add_failure "before_after_checksum_mismatch"
  fi
  if [ -n "$expected_checksum" ] && [ "$after_checksum" != "$expected_checksum" ]; then
    add_failure "expected_checksum_mismatch"
  fi
fi

# The guide requires at least three before and after measurements and a deterministic
# comparison. Accept elapsed_ms or runtime_ms labels and require a material median or
# buffer-get improvement recorded in the summary.
if [ -s "$summary" ]; then
  grep -Eiq 'before.*plan.*hash|baseline.*plan.*hash' "$summary" || add_failure "summary_before_hash_missing"
  grep -Eiq 'after.*plan.*hash|post.*plan.*hash' "$summary" || add_failure "summary_after_hash_missing"
  grep -Eiq 'estimated.*actual|E-Rows.*A-Rows|cardinalit' "$summary" || add_failure "cardinality_comparison_missing"
  grep -Eiq 'checksum' "$summary" || add_failure "summary_checksum_missing"

  before_times=$(grep -Eio '(before|baseline)[^0-9\n]*(elapsed|runtime)?[^0-9\n]*[0-9]+([.][0-9]+)?[[:space:]]*(ms|milliseconds)' "$summary" | wc -l)
  after_times=$(grep -Eio '(after|post)[^0-9\n]*(elapsed|runtime)?[^0-9\n]*[0-9]+([.][0-9]+)?[[:space:]]*(ms|milliseconds)' "$summary" | wc -l)
  if [ "$before_times" -lt 3 ] || [ "$after_times" -lt 3 ]; then
    grep -Eiq '(three|3).*(before|baseline).*(three|3).*(after|post)|(before|baseline).*(runs|executions).*[0-9].*[0-9].*[0-9]' "$summary" || add_failure "three_run_measurements_missing"
  fi

  grep -Eiq '(median|buffer gets|buffer_gets).*(improv|reduc|lower|before.*after)|(before.*after).*(median|buffer gets|buffer_gets)' "$summary" || add_failure "deterministic_improvement_missing"
fi

# Require a targeted DBMS_STATS operation and reject broad statistics gathering.
object_owner=""
object_name=""
if [ -s "$stats_sql" ]; then
  grep -Eiq 'DBMS_STATS[.]GATHER_TABLE_STATS' "$stats_sql" || add_failure "targeted_table_stats_missing"
  if grep -Eiq 'GATHER_(SCHEMA|DATABASE|DICTIONARY|FIXED_OBJECTS)_STATS' "$stats_sql"; then
    add_failure "broad_stats_gather_detected"
  fi
  object_owner=$(sed -nE "s/.*ownname[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/ip" "$stats_sql" | tail -n 1)
  object_name=$(sed -nE "s/.*tabname[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/ip" "$stats_sql" | tail -n 1)
  [ -n "$object_owner" ] && [ -n "$object_name" ] || add_failure "target_stats_object_not_identified"
fi

# Corroborate the named object's targeted statistics against the live PDB through
# the dynamically resolved container.
if [ -n "$CONTAINER_ID" ] && [ -n "$object_owner" ] && [ -n "$object_name" ]; then
  stats_result=$(docker exec -i "$CONTAINER_ID" sqlplus -s / as sysdba 2>/dev/null <<SQL
whenever sqlerror exit failure
set heading off feedback off pages 0 verify off echo off
alter session set container=FREEPDB1;
select sys_context('USERENV','CON_NAME')||'|'||count(*)||'|'||to_char(max(last_analyzed),'YYYY-MM-DD HH24:MI:SS')
from dba_tab_statistics
where owner=upper('$object_owner') and table_name=upper('$object_name');
exit
SQL
)
  stats_rc=$?
  stats_line=$(printf '%s\n' "$stats_result" | grep -E '^FREEPDB1[|][0-9]+[|]' | tail -n 1)
  stats_count=$(printf '%s' "$stats_line" | cut -d'|' -f2)
  stats_date=$(printf '%s' "$stats_line" | cut -d'|' -f3)
  stats_epoch=$(date -u -d "$stats_date UTC" +%s 2>/dev/null)
  now_epoch=$(date -u +%s)
  if [ $stats_rc -ne 0 ] || [ -z "$stats_line" ] || [ "${stats_count:-0}" -lt 1 ]; then
    add_failure "live_target_stats_unverified"
  elif [ -z "$stats_epoch" ] || [ $((now_epoch - stats_epoch)) -lt 0 ] || [ $((now_epoch - stats_epoch)) -gt 604800 ]; then
    add_failure "live_target_stats_not_fresh"
  fi
fi

verifier=/usr/local/sbin/rman-verify.sh
if [ ! -f "$verifier" ] || [ ! -x "$verifier" ]; then
  add_failure "executable_rman_verifier_missing"
else
  # Dynamic discovery must be implemented by the learner program itself.
  grep -Eq 'docker[[:space:]]+ps[^\n]*--filter[=[:space:]]+["'"']?name=oracle-free' "$verifier" || add_failure "verifier_dynamic_name_filter_missing"
  grep -Eq 'docker[[:space:]]+ps[^\n]*--filter[=[:space:]]+["'"']?status=running' "$verifier" || add_failure "verifier_running_filter_missing"
  grep -Eq 'docker[[:space:]]+ps[^\n]*-q|--quiet' "$verifier" || add_failure "verifier_container_id_query_missing"
  grep -Eq '(wc[[:space:]]+-l|mapfile|readarray|#[{][^}]+[@][}]).*(1|-ne[[:space:]]+1|-eq[[:space:]]+1)|-ne[[:space:]]+1|-eq[[:space:]]+1' "$verifier" || add_failure "verifier_ambiguity_check_missing"
  grep -Eq 'docker[[:space:]]+exec[^\n]*\$(\{)?CONTAINER_ID|docker[[:space:]]+exec[^\n]*"\$(\{)?CONTAINER_ID' "$verifier" || add_failure "verifier_does_not_exec_resolved_id"

  # Reject literal container targets/IDs and scripts that can manufacture success.
  if grep -Eq 'docker[[:space:]]+exec[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*["'"']?oracle-free(["'"']|[[:space:]])' "$verifier"; then
    add_failure "hardcoded_container_name_detected"
  fi
  if grep -Eq 'docker[[:space:]]+(exec|inspect)[^#\n]*[[:space:]][0-9a-f]{12,64}([[:space:]]|$)' "$verifier"; then
    add_failure "hardcoded_container_id_detected"
  fi
  if grep -Eiq '(^|[;&|[:space:]])(true|:)[[:space:]]*(#.*)?$|rman[^#\n]*[|][|][[:space:]]*true|exit[[:space:]]+0[[:space:]]*(#.*)?$' "$verifier"; then
    add_failure "hardcoded_success_or_masked_failure_detected"
  fi

  grep -Eiq 'CROSSCHECK[[:space:]]+BACKUP' "$verifier" || add_failure "rman_crosscheck_backup_missing"
  grep -Eiq 'CROSSCHECK[[:space:]]+ARCHIVELOG' "$verifier" || add_failure "rman_crosscheck_archivelog_missing"
  grep -Eiq 'RESTORE[[:space:]]+DATABASE[[:space:]]+VALIDATE|RESTORE[[:space:]]+VALIDATE[[:space:]]+DATABASE|VALIDATE[[:space:]]+DATABASE' "$verifier" || add_failure "rman_restore_validation_missing"
  grep -Eiq 'EXPIRED|LIST[[:space:]]+EXPIRED|missing' "$verifier" || add_failure "expired_artifact_check_missing"
  grep -Eq 'flock[[:space:]]+(-n|--nonblock)|flock[^\n]*-n' "$verifier" || add_failure "nonblocking_lock_missing"
  grep -Eq '/u02/backup/verification/' "$verifier" || add_failure "verification_log_directory_missing"
  grep -Eq 'date[^\n]*(%Y|--iso-8601)|TIMESTAMP=' "$verifier" || add_failure "utc_timestamped_log_missing"
  grep -Eq 'set[[:space:]]+-[^#\n]*e[^#\n]*o[[:space:]]+pipefail|set[[:space:]]+-[^#\n]*o[[:space:]]+pipefail' "$verifier" || add_failure "strict_failure_handling_missing"
  grep -Eq 'PIPESTATUS|trap[^\n]*(ERR|EXIT)|exit[[:space:]]+["'"']?\$[A-Za-z_]|return[[:space:]]+["'"']?\$[A-Za-z_]' "$verifier" || add_failure "failure_status_propagation_missing"
  grep -Eiq '(start|started).*(time|date)|START_TIME' "$verifier" || add_failure "log_start_metadata_missing"
  grep -Eiq '(end|finished).*(time|date)|END_TIME' "$verifier" || add_failure "log_end_metadata_missing"
  grep -Eiq 'hostname|HOST=' "$verifier" || add_failure "log_host_metadata_missing"
  grep -Eiq 'database|ORACLE_SID|DB_NAME' "$verifier" || add_failure "log_database_metadata_missing"
fi

# Confirm that the exact verifier is recurring and enabled.
scheduled=false
if [ -f /etc/systemd/system/rman-verify.service ] && [ -f /etc/systemd/system/rman-verify.timer ]; then
  if grep -Eq '^[[:space:]]*ExecStart=[^#]*\/usr\/local\/sbin\/rman-verify[.]sh([[:space:]]|$)' /etc/systemd/system/rman-verify.service \
     && systemctl is-enabled rman-verify.timer >/dev/null 2>&1 \
     && systemctl is-active rman-verify.timer >/dev/null 2>&1 \
     && systemctl show rman-verify.timer -p NextElapseUSecRealtime --value 2>/dev/null | grep -qv '^n/a$'; then
    scheduled=true
  fi
fi
if [ -f /etc/cron.d/rman-verify ]; then
  cron_entry=$(grep -Ev '^[[:space:]]*(#|$)' /etc/cron.d/rman-verify 2>/dev/null | grep -F '/usr/local/sbin/rman-verify.sh' | head -n 1)
  if [ -n "$cron_entry" ] \
     && printf '%s\n' "$cron_entry" | grep -Eq '^[[:space:]]*([^[:space:]]+[[:space:]]+){5}(oracle|[0-9]+)[[:space:]]+' \
     && (systemctl is-active crond >/dev/null 2>&1 || systemctl is-active cron >/dev/null 2>&1); then
    scheduled=true
  fi
fi
[ "$scheduled" = "true" ] || add_failure "enabled_recurring_schedule_missing"

# Authenticate a recent run from substantive RMAN transcript content. A lone PASS
# line cannot satisfy these checks.
recent_log=""
while IFS= read -r log_file; do
  [ -f "$log_file" ] || continue
  grep -Eiq 'Recovery Manager: Release|connected to target database' "$log_file" || continue
  grep -Eiq 'crosschecked backup piece|crosschecked archived log|validation succeeded' "$log_file" || continue
  grep -Eiq 'Finished restore at|validation succeeded' "$log_file" || continue
  grep -Eiq '(start|started).*(UTC|time|date)|START_TIME' "$log_file" || continue
  grep -Eiq '(end|finished).*(UTC|time|date)|END_TIME' "$log_file" || continue
  grep -Eiq '(host|hostname)[[:space:]:=]' "$log_file" || continue
  grep -Eiq '(database|db_name|oracle_sid)[[:space:]:=]' "$log_file" || continue
  grep -Eiq '(final[ _-]?(exit[ _-]?)?status|exit[ _-]?code)[[:space:]:=]+(0|success)' "$log_file" || continue
  grep -Eq 'RMAN-[0-9]{5}|ORA-[0-9]{5}' "$log_file" && continue
  recent_log="$log_file"
  break
done < <(find /u02/backup/verification -xdev -type f -mmin -2880 -size +200c -size -5M -print 2>/dev/null | sort -r)
[ -n "$recent_log" ] || add_failure "recent_authentic_successful_log_missing"

if [ -z "$failures" ]; then
  echo "VALIDATION3_OK"
else
  echo "VALIDATION3_FAILED:$failures"
fi
REMOTE_SCRIPT
)

  payload=$(printf '%s' "$remote_script" | base64 | tr -d '\n')
  command_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "CloudLabs read-only Validation 3" \
    --parameters "commands=[\"echo '$payload' | base64 -d | bash\"]" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)
  send_rc=$?

  if [ $send_rc -ne 0 ] || [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
    last_reason="SSM Run Command could not start on instance ${instance_id}"
    set -e
    if [ $count -lt 3 ]; then sleep 10; fi
    continue
  fi

  status="Pending"
  response_code=-1
  for _ in $(seq 1 30); do
    invocation=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query '[Status,ResponseCode]' \
      --output text 2>/dev/null)
    invocation_rc=$?
    if [ $invocation_rc -eq 0 ]; then
      status=$(printf '%s\n' "$invocation" | awk '{print $1}')
      response_code=$(printf '%s\n' "$invocation" | awk '{print $2}')
      case "$status" in
        Success|Cancelled|TimedOut|Failed|Cancelling) break ;;
      esac
    fi
    sleep 5
  done

  if [ "$status" = "Success" ] && [ "$response_code" = "0" ]; then
    command_output=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'StandardOutputContent' \
      --output text 2>/dev/null)
    output_rc=$?
    if [ $output_rc -eq 0 ] && printf '%s\n' "$command_output" | grep -qx 'VALIDATION3_OK'; then
      found=true
      set -e
      cat <<EOF
{"Status":"Succeeded","Message":"Instance '$instance_id' in account $ACCOUNT_ID has authentic FREEPDB1 before/after tuning evidence with fresh targeted statistics and matching checksums, plus a dynamically container-aware RMAN verifier with validation, locking, failure propagation, an enabled recurring schedule, and a recent successful transcript."}
EOF
      exit 0
    fi
    failure_codes=$(printf '%s\n' "$command_output" | sed -n 's/^VALIDATION3_FAILED://p' | tail -n 1)
    if [ -n "$failure_codes" ]; then
      last_reason="guest checks failed: ${failure_codes}"
    else
      last_reason="SSM completed but returned no authentic Validation 3 result"
    fi
  else
    last_reason="SSM command ${command_id} ended with status ${status} and response code ${response_code}"
  fi

  set -e
  if [ "$found" != "true" ] && [ $count -lt 3 ]; then
    sleep 10
  fi
done

cat <<EOF
{"Status":"Failed","Message":"Validation 3 failed for deployment '$DEPLOYMENT_ID' in account $ACCOUNT_ID after $count attempts: $last_reason."}
EOF
exit 0
