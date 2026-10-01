#!/bin/bash
set -uo pipefail

# Platform-injected vars (do NOT re-define):
#   ACCOUNT_ID    — AWS account id
#   DEPLOYMENT_ID — CloudLabs deployment id
#   AWS_REGION    — primary region

count=0
found=false
last_reason="the lab EC2 instance was not discovered"

while [ $count -lt 3 ] && [ "$found" != "true" ]; do
  count=$((count + 1))
  instance_ids=()

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
    last_reason="dynamic discovery found ${#unique_ids[@]} running instances for deployment ${DEPLOYMENT_ID}"
  else
    instance_id="${unique_ids[0]}"

    read -r -d '' remote_script <<'REMOTE' || true
#!/bin/bash
set -uo pipefail

fail() {
  echo "VALIDATION_FAIL:$1"
  exit 1
}

record=/opt/lab/state/ex2.env
[ -f /opt/lab/.ready ] || fail "general lab readiness marker is missing"
mountpoint -q /u02/backup || fail "backup storage is not mounted"
[ -f "$record" ] || fail "missing protected Exercise 2 injection state"
[ "$(stat -c '%U:%G' "$record" 2>/dev/null)" = "root:root" ] || fail "Exercise 2 injection state is not owned by root"
record_mode=$(stat -c '%a' "$record" 2>/dev/null) || fail "cannot inspect Exercise 2 state permissions"
[ $((8#$record_mode & 022)) -eq 0 ] || fail "Exercise 2 injection state is group/world writable"

field() {
  awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$record"
}
first_field() {
  local key value
  for key in "$@"; do
    value=$(field "$key")
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

# Exercise 2 is deliberately independent. Never read or test Exercise 1 state,
# a PITR result, or an Exercise 1 post-RESETLOGS marker.
pdb=$(first_field PDB_NAME PDB 2>/dev/null || true)
tablespace=$(first_field TABLESPACE_NAME TABLESPACE 2>/dev/null || true)
file_no=$(first_field DATAFILE_NUMBER FILE_NO 2>/dev/null || true)
container_path=$(first_field CONTAINER_DATAFILE_PATH CONTAINER_FILE DATAFILE_PATH 2>/dev/null || true)
recorded_host_path=$(first_field HOST_DATAFILE_PATH HOST_FILE HOST_PATH 2>/dev/null || true)
expected_checksum=$(first_field EXPECTED_CHECKSUM PRELOSS_CHECKSUM 2>/dev/null || true)
expected_resetlogs=$(first_field RESETLOGS_CHANGE RESETLOGS_SCN CURRENT_RESETLOGS_SCN 2>/dev/null || true)
backup_resetlogs=$(first_field BACKUP_RESETLOGS_CHANGE BACKUP_RESETLOGS_SCN LEVEL0_RESETLOGS_SCN 2>/dev/null || true)
backup_provenance=$(first_field BACKUP_PROVENANCE LEVEL0_BACKUP_PROVENANCE SAFETY_BACKUP_PROVENANCE 2>/dev/null || true)
injected_utc=$(first_field INJECTED_UTC INJECTION_UTC UTC 2>/dev/null || true)

[ -z "$pdb" ] && pdb=FREEPDB1
[ -z "$tablespace" ] && tablespace=LABRECOVERY
[ "$pdb" = "FREEPDB1" ] || fail "injection state does not identify FREEPDB1"
[ "$tablespace" = "LABRECOVERY" ] || fail "injection state does not identify LABRECOVERY"
[[ "$file_no" =~ ^[0-9]+$ ]] || fail "injection state has an invalid datafile number"
[[ "$expected_checksum" =~ ^[0-9]+:[0-9]+$ ]] || fail "injection state has an invalid pre-loss row-count/checksum"
[[ "$expected_resetlogs" =~ ^[0-9]+$ ]] || fail "injection state has an invalid current-incarnation identity"
[[ "$backup_resetlogs" =~ ^[0-9]+$ ]] || fail "injection state does not record the level 0 backup incarnation"
[ "$backup_resetlogs" = "$expected_resetlogs" ] || fail "recorded level 0 backup is not from the incident's current incarnation"
[[ "$injected_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "injection state has no valid UTC timestamp"

normalized_provenance=$(printf '%s' "$backup_provenance" | tr '[:lower:] -' '[:upper:]__')
case "$normalized_provenance" in
  LEARNER|LEARNER_CREATED|EXISTING|EXISTING_LEARNER_BACKUP)
    normalized_provenance=LEARNER_CREATED
    ;;
  INJECTOR|INJECTOR_CREATED|SAFETY|SAFETY_BACKUP|INJECT_EX2_CREATED)
    normalized_provenance=INJECTOR_CREATED
    ;;
  *)
    fail "injection state does not explicitly record learner-created or injector-created level 0 provenance"
    ;;
esac

[[ "$container_path" =~ ^/opt/oracle/oradata/[A-Za-z0-9._/-]+$ ]] || fail "recorded container datafile path is outside /opt/oracle/oradata"
[[ "$container_path" != *"/../"* && "$container_path" != */.. ]] || fail "recorded container datafile path contains traversal"
[[ "$(basename "$container_path")" =~ ^[A-Za-z0-9._-]+\.dbf$ ]] || fail "recorded target is not a database datafile"
case "${container_path,,}" in
  *system*|*sysaux*|*undo*|*temp*|*control*|*redo*) fail "protected Oracle file class appears in the recorded target path" ;;
esac

# Dynamically resolve exactly one intended running container. No container ID is
# persisted in this validator or accepted from injection state.
mapfile -t container_ids < <(docker ps --filter name=oracle-free --filter status=running -q 2>/dev/null)
[ ${#container_ids[@]} -eq 1 ] || fail "expected exactly one running oracle-free container"
CONTAINER_ID="${container_ids[0]}"
[[ "$CONTAINER_ID" =~ ^[0-9a-f]+$ ]] || fail "Docker returned an invalid container identifier"
[ "$(docker inspect --format '{{.Name}}' "$CONTAINER_ID" 2>/dev/null)" = "/oracle-free" ] || fail "resolved container is not exactly oracle-free"

mounts=$(docker inspect --format '{{range .Mounts}}{{printf "%s|%s\n" .Source .Destination}}{{end}}' "$CONTAINER_ID" 2>/dev/null) || fail "cannot inspect Oracle bind mounts"
printf '%s\n' "$mounts" | grep -Fxq '/u01/oradata|/opt/oracle/oradata' || fail "required Oracle data bind mount is absent"
printf '%s\n' "$mounts" | grep -Fxq '/u02/backup|/u02/backup' || fail "required RMAN backup bind mount is absent"

relative_path=${container_path#/opt/oracle/oradata/}
[ "$relative_path" != "$container_path" ] && [ -n "$relative_path" ] || fail "cannot map the container datafile to its host bind mount"
host_path=$(realpath -m -- "/u01/oradata/$relative_path" 2>/dev/null) || fail "cannot canonicalize derived host datafile path"
case "$host_path" in /u01/oradata/*) ;; *) fail "derived host datafile path escapes /u01/oradata" ;; esac
[ -n "$recorded_host_path" ] || fail "injection state does not record the safely mapped host path"
recorded_host_canonical=$(realpath -m -- "$recorded_host_path" 2>/dev/null) || fail "cannot canonicalize recorded host datafile path"
[ "$recorded_host_canonical" = "$host_path" ] || fail "recorded and independently derived host paths differ"
[ -f "$host_path" ] && [ ! -L "$host_path" ] && [ -s "$host_path" ] || fail "recovered host datafile is absent, empty, or a symbolic link"
resolved_host_path=$(realpath -e -- "$host_path" 2>/dev/null) || fail "cannot resolve recovered host datafile"
case "$resolved_host_path" in /u01/oradata/*) ;; *) fail "recovered datafile resolves outside /u01/oradata" ;; esac

transcript=/u02/backup/logs/ex2-rman-recovery.log
[ -s "$transcript" ] || fail "required Exercise 2 RMAN transcript is missing or empty"
[ "$transcript" -nt "$record" ] || fail "Exercise 2 RMAN transcript predates the injection state"
file_base=$(basename "$container_path")
grep -Eiq "restore[[:space:]]+datafile[[:space:]]+([^;]*(^|[^0-9])${file_no}([^0-9]|$)|[^;]*${file_base})" "$transcript" || fail "RMAN transcript lacks a targeted restore of the recorded datafile"
grep -Eiq "recover[[:space:]]+datafile[[:space:]]+([^;]*(^|[^0-9])${file_no}([^0-9]|$)|[^;]*${file_base})" "$transcript" || fail "RMAN transcript lacks targeted recovery of the recorded datafile"
grep -Eiq 'finished restore' "$transcript" || fail "RMAN transcript does not show completed restore work"
grep -Eiq 'finished recover' "$transcript" || fail "RMAN transcript does not show completed recovery work"
if grep -Eiq '(^|[;[:space:]])(restore|recover)[[:space:]]+database([;[:space:]]|$)|(^|[;[:space:]])(restore|recover)[[:space:]]+pluggable[[:space:]]+database|open[[:space:]]+resetlogs' "$transcript"; then
  fail "RMAN transcript shows whole-CDB/PDB replacement or RESETLOGS activity"
fi

sql_path=${container_path//\'/\'\'}
sql_text=$(cat <<SQL
set heading off feedback off pagesize 0 verify off echo off trimspool on linesize 4000
whenever sqlerror exit 2
select 'RESETLOGS_CHANGE=' || resetlogs_change# from v\$database;
select 'PDB_OPEN=' || replace(open_mode,' ','') from v\$pdbs where name='FREEPDB1';
select 'ROOT_FILE_MATCH=' || count(*)
from cdb_data_files d join v\$pdbs p on p.con_id=d.con_id
where p.name='FREEPDB1' and d.file_id=${file_no} and d.file_name='${sql_path}'
  and d.tablespace_name='LABRECOVERY' and d.status='AVAILABLE';
select 'UNCOVERED_LEVEL0_FILES=' || count(*)
from v\$datafile d
where not exists (
  select 1
  from v\$backup_datafile bd
  join v\$backup_set bs on bs.set_stamp=bd.set_stamp and bs.set_count=bd.set_count
  join v\$backup_piece bp on bp.set_stamp=bs.set_stamp and bp.set_count=bs.set_count
  where bd.file#=d.file# and bs.incremental_level=0
    and bs.resetlogs_change#=${expected_resetlogs}
    and bp.status='A' and bp.deleted='NO'
);
select distinct 'LEVEL0_HANDLE=' || bp.handle
from v\$backup_set bs
join v\$backup_piece bp on bp.set_stamp=bs.set_stamp and bp.set_count=bs.set_count
where bs.incremental_level=0 and bs.resetlogs_change#=${expected_resetlogs}
  and bp.status='A' and bp.deleted='NO' and bp.handle is not null;
alter session set container=FREEPDB1;
select 'TABLESPACE_ONLINE=' || count(*) from dba_tablespaces
where tablespace_name='LABRECOVERY' and status='ONLINE';
select 'DATAFILE_AVAILABLE=' || count(*) from dba_data_files
where file_id=${file_no} and file_name='${sql_path}' and tablespace_name='LABRECOVERY' and status='AVAILABLE';
select 'UNAVAILABLE_FILES=' || count(*) from dba_data_files where status <> 'AVAILABLE';
select 'RECOVERY_REQUIRED=' || count(*) from v\$recover_file where file#=${file_no};
select 'LIVE_CHECKSUM=' || count(*) || ':' || nvl(sum(order_id),0) from LABAPP.ORDERS;
exit
SQL
)

sql_out=$(printf '%s\n' "$sql_text" | docker exec -i "$CONTAINER_ID" sqlplus -s "/ as sysdba" 2>&1)
sql_rc=$?
[ $sql_rc -eq 0 ] || fail "Oracle metadata and integrity checks failed in the dynamically resolved container"

value() {
  printf '%s\n' "$sql_out" | sed -n "s/^[[:space:]]*$1=//p" | tail -n 1 | tr -d '[:space:]'
}

[ "$(value RESETLOGS_CHANGE)" = "$expected_resetlogs" ] || fail "CDB incarnation changed after Exercise 2 injection"
[ "$(value PDB_OPEN)" = "READWRITE" ] || fail "FREEPDB1 is not open read write"
[ "$(value ROOT_FILE_MATCH)" = "1" ] || fail "target file is not uniquely mapped to FREEPDB1/LABRECOVERY"
[ "$(value UNCOVERED_LEVEL0_FILES)" = "0" ] || fail "no usable current-incarnation level 0 covers every current CDB datafile"
[ "$(value TABLESPACE_ONLINE)" = "1" ] || fail "LABRECOVERY tablespace is not online"
[ "$(value DATAFILE_AVAILABLE)" = "1" ] || fail "target FREEPDB1 datafile is not available at its recorded path"
[ "$(value UNAVAILABLE_FILES)" = "0" ] || fail "FREEPDB1 still has an unavailable permanent datafile"
[ "$(value RECOVERY_REQUIRED)" = "0" ] || fail "target datafile still requires media recovery"
[ "$(value LIVE_CHECKSUM)" = "$expected_checksum" ] || fail "live FREEPDB1 row-count/checksum differs from the protected pre-loss value"

mapfile -t level0_handles < <(printf '%s\n' "$sql_out" | sed -n 's/^[[:space:]]*LEVEL0_HANDLE=//p' | sed '/^[[:space:]]*$/d' | sort -u)
[ ${#level0_handles[@]} -gt 0 ] || fail "current-incarnation level 0 has no available physical backup pieces"
for handle in "${level0_handles[@]}"; do
  case "$handle" in /u02/backup/*) ;; *) fail "current-incarnation level 0 piece is outside /u02/backup" ;; esac
  docker exec "$CONTAINER_ID" test -s "$handle" >/dev/null 2>&1 || fail "RMAN metadata references a missing or empty level 0 piece"
done

echo "VALIDATION_OK:FREEPDB1 datafile ${file_no} targeted recovery is valid; level 0 provenance=${normalized_provenance}; current incarnation=${expected_resetlogs}"
REMOTE

    encoded=$(printf '%s' "$remote_script" | base64 | tr -d '\n')
    parameters=$(printf '{"commands":["echo %s | base64 -d | bash"]}' "$encoded")

    command_id=$(aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --comment "CloudLabs Validation 2: independent FREEPDB1 datafile recovery" \
      --timeout-seconds 180 \
      --parameters "$parameters" \
      --query 'Command.CommandId' \
      --output text 2>/dev/null)
    send_rc=$?

    if [ $send_rc -ne 0 ] || [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
      last_reason="SSM SendCommand failed for instance ${instance_id}"
    else
      status="Pending"
      for _ in $(seq 1 36); do
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

      command_output=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null)
      output_rc=$?

      if [ "$status" = "Success" ] && [ $output_rc -eq 0 ] && grep -q '^VALIDATION_OK:' <<<"$command_output"; then
        found=true
        detail=$(printf '%s\n' "$command_output" | sed -n 's/^VALIDATION_OK://p' | tail -n 1)
        cat <<EOF
{"Status":"Succeeded","Message":"Exercise 2 passed independently on EC2 instance ${instance_id} in account ${ACCOUNT_ID}: ${detail}. The check did not require Exercise 1 state or success."}
EOF
        exit 0
      fi

      remote_reason=$(printf '%s\n' "$command_output" | sed -n 's/^VALIDATION_FAIL://p' | tail -n 1)
      if [ -n "$remote_reason" ]; then
        last_reason="$remote_reason on instance ${instance_id}"
      else
        last_reason="SSM Oracle check on instance ${instance_id} ended with status ${status}"
      fi
    fi
  fi

  if [ "$found" != "true" ] && [ $count -lt 3 ]; then
    sleep 10
  fi
done

cat <<EOF
{"Status":"Failed","Message":"Independent FREEPDB1 datafile recovery validation failed in account ${ACCOUNT_ID} after ${count} attempts: ${last_reason}."}
EOF
exit 0
