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

  instance_ids=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag-value,Values=*$DEPLOYMENT_ID*" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null)
  instance_rc=$?
  instance_count=$(printf '%s\n' "$instance_ids" | awk '{print NF}')

  if [ $instance_rc -ne 0 ] || [ "$instance_count" -ne 1 ]; then
    last_failure="Expected exactly one running EC2 instance tagged for deployment '$DEPLOYMENT_ID'."
  else
    instance_id=$(printf '%s\n' "$instance_ids" | awk '{print $1}')

    # Deliberately inspect EBS through EC2 rather than trusting guest evidence.
    volume_rows=$(aws ec2 describe-volumes \
      --region "$AWS_REGION" \
      --filters \
        "Name=attachment.instance-id,Values=$instance_id" \
        "Name=volume-type,Values=gp3" \
        "Name=size,Values=30" \
        "Name=encrypted,Values=true" \
        "Name=status,Values=in-use" \
        "Name=attachment.status,Values=attached" \
      --query 'Volumes[].{AttachmentState:Attachments[?InstanceId==`'"$instance_id"'`]|[0].State,Encrypted:Encrypted,InstanceId:Attachments[?InstanceId==`'"$instance_id"'`]|[0].InstanceId,Size:Size,State:State,VolumeId:VolumeId,Type:VolumeType}' \
      --output text 2>/dev/null)
    volume_rc=$?
    volume_count=$(printf '%s\n' "$volume_rows" | awk 'NF {n++} END {print n+0}')

    if [ $volume_rc -ne 0 ] || [ "$volume_count" -ne 1 ]; then
      last_failure="Instance '$instance_id' does not have exactly one attached, in-use, encrypted 30 GiB gp3 backup volume."
    else
      read -r attachment_state encrypted instance_on_volume size_gib volume_state volume_id volume_type <<< "$volume_rows"
      if [ "$attachment_state" != "attached" ] || [ "$encrypted" != "True" ] || \
         [ "$instance_on_volume" != "$instance_id" ] || [ "$size_gib" != "30" ] || \
         [ "$volume_state" != "in-use" ] || [ "$volume_type" != "gp3" ]; then
        last_failure="Backup volume '$volume_id' does not meet the encrypted gp3, 30 GiB, in-use attachment contract."
      else
        read -r -d '' remote_script <<'REMOTE' || true
set -uo pipefail
fail() { printf 'CHECK_FAILED:%s\n' "$1"; exit 1; }
expected_volume_id="__VOLUME_ID__"
expected_serial=${expected_volume_id//-/}

[ -r /etc/os-release ] || fail "os_release_missing"
. /etc/os-release
[ "${ID:-}" = "amzn" ] && [ "${VERSION_ID:-}" = "2023" ] || fail "not_amazon_linux_2023"
command -v docker >/dev/null 2>&1 || fail "docker_missing"
systemctl is-active --quiet docker || fail "docker_not_active"

[ -d /u01/oradata ] && [ -d /u02/backup ] || fail "persistent_path_missing"
[ "$(stat -c '%u:%g' /u01/oradata 2>/dev/null)" = "54321:54321" ] || fail "oradata_owner_not_54321"
[ "$(stat -c '%u:%g' /u02/backup 2>/dev/null)" = "54321:54321" ] || fail "backup_owner_not_54321"
mount_target=$(findmnt -rn -T /u02/backup -o TARGET 2>/dev/null) || fail "backup_mount_lookup"
mount_source=$(findmnt -rn -T /u02/backup -o SOURCE 2>/dev/null) || fail "backup_mount_source"
[ "$mount_target" = "/u02/backup" ] || fail "backup_not_separate_mount"
source_device=$(readlink -f "$mount_source" 2>/dev/null || printf '%s' "$mount_source")
serials=$(lsblk -s -n -o SERIAL "$source_device" 2>/dev/null | tr -d ' -')
printf '%s\n' "$serials" | grep -qi "$expected_serial" || fail "backup_mount_volume_mismatch"

# Resolve exactly one intended running container; never retain a deployment-time ID.
container_ids=$(docker ps --filter name=oracle-free --filter status=running -q)
[ "$(printf '%s\n' "$container_ids" | sed '/^$/d' | wc -l)" -eq 1 ] || fail "expected_one_running_oracle_container"
CONTAINER_ID=$(printf '%s\n' "$container_ids" | head -n 1)
[ "$(docker inspect -f '{{.Name}}' "$CONTAINER_ID" 2>/dev/null)" = "/oracle-free" ] || fail "wrong_container_name"
[ "$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_ID" 2>/dev/null)" = "container-registry.oracle.com/database/free:23.9.0.0" ] || fail "wrong_oracle_image_tag"
[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_ID" 2>/dev/null)" = "unless-stopped" ] || fail "wrong_restart_policy"
[ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination \"/opt/oracle/oradata\"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_ID")" = "/u01/oradata" ] || fail "oradata_bind_mount_invalid"
[ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination \"/u02/backup\"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_ID")" = "/u02/backup" ] || fail "backup_bind_mount_invalid"

# Exercise 1 must have its own protected injection record and learner transcripts.
state=/opt/lab/state/ex1.env
[ -f "$state" ] || fail "ex1_state_missing"
[ "$(stat -c '%u' "$state" 2>/dev/null)" = "0" ] || fail "ex1_state_not_root_owned"
state_mode=$(stat -c '%a' "$state" 2>/dev/null) || fail "ex1_state_stat"
case "$state_mode" in *[2367][0-7]|*[0-7][2367]) fail "ex1_state_writable_by_non_root" ;; esac
TARGET_SCN=$(awk -F= '$1=="TARGET_SCN"{print $2}' "$state" | tail -1)
BASE_RESETLOGS_SCN=$(awk -F= '$1=="BASE_RESETLOGS_SCN"{print $2}' "$state" | tail -1)
MARKER=$(awk -F= '$1=="MARKER"{sub(/^[^=]*=/,"");print}' "$state" | tail -1)
case "$TARGET_SCN" in ''|*[!0-9]*) fail "invalid_target_scn" ;; esac
case "$BASE_RESETLOGS_SCN" in ''|*[!0-9]*) fail "invalid_base_resetlogs_scn" ;; esac
[ -n "$MARKER" ] || fail "bad_marker_missing"

