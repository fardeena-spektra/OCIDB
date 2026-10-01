#!/bin/bash
set -uo pipefail

# Platform-injected vars (do NOT re-define):
#   ACCOUNT_ID    — AWS account id
#   DEPLOYMENT_ID — CloudLabs deployment id (suffix on lab resources)
#   AWS_REGION    — primary region

count=0
found=false
last_failure="No tagged learner instance was found."

while [ $count -lt 3 ] && [ "$found" != "true" ]; do
  count=$((count + 1))

  # Discover the learner VM from its deployment tag rather than assuming a name.
  set +e
  instance_ids=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag-value,Values=*$DEPLOYMENT_ID*" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null)
  instance_rc=$?
  set -e

  instance_count=$(printf '%s\n' "$instance_ids" | awk '{print NF}')
  if [ $instance_rc -ne 0 ] || [ "$instance_count" -ne 1 ]; then
    last_failure="Expected exactly one running EC2 instance tagged for deployment '$DEPLOYMENT_ID'."
  else
    instance_id=$(printf '%s\n' "$instance_ids" | awk '{print $1}')

    # Inspect EBS through the EC2 control plane. This deliberately does not use SSM.
    set +e
    volume_rows=$(aws ec2 describe-volumes \
      --region "$AWS_REGION" \
      --filters \
        "Name=attachment.instance-id,Values=$instance_id" \
        "Name=volume-type,Values=gp3" \
        "Name=size,Values=30" \
        "Name=encrypted,Values=true" \
        "Name=status,Values=in-use" \
        "Name=attachment.status,Values=attached" \
      --query 'Volumes[].{Id:VolumeId,Type:VolumeType,GiB:Size,Encrypted:Encrypted,State:State,Instance:Attachments[0].InstanceId,Attachment:Attachments[0].State}' \
      --output text 2>/dev/null)
    volume_rc=$?
    set -e

    volume_count=$(printf '%s\n' "$volume_rows" | awk 'NF {n++} END {print n+0}')
    if [ $volume_rc -ne 0 ] || [ "$volume_count" -ne 1 ]; then
      last_failure="Instance '$instance_id' does not have exactly one attached, in-use, encrypted 30 GiB gp3 backup volume."
    else
      read -r attachment_state encrypted size_gib volume_id instance_on_volume volume_state volume_type <<< "$volume_rows"

      if [ "$volume_type" != "gp3" ] || [ "$size_gib" != "30" ] || [ "$encrypted" != "True" ] || \
         [ "$volume_state" != "in-use" ] || [ "$instance_on_volume" != "$instance_id" ] || \
         [ "$attachment_state" != "attached" ]; then
        last_failure="Backup volume metadata for instance '$instance_id' does not meet the gp3, 30 GiB, encrypted, in-use, attached requirements."
      else
        # Only guest filesystem and Oracle/RMAN assertions are delegated to SSM.
        # /opt/lab/validate-ex1.sh is deployment-created, root-owned verification
        # scaffolding. Its --read-only mode validates the protected injection record,
        # pre-target markers, absence of the injected bad row, and current-incarnation
        # post-RESETLOGS backup evidence without changing Oracle or RMAN state.
        read -r -d '' remote_script <<'REMOTE' || true
set -uo pipefail
fail() { printf 'CHECK_FAILED:%s\n' "$1"; exit 1; }

expected_volume_id="__VOLUME_ID__"
expected_serial=${expected_volume_id//-/}

mount_target=$(findmnt -rn -T /u02/backup -o TARGET 2>/dev/null) || fail "mount_lookup"
mount_source=$(findmnt -rn -T /u02/backup -o SOURCE 2>/dev/null) || fail "mount_source"
mount_options=$(findmnt -rn -T /u02/backup -o OPTIONS 2>/dev/null) || fail "mount_options"
[ "$mount_target" = "/u02/backup" ] || fail "backup_not_separate_mount"
printf '%s\n' "$mount_options" | tr ',' '\n' | grep -qx 'rw' || fail "backup_mount_not_rw"

source_device=$(readlink -f "$mount_source" 2>/dev/null || printf '%s' "$mount_source")
serials=$(lsblk -s -n -o SERIAL "$source_device" 2>/dev/null | tr -d ' -')
printf '%s\n' "$serials" | grep -qi "$expected_serial" || fail "mount_volume_mismatch"

export ORACLE_SID=FREE
export ORAENV_ASK=NO
if [ -r /usr/local/bin/oraenv ]; then
  . /usr/local/bin/oraenv >/dev/null 2>&1 || fail "oraenv"
elif [ -r /usr/bin/oraenv ]; then
  . /usr/bin/oraenv >/dev/null 2>&1 || fail "oraenv"
fi
command -v sqlplus >/dev/null 2>&1 || fail "sqlplus_missing"

db_report=$(sqlplus -s / as sysdba <<'SQL'
set pages 0 feedback off heading off verify off echo off lines 32767 trimspool on
whenever sqlerror exit failure
select 'METRICS|' ||
       (select count(*) from v$backup_set where backup_type='D' and incremental_level=0) || '|' ||
       (select count(*) from v$backup_set where backup_type='I' and incremental_level=1) || '|' ||
       (select count(*) from v$backup_set where backup_type='L') || '|' ||
       (select count(*) from v$backup_set where controlfile_included='YES') || '|' ||
       (select count(*) from v$backup_spfile) || '|' ||
       (select count(*) from v$backup_piece where status='A' and handle like '/u02/backup/%') || '|' ||
       (select count(*) from v$backup_set b, v$database d where b.backup_type='D' and b.completion_time > d.resetlogs_time) || '|' ||
       (select count(*) from v$database_incarnation where status='CURRENT') || '|' ||
       (select count(*) from v$database_incarnation)
from dual;
select 'PIECE|' || handle
from v$backup_piece
where status='A' and handle like '/u02/backup/%';
exit
SQL
) || fail "oracle_backup_metadata"

metrics=$(printf '%s\n' "$db_report" | sed -n 's/^[[:space:]]*METRICS|//p' | tail -1)
IFS='|' read -r level0 level1 arch control spfile pieces postreset current_inc incarnations <<< "$metrics"
for value in "$level0" "$level1" "$arch" "$control" "$spfile" "$pieces" "$postreset" "$current_inc" "$incarnations"; do
  case "$value" in ''|*[!0-9]*) fail "invalid_rman_metrics" ;; esac
