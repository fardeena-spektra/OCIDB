#!/bin/bash
set -uo pipefail

# Platform-injected vars (do NOT re-define):
#   ACCOUNT_ID    — AWS account id
#   DEPLOYMENT_ID — CloudLabs deployment id
#   AWS_REGION    — primary region
#
# Validator identity needs ec2:DescribeInstances, ssm:SendCommand for the
# target instance and AWS-RunShellScript document, and
# ssm:GetCommandInvocation. The instance role needs AmazonSSMManagedInstanceCore.

count=0
found=false
last_reason="the lab EC2 instance was not discovered"

while [ $count -lt 3 ] && [ "$found" != "true" ]; do
  count=$((count + 1))
  instance_ids=()

  # Discover by deployment tags. The Name fallback supports stacks that encode
  # the deployment ID in resource names instead of a dedicated deployment tag.
  for tag_key in DeploymentID DeploymentId CloudLabsDeploymentId cloudlabs:deployment-id; do
    ids=$(aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --filters "Name=instance-state-name,Values=running" "Name=tag:${tag_key},Values=${DEPLOYMENT_ID}" \
      --query 'Reservations[].Instances[].InstanceId' \
      --output text 2>/dev/null)
    rc=$?
    if [ $rc -eq 0 ] && [ -n "$ids" ] && [ "$ids" != "None" ]; then
      for id in $ids; do
        [[ "$id" =~ ^i-[0-9a-f]+$ ]] && instance_ids+=("$id")
      done
    fi
  done

  ids=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=*${DEPLOYMENT_ID}*" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null)
  rc=$?
  if [ $rc -eq 0 ] && [ -n "$ids" ] && [ "$ids" != "None" ]; then
    for id in $ids; do
      [[ "$id" =~ ^i-[0-9a-f]+$ ]] && instance_ids+=("$id")
    done
  fi

  if [ ${#instance_ids[@]} -gt 0 ]; then
    mapfile -t unique_ids < <(printf '%s\n' "${instance_ids[@]}" | sort -u)
  else
    unique_ids=()
  fi

  if [ ${#unique_ids[@]} -ne 1 ]; then
    last_reason="dynamic discovery found ${#unique_ids[@]} running instances for deployment '${DEPLOYMENT_ID}'"
  else
    instance_id="${unique_ids[0]}"

    # This guest script performs only reads. Exercise 2 creates the protected
    # injection record and tells the learner to save the RMAN transcript at the
    # exact paths below.
    read -r -d '' remote_script <<'REMOTE' || true
#!/bin/bash
set -uo pipefail
record=/opt/lab/evidence/ex2-injection.env
transcript=/opt/lab/evidence/ex2-rman-recovery.log

fail() {
  echo "VALIDATION_FAIL:$1"
  exit 1
}

[ -f "$record" ] || fail "missing protected Exercise 2 injection record"
[ -f "$transcript" ] || fail "missing Exercise 2 RMAN recovery transcript"
[ "$(stat -c '%U' "$record" 2>/dev/null)" = "root" ] || fail "injection record is not root-owned"
mode=$(stat -c '%a' "$record" 2>/dev/null) || fail "cannot inspect injection record permissions"
[ $((8#$mode & 022)) -eq 0 ] || fail "injection record is group/world writable"

field() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$record"
}

pdb=$(field PDB_NAME)
df_num=$(field DATAFILE_NUMBER)
df_path=$(field DATAFILE_PATH)
ts_name=$(field TABLESPACE_NAME)
expected_rows=$(field EXPECTED_ROW_COUNT)
expected_checksum=$(field EXPECTED_CHECKSUM)
expected_resetlogs=$(field RESETLOGS_CHANGE)

[ "$pdb" = "FREEPDB1" ] || fail "injection record does not identify FREEPDB1"
[[ "$df_num" =~ ^[0-9]+$ ]] || fail "invalid recorded datafile number"
[[ "$ts_name" =~ ^[A-Z][A-Z0-9_$#]*$ ]] || fail "invalid recorded tablespace"
[[ "$expected_rows" =~ ^[0-9]+$ ]] || fail "invalid expected row count"
[[ "$expected_checksum" =~ ^[0-9]+$ ]] || fail "invalid expected checksum"
[[ "$expected_resetlogs" =~ ^[0-9]+$ ]] || fail "invalid recorded RESETLOGS change"
[ -n "$df_path" ] && [ -f "$df_path" ] || fail "recovered datafile is absent from its recorded path"

df_base=$(basename "$df_path")
grep -Eiq "FREEPDB1|alter[[:space:]]+session[[:space:]]+set[[:space:]]+container" "$transcript" || fail "transcript lacks explicit FREEPDB1 context"
grep -Eiq "restore[[:space:]]+datafile.*(${df_num}|${df_base})" "$transcript" || fail "transcript lacks targeted datafile restore evidence"
grep -Eiq "recover[[:space:]]+datafile.*(${df_num}|${df_base})" "$transcript" || fail "transcript lacks targeted datafile recovery evidence"
if grep -Eiq "restore[[:space:]]+database|recover[[:space:]]+database|open[[:space:]]+resetlogs" "$transcript"; then
  fail "transcript contains whole-CDB recovery or RESETLOGS evidence"
fi

sql_path=${df_path//\'/\'\'}
sql_text=$(cat <<SQL
set heading off feedback off pagesize 0 verify off echo off termout on trimspool on
whenever sqlerror exit 2
select 'RESETLOGS_CHANGE=' || resetlogs_change# from v\$database;
alter session set container=FREEPDB1;
select 'PDB_OPEN=' || open_mode from v\$pdbs where name='FREEPDB1';
select 'DATAFILE_MATCH=' || count(*) from dba_data_files where file_id=${df_num} and file_name='${sql_path}' and tablespace_name='${ts_name}' and status='AVAILABLE';
select 'TABLESPACE_ONLINE=' || count(*) from dba_tablespaces where tablespace_name='${ts_name}' and status='ONLINE';
select 'RECOVERY_REQUIRED=' || count(*) from v\$recover_file where file#=${df_num};
select 'MARKER_ROWS=' || count(*) from LABAPP.RECOVERY_MARKERS;
select 'MARKER_CHECKSUM=' || nvl(sum(ora_hash(to_char(marker_id,'TM9') || ':' || marker_value,4294967295)),0) from LABAPP.RECOVERY_MARKERS;
exit
SQL
)

sql_out=$(printf '%s\n' "$sql_text" | runuser -u oracle -- bash -c 'export ORACLE_SID=FREE ORAENV_ASK=NO; . /usr/local/bin/oraenv >/dev/null 2>&1; sqlplus -s "/ as sysdba"' 2>&1)
sql_rc=$?
[ $sql_rc -eq 0 ] || fail "Oracle health query failed"

value() {
  printf '%s\n' "$sql_out" | sed -n "s/^[[:space:]]*$1=//p" | tail -1 | tr -d '[:space:]'
}

[ "$(value RESETLOGS_CHANGE)" = "$expected_resetlogs" ] || fail "CDB RESETLOGS identity changed after injection"
[ "$(value PDB_OPEN)" = "READWRITE" ] || fail "FREEPDB1 is not READ WRITE"
[ "$(value DATAFILE_MATCH)" = "1" ] || fail "recorded FREEPDB1 datafile is not available at its original path"
[ "$(value TABLESPACE_ONLINE)" = "1" ] || fail "recovery training tablespace is not online"
[ "$(value RECOVERY_REQUIRED)" = "0" ] || fail "recovered datafile still requires media recovery"
[ "$(value MARKER_ROWS)" = "$expected_rows" ] || fail "recovered marker row count differs from the injection record"
[ "$(value MARKER_CHECKSUM)" = "$expected_checksum" ] || fail "recovered marker checksum differs from the injection record"

echo "VALIDATION_OK:FREEPDB1 datafile ${df_num} is online, recovered, and integrity-checked with targeted RMAN evidence"
REMOTE

    encoded=$(printf '%s' "$remote_script" | base64 | tr -d '\n')
    parameters=$(printf '{"commands":["echo %s | base64 -d | bash"]}' "$encoded")

    command_id=$(aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --comment "CloudLabs read-only Validation 2: FREEPDB1 datafile recovery" \
      --timeout-seconds 120 \
      --parameters "$parameters" \
      --query 'Command.CommandId' \
      --output text 2>/dev/null)
    send_rc=$?

    if [ $send_rc -ne 0 ] || [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
      last_reason="SSM SendCommand failed for instance '${instance_id}'"
    else
      status="Pending"
      for _ in $(seq 1 24); do
        status=$(aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query 'Status' \
          --output text 2>/dev/null)
        get_rc=$?
        if [ $get_rc -eq 0 ] && [[ "$status" =~ ^(Success|Cancelled|TimedOut|Failed|Cancelling)$ ]]; then
          break
        fi
        sleep 5
      done

      if [ "$status" = "Success" ]; then
        command_output=$(aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query 'StandardOutputContent' \
          --output text 2>/dev/null)
        output_rc=$?
        if [ $output_rc -eq 0 ] && grep -q '^VALIDATION_OK:' <<<"$command_output"; then
          found=true
          cat <<EOF
{"Status":"Succeeded","Message":"FREEPDB1 dedicated datafile recovery is healthy and integrity-checked on EC2 instance '${instance_id}' in account ${ACCOUNT_ID}; SSM evidence confirms targeted restore/recovery without a new whole-CDB RESETLOGS."}
EOF
          exit 0
        fi
        last_reason="Oracle checks did not return the expected validation marker on instance '${instance_id}'"
      else
        last_reason="SSM Oracle check on instance '${instance_id}' ended with status '${status}'"
      fi
    fi
  fi

  if [ "$found" != "true" ] && [ $count -lt 3 ]; then
    sleep 10
  fi
done

cat <<EOF
{"Status":"Failed","Message":"FREEPDB1 datafile recovery validation failed in account ${ACCOUNT_ID} after ${count} attempts: ${last_reason}."}
EOF
exit 0