for evidence in \
  level0-rman.txt level1-rman.txt injection-output.txt pitr-rman.txt \
  open-resetlogs.txt recovery-outcome.txt post-resetlogs-backup.txt \
  container-after-shutdown.txt container-at-mount.txt container-after-resetlogs.txt; do
  path="/opt/lab/evidence/ex1/$evidence"
  [ -s "$path" ] || fail "learner_evidence_${evidence//[^A-Za-z0-9]/_}_missing"
done
# Provenance is tied to the exact learner commands/tags in Exercise 1, not merely
# to the existence of arbitrary RMAN backups.
grep -q "CL_EX1_L0" /opt/lab/evidence/ex1/level0-rman.txt || fail "learner_l0_transcript_tag_missing"
grep -q "CL_EX1_L1" /opt/lab/evidence/ex1/level1-rman.txt || fail "learner_l1_transcript_tag_missing"
grep -q "CL_EX1_POST_RESETLOGS_L0" /opt/lab/evidence/ex1/post-resetlogs-backup.txt || fail "learner_postreset_transcript_tag_missing"
grep -Eiq "SET[[:space:]]+UNTIL[[:space:]]+SCN[[:space:]]+$TARGET_SCN([^0-9]|$)" /opt/lab/evidence/ex1/pitr-rman.txt || fail "pitr_target_scn_not_evidenced"
grep -Eiq 'RESTORE[[:space:]]+DATABASE' /opt/lab/evidence/ex1/pitr-rman.txt || fail "whole_database_restore_not_evidenced"
grep -Eiq 'RECOVER[[:space:]]+DATABASE' /opt/lab/evidence/ex1/pitr-rman.txt || fail "whole_database_recover_not_evidenced"
grep -Eiq 'open[[:space:]]+resetlogs' /opt/lab/evidence/ex1/open-resetlogs.txt || fail "open_resetlogs_not_evidenced"