done
[ "$level0" -gt 0 ] || fail "level0_missing"
[ "$level1" -gt 0 ] || fail "level1_missing"
[ "$arch" -gt 0 ] || fail "archivelog_backup_missing"
[ "$control" -gt 0 ] || fail "controlfile_protection_missing"
[ "$spfile" -gt 0 ] || fail "spfile_protection_missing"
[ "$pieces" -gt 0 ] || fail "usable_backup_pieces_missing"
[ "$postreset" -gt 0 ] || fail "post_resetlogs_backup_missing"
[ "$current_inc" -eq 1 ] || fail "current_incarnation_invalid"
[ "$incarnations" -ge 2 ] || fail "resetlogs_incarnation_evidence_missing"

piece_lines=$(printf '%s\n' "$db_report" | sed -n 's/^[[:space:]]*PIECE|//p')
[ -n "$piece_lines" ] || fail "physical_piece_list_empty"
while IFS= read -r piece; do
  [ -f "$piece" ] || fail "physical_backup_piece_missing"
done <<< "$piece_lines"

[ -x /opt/lab/validate-ex1.sh ] || fail "protected_ex1_verifier_missing"
owner_mode=$(stat -c '%U:%a' /opt/lab/validate-ex1.sh 2>/dev/null) || fail "verifier_stat"
owner=${owner_mode%%:*}
mode=${owner_mode#*:}
[ "$owner" = "root" ] || fail "verifier_not_root_owned"
case "$mode" in *[2367][0-7]|*[0-7][2367]) fail "verifier_writable_by_non_root" ;; esac
verifier_output=$(/opt/lab/validate-ex1.sh --read-only 2>&1) || fail "exercise_outcome"
printf '%s\n' "$verifier_output" | grep -qx 'VALIDATION_EX1_OK' || fail "exercise_outcome_marker"

printf 'VALIDATION_OK\n'
REMOTE
        remote_script=${remote_script//__VOLUME_ID__/$volume_id}
        payload=$(printf '%s' "$remote_script" | base64 | tr -d '\n')
        parameters_json=$(printf '{"commands":["echo %s | base64 -d | bash"]}' "$payload")

        set +e
        command_id=$(aws ssm send-command \
          --region "$AWS_REGION" \
          --instance-ids "$instance_id" \
          --document-name "AWS-RunShellScript" \
          --comment "CloudLabs read-only validation 1 for $DEPLOYMENT_ID" \
          --timeout-seconds 600 \
          --parameters "$parameters_json" \
          --query 'Command.CommandId' \
          --output text 2>/dev/null)
        send_rc=$?
        set -e

        if [ $send_rc -ne 0 ] || [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
          last_failure="SSM could not start read-only guest and Oracle/RMAN checks on instance '$instance_id'."
        else
          invocation_status="Pending"
          response_code="-1"
          standard_output=""
          poll_count=0
          while [ $poll_count -lt 60 ]; do
            poll_count=$((poll_count + 1))
            sleep 5
            set +e
            invocation=$(aws ssm get-command-invocation \
              --region "$AWS_REGION" \
              --command-id "$command_id" \
              --instance-id "$instance_id" \
              --query '[Status,ResponseCode,StandardOutputContent]' \
              --output text 2>/dev/null)
            invocation_rc=$?
            set -e
            if [ $invocation_rc -ne 0 ]; then
              continue
            fi
            invocation_status=$(printf '%s\n' "$invocation" | awk -F '\t' '{print $1}')
            response_code=$(printf '%s\n' "$invocation" | awk -F '\t' '{print $2}')
            standard_output=$(printf '%s\n' "$invocation" | cut -f3-)
            case "$invocation_status" in
              Success|Cancelled|TimedOut|Failed|Cancelling) break ;;
            esac
          done

          if [ "$invocation_status" = "Success" ] && [ "$response_code" = "0" ] && \
             printf '%s\n' "$standard_output" | grep -q 'VALIDATION_OK'; then
            found=true
            cat <<EOF
{"Status":"Succeeded","Message":"Instance '$instance_id' in account $ACCOUNT_ID has attached encrypted 30 GiB gp3 backup volume '$volume_id'; its matching /u02/backup mount, RMAN level 0/1 and redo chain, control-file/SPFILE protection, physical pieces, whole-CDB PITR outcome, RESETLOGS incarnation, and post-RESETLOGS backup passed read-only checks."}
EOF
            exit 0
          fi

          last_failure="SSM read-only guest/Oracle validation failed on instance '$instance_id' (command status: $invocation_status)."
        fi
      fi
    fi
  fi

  if [ "$found" != "true" ] && [ $count -lt 3 ]; then
    sleep 10
  fi
done

cat <<EOF
{"Status":"Failed","Message":"Validation 1 failed in account $ACCOUNT_ID after $count attempts. $last_failure"}
EOF
exit 0
