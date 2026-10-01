#!/bin/bash
set -uo pipefail

# Platform-injected vars (do NOT re-define):
#   ACCOUNT_ID    — AWS account id
#   DEPLOYMENT_ID — CloudLabs deployment id (suffix on lab resources)
#   AWS_REGION    — primary region

count=0
found=false
last_reason="the lab EC2 instance or its SSM results were unavailable"

while [ $count -lt 3 ] && [ "$found" != "true" ]; do
  count=$((count + 1))
  set +e

  instance_rows=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,join(`,`,Tags[].Value)]' \
    --output text 2>/dev/null)
  describe_rc=$?

  instance_id=""
  if [ $describe_rc -eq 0 ]; then
    instance_id=$(printf '%s\n' "$instance_rows" | awk -v deployment="$DEPLOYMENT_ID" 'index($0, deployment) {print $1; exit}')
  fi

  if [ -z "$instance_id" ]; then
    last_reason="no EC2 instance tagged for deployment ${DEPLOYMENT_ID} was found"
    set -e
    if [ $count -lt 3 ]; then sleep 10; fi
    continue
  fi

  remote_script=$(cat <<'REMOTE_SCRIPT'
#!/bin/bash
set -uo pipefail

failures=""
add_failure() {
  if [ -z "$failures" ]; then failures="$1"; else failures="$failures,$1"; fi
}

# Evidence must contain real plans and metrics, not merely a hand-written PASS marker.
evidence_root="/opt/lab/evidence"
baseline_plan=$(find "$evidence_root" -type f \( -iname '*baseline*plan*' -o -iname '*before*plan*' \) -readable 2>/dev/null | head -n 1)
post_plan=$(find "$evidence_root" -type f \( -iname '*post*plan*' -o -iname '*improved*plan*' -o -iname '*after*plan*' \) -readable 2>/dev/null | head -n 1)

if [ -z "$baseline_plan" ] || [ -z "$post_plan" ]; then
  add_failure "plan_evidence_missing"
else
  grep -Eiq 'FREEPDB1' "$baseline_plan" || add_failure "baseline_not_freepdb1"
  grep -Eiq 'FREEPDB1' "$post_plan" || add_failure "post_plan_not_freepdb1"
  grep -Eiq 'Plan hash value|PLAN_HASH_VALUE[[:space:]]*=' "$baseline_plan" || add_failure "baseline_plan_hash_missing"
  grep -Eiq 'Plan hash value|PLAN_HASH_VALUE[[:space:]]*=' "$post_plan" || add_failure "post_plan_hash_missing"
  grep -Eiq 'TABLE ACCESS|INDEX .*SCAN|HASH JOIN|NESTED LOOPS' "$baseline_plan" || add_failure "baseline_operations_missing"
  grep -Eiq 'TABLE ACCESS|INDEX .*SCAN|HASH JOIN|NESTED LOOPS' "$post_plan" || add_failure "post_operations_missing"

  baseline_hash=$(grep -Ei 'Plan hash value|PLAN_HASH_VALUE[[:space:]]*=' "$baseline_plan" | grep -Eo '[0-9]+' | tail -n 1)
  post_hash=$(grep -Ei 'Plan hash value|PLAN_HASH_VALUE[[:space:]]*=' "$post_plan" | grep -Eo '[0-9]+' | tail -n 1)
  if [ -z "$baseline_hash" ] || [ -z "$post_hash" ] || [ "$baseline_hash" = "$post_hash" ]; then
    add_failure "plan_not_improved"
  fi

  baseline_checksum=$(grep -Eio 'checksum[[:space:]:=]+[[:alnum:]_.-]+' "$baseline_plan" | tail -n 1 | sed -E 's/.*[[:space:]:=]+//')
  post_checksum=$(grep -Eio 'checksum[[:space:]:=]+[[:alnum:]_.-]+' "$post_plan" | tail -n 1 | sed -E 's/.*[[:space:]:=]+//')
  if [ -z "$baseline_checksum" ] || [ "$baseline_checksum" != "$post_checksum" ]; then
    add_failure "checksum_mismatch"
  fi

  baseline_gets=$(grep -Eio 'buffer_gets[[:space:]:=]+[0-9]+' "$baseline_plan" | tail -n 1 | grep -Eo '[0-9]+')
  post_gets=$(grep -Eio 'buffer_gets[[:space:]:=]+[0-9]+' "$post_plan" | tail -n 1 | grep -Eo '[0-9]+')
  baseline_ms=$(grep -Eio 'elapsed_ms[[:space:]:=]+[0-9]+' "$baseline_plan" | tail -n 1 | grep -Eo '[0-9]+')
  post_ms=$(grep -Eio 'elapsed_ms[[:space:]:=]+[0-9]+' "$post_plan" | tail -n 1 | grep -Eo '[0-9]+')

  metric_better=false
  if [ -n "$baseline_gets" ] && [ -n "$post_gets" ] && [ "$baseline_gets" -gt 0 ] && [ $((post_gets * 100)) -le $((baseline_gets * 80)) ]; then
    metric_better=true
  fi
  if [ -n "$baseline_ms" ] && [ -n "$post_ms" ] && [ "$baseline_ms" -gt 0 ] && [ $((post_ms * 100)) -le $((baseline_ms * 80)) ]; then
    metric_better=true
  fi
  [ "$metric_better" = "true" ] || add_failure "stable_metric_not_improved"

  # Corroborate the claimed affected object against live FREEPDB1 statistics.
  object_ref=$(grep -Eio '(object|table)[[:space:]:=]+[A-Za-z][A-Za-z0-9_$#]*\.[A-Za-z][A-Za-z0-9_$#]*' "$post_plan" | tail -n 1 | sed -E 's/^[^:= ]+[[:space:]:=]+//')
  if [[ "$object_ref" =~ ^[A-Za-z][A-Za-z0-9_\$#]*\.[A-Za-z][A-Za-z0-9_\$#]*$ ]]; then
    owner=${object_ref%%.*}
    table_name=${object_ref##*.}
    sqlplus=$(find /opt/oracle/product -type f -path '*/bin/sqlplus' -perm /111 2>/dev/null | head -n 1)
    if [ -z "$sqlplus" ]; then
      add_failure "sqlplus_unavailable"
    else
      stats_date=$(printf "whenever sqlerror exit failure\nset heading off feedback off pages 0 verify off echo off\nalter session set container=FREEPDB1;\nselect to_char(max(last_analyzed),'YYYY-MM-DD HH24:MI:SS') from dba_tab_statistics where owner=upper('%s') and table_name=upper('%s');\nexit\n" "$owner" "$table_name" | runuser -u oracle -- env ORACLE_SID=FREE "$sqlplus" -s "/ as sysdba" 2>/dev/null | awk 'NF {line=$0} END {gsub(/^[ \t]+|[ \t]+$/, "", line); print line}')
      stats_epoch=$(date -d "$stats_date UTC" +%s 2>/dev/null)
      now_epoch=$(date -u +%s)
      if [ -z "$stats_epoch" ] || [ $((now_epoch - stats_epoch)) -gt 604800 ] || [ $((now_epoch - stats_epoch)) -lt 0 ]; then
        add_failure "affected_object_stats_not_fresh"
      fi
    fi
  else
    add_failure "affected_object_not_identified"
  fi
fi

# Locate an actual verifier program by RMAN operations; do not trust a success marker.
verifier=""
while IFS= read -r candidate; do
  if grep -Eiq 'CROSSCHECK[[:space:]]+(BACKUP|COPY)|CROSSCHECK[[:space:]]+ARCHIVELOG' "$candidate" \
     && grep -Eiq 'RESTORE[[:space:]]+(DATABASE[[:space:]]+)?VALIDATE|VALIDATE[[:space:]]+DATABASE' "$candidate"; then
    verifier="$candidate"
    break
  fi
done < <(find /usr/local/sbin /usr/local/bin /opt/lab /home -xdev -type f -perm /111 -size -256k 2>/dev/null)

if [ -z "$verifier" ]; then
  add_failure "rman_verifier_missing"
else
  grep -Eq '(^|[^[:alnum:]_])flock([^[:alnum:]_]|$)' "$verifier" || add_failure "overlap_prevention_missing"
  grep -Eq '/u02/backup/' "$verifier" || add_failure "backup_log_path_missing"
  grep -Eq 'date[[:space:]].*[%+]Y|%Y[%_-].*%m|TIMESTAMP' "$verifier" || add_failure "timestamped_log_missing"
  grep -Eq 'set[[:space:]]+-[^#\n]*(e|o[[:space:]]+pipefail)|PIPESTATUS|(^|[;[:space:]])rc=|\$\?' "$verifier" || add_failure "failure_propagation_missing"
  if grep -Eiq 'rman[^#]*(\|\|[[:space:]]*true)|echo[[:space:]].*(success|passed).*(>|tee).*/u02/backup' "$verifier"; then
    add_failure "hard_coded_success_detected"
  fi

  scheduled=false
  while IFS= read -r unit_file; do
    grep -Fq "$verifier" "$unit_file" || continue
    unit_name=$(basename "$unit_file" .service)
    if systemctl is-enabled "${unit_name}.timer" >/dev/null 2>&1 \
       && systemctl is-active "${unit_name}.timer" >/dev/null 2>&1; then
      scheduled=true
      break
    fi
  done < <(find /etc/systemd/system /usr/lib/systemd/system -maxdepth 1 -type f -name '*.service' 2>/dev/null)

  if [ "$scheduled" != "true" ]; then
    while IFS= read -r cron_file; do
      if grep -Ev '^[[:space:]]*(#|$)' "$cron_file" 2>/dev/null | grep -Fq "$verifier"; then
        scheduled=true
        break
      fi
    done < <(find /etc/cron.d /var/spool/cron -type f 2>/dev/null)
  fi
  [ "$scheduled" = "true" ] || add_failure "enabled_schedule_missing"
fi

recent_log=""
while IFS= read -r log_file; do
  # A real RMAN transcript contains operation output, not only a learner-authored PASS line.
  if grep -Eiq 'crosschecked backup piece|validation succeeded|Finished restore at' "$log_file" \
     && grep -Eiq 'Finished restore at|validation succeeded' "$log_file" \
     && ! grep -Eq 'RMAN-[0-9]{5}|ORA-[0-9]{5}' "$log_file"; then
    recent_log="$log_file"
    break
  fi
done < <(find /u02/backup -xdev -type f -mmin -2880 -size -2M 2>/dev/null)
[ -n "$recent_log" ] || add_failure "recent_successful_rman_log_missing"

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
  for _ in $(seq 1 24); do
    status=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' \
      --output text 2>/dev/null)
    case "$status" in
      Success|Cancelled|TimedOut|Failed|Cancelling) break ;;
    esac
    sleep 5
  done

  if [ "$status" = "Success" ]; then
    command_output=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'StandardOutputContent' \
      --output text 2>/dev/null)
    if printf '%s\n' "$command_output" | grep -qx 'VALIDATION3_OK'; then
      found=true
      set -e
      cat <<EOF
{"Status":"Succeeded","Message":"FREEPDB1 plan evidence shows fresh targeted statistics, matching checksums, and a deterministic metric improvement; instance '$instance_id' also has a non-hard-coded RMAN verifier with overlap protection, an enabled schedule, and a recent successful log under /u02/backup in account $ACCOUNT_ID."}
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
    last_reason="SSM command ${command_id} ended with status ${status}"
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