# If Exercise 2 has run, its safety-backup provenance may exist and is valid for
# Exercise 2 only. It must not be represented as Exercise 1 evidence.
if [ -f /opt/lab/state/ex2.env ]; then
  if grep -Eiq '(^|[|_])(BACKUP_)?PROVENANCE=(inject-ex2|injector)|CREATED_BY=inject-ex2' /opt/lab/state/ex2.env; then
    grep -Eiq 'inject-ex2|injector|CL_EX2|SAFETY' /opt/lab/evidence/ex1/level0-rman.txt && fail "inject_ex2_backup_claimed_as_ex1_l0"
    grep -Eiq 'inject-ex2|injector|CL_EX2|SAFETY' /opt/lab/evidence/ex1/post-resetlogs-backup.txt && fail "inject_ex2_backup_claimed_as_ex1_postreset"
  fi
  ex2_mtime=$(stat -c '%Y' /opt/lab/state/ex2.env 2>/dev/null) || fail "ex2_state_stat"
  for evidence in level0-rman.txt level1-rman.txt pitr-rman.txt open-resetlogs.txt post-resetlogs-backup.txt; do
    [ "$(stat -c '%Y' "/opt/lab/evidence/ex1/$evidence")" -le "$ex2_mtime" ] || fail "ex1_evidence_created_after_ex2_injection"
  done
fi

# Query only exact learner Exercise 1 tags. Generic or CL_EX2 safety sets cannot
# satisfy these counts, even if inject-ex2 had to create a current-incarnation L0.
db_report=$(docker exec "$CONTAINER_ID" bash -lc "sqlplus -s / as sysdba" <<SQL
set pages 0 feedback off heading off verify off echo off lines 32767 trimspool on
whenever sqlerror exit failure
select 'STATE|'||open_mode||'|'||log_mode||'|'||resetlogs_change# from v\$database;
select 'PDB|'||open_mode from v\$pdbs where name='FREEPDB1';
select 'BAD|'||count(*) from LABAPP.ORDERS@FREEPDB1 where marker=q'~$MARKER~';
select 'BASE|'||trim((select count(*)||':'||nvl(sum(order_id),0) from LABAPP.ORDERS@FREEPDB1)) from dual;
select 'CURRENTINC|'||count(*) from v\$database_incarnation where status='CURRENT';
select 'INCS|'||count(*) from v\$database_incarnation;
select 'L0|'||count(*) from v\$backup_set where backup_type='D' and incremental_level=0 and tag='CL_EX1_L0' and resetlogs_change#=$BASE_RESETLOGS_SCN;
select 'L1|'||count(*) from v\$backup_set where backup_type='I' and incremental_level=1 and tag='CL_EX1_L1' and resetlogs_change#=$BASE_RESETLOGS_SCN;
select 'ARC|'||count(*) from v\$backup_set where backup_type='L' and tag in ('CL_EX1_L0_ARC','CL_EX1_L1_ARC');
select 'CTL|'||count(*) from v\$backup_set where controlfile_included='YES' and tag='CL_EX1_L0_CTL';
select 'SPF|'||count(*) from v\$backup_spfile s join v\$backup_set b on b.set_stamp=s.set_stamp and b.set_count=s.set_count where b.tag='CL_EX1_L0_SPFILE';
select 'POST|'||count(*) from v\$backup_set b, v\$database d where b.backup_type='D' and b.incremental_level=0 and b.tag='CL_EX1_POST_RESETLOGS_L0' and b.resetlogs_change#=d.resetlogs_change# and b.completion_time>d.resetlogs_time;
select 'PIECE|'||p.handle from v\$backup_piece p join v\$backup_set b on b.set_stamp=p.set_stamp and b.set_count=p.set_count where p.status='A' and p.handle like '/u02/backup/%' and b.tag in ('CL_EX1_L0','CL_EX1_L1','CL_EX1_L0_ARC','CL_EX1_L1_ARC','CL_EX1_L0_CTL','CL_EX1_L0_SPFILE','CL_EX1_POST_RESETLOGS_L0','CL_EX1_POST_RESETLOGS_ARC','CL_EX1_POST_RESETLOGS_CTL','CL_EX1_POST_RESETLOGS_SPFILE');
exit
SQL
) || fail "docker_oracle_rman_query"

state_row=$(printf '%s\n' "$db_report" | sed -n 's/^[[:space:]]*STATE|//p' | tail -1)
IFS='|' read -r cdb_mode log_mode current_resetlogs <<< "$state_row"
[ "$cdb_mode" = "READ WRITE" ] && [ "$log_mode" = "ARCHIVELOG" ] || fail "cdb_not_open_archivelog"
case "$current_resetlogs" in ''|*[!0-9]*) fail "invalid_current_resetlogs_scn" ;; esac
[ "$current_resetlogs" -gt "$BASE_RESETLOGS_SCN" ] || fail "resetlogs_did_not_advance"
[ "$(printf '%s\n' "$db_report" | sed -n 's/^[[:space:]]*PDB|//p' | tail -1)" = "READ WRITE" ] || fail "freepdb1_not_read_write"
[ "$(printf '%s\n' "$db_report" | sed -n 's/^[[:space:]]*BAD|//p' | tr -d ' ' | tail -1)" = "0" ] || fail "bad_transaction_still_present"
seed_baseline=$(tr -d '[:space:]' </opt/lab/state/seed-baseline.txt 2>/dev/null) || fail "seed_baseline_missing"
current_baseline=$(printf '%s\n' "$db_report" | sed -n 's/^[[:space:]]*BASE|//p' | tr -d ' ' | tail -1)
[ -n "$seed_baseline" ] && [ "$current_baseline" = "$seed_baseline" ] || fail "pretarget_data_checksum_mismatch"

metric() { printf '%s\n' "$db_report" | sed -n "s/^[[:space:]]*$1|//p" | tr -d ' ' | tail -1; }
for key in CURRENTINC INCS L0 L1 ARC CTL SPF POST; do
  value=$(metric "$key")
  case "$value" in ''|*[!0-9]*) fail "invalid_${key}_metric" ;; esac
  [ "$value" -gt 0 ] || fail "${key}_learner_evidence_missing"
done
[ "$(metric CURRENTINC)" -eq 1 ] || fail "current_incarnation_count_invalid"
[ "$(metric INCS)" -ge 2 ] || fail "resetlogs_incarnation_evidence_missing"

piece_lines=$(printf '%s\n' "$db_report" | sed -n 's/^[[:space:]]*PIECE|//p')
[ -n "$piece_lines" ] || fail "learner_tagged_physical_pieces_missing"
while IFS= read -r piece; do [ -f "$piece" ] || fail "learner_tagged_piece_not_physical"; done <<< "$piece_lines"

docker ps --filter id="$CONTAINER_ID" --filter status=running -q | grep -qx "$CONTAINER_ID" || fail "container_stopped_during_validation"
printf 'VALIDATION_OK\n'
REMOTE
        remote_script=${remote_script//__VOLUME_ID__/$volume_id}
        payload=$(printf '%s' "$remote_script" | base64 | tr -d '\n')
        parameters_json=$(printf '{"commands":["echo %s | base64 -d | bash"]}' "$payload")

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

        if [ $send_rc -ne 0 ] || [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
          last_failure="SSM could not start the read-only Docker and Oracle checks on instance '$instance_id'."
        else
          invocation_status="Pending"
          response_code="-1"
          standard_output=""
          standard_error=""
          poll_count=0
          while [ $poll_count -lt 60 ]; do
            poll_count=$((poll_count + 1))
            sleep 5
            invocation=$(aws ssm get-command-invocation \
              --region "$AWS_REGION" \
              --command-id "$command_id" \
              --instance-id "$instance_id" \
              --query '[Status,ResponseCode,StandardOutputContent,StandardErrorContent]' \
              --output text 2>/dev/null)
            invocation_rc=$?
            [ $invocation_rc -eq 0 ] || continue
            invocation_status=$(printf '%s\n' "$invocation" | awk -F '\t' '{print $1}')
            response_code=$(printf '%s\n' "$invocation" | awk -F '\t' '{print $2}')
            standard_output=$(printf '%s\n' "$invocation" | awk -F '\t' '{print $3}')
            standard_error=$(printf '%s\n' "$invocation" | cut -f4-)
            case "$invocation_status" in Success|Cancelled|TimedOut|Failed|Cancelling) break ;; esac
          done

          if [ "$invocation_status" = "Success" ] && [ "$response_code" = "0" ] && \
             printf '%s\n' "$standard_output" | grep -qx 'VALIDATION_OK'; then
            found=true
            cat <<EOF
{"Status":"Succeeded","Message":"Instance '$instance_id' in account $ACCOUNT_ID has encrypted 30 GiB gp3 backup volume '$volume_id', valid Docker-aware storage, and learner-proven Exercise 1 RMAN level 0/1, whole-CDB PITR/RESETLOGS, logical outcome, and current-incarnation post-RESETLOGS backup evidence; inject-ex2 safety backups were excluded."}
EOF
            exit 0
          fi

          failure_detail=$(printf '%s\n%s\n' "$standard_output" "$standard_error" | grep -o 'CHECK_FAILED:[A-Za-z0-9_:-]*' | tail -1)
          last_failure="SSM Docker/Oracle validation failed on instance '$instance_id' (command status: $invocation_status${failure_detail:+; $failure_detail})."
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
