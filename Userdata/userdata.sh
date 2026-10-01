#!/bin/bash
set -euo pipefail
set -E
exec > >(tee -a /var/log/cloudlabs-bootstrap.log) 2>&1
umask 077

DEPLOYMENT_ID="${DEPLOYMENT_ID:-unknown}"
ODL_ID="${ODL_ID:-unknown}"
ADMIN_USERNAME="${ADMIN_USERNAME-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CFN_STACK="${CFN_STACK:-}"
CFN_RESOURCE="${CFN_RESOURCE:-LabVm}"
BACKUP_VOLUME_ID="${BACKUP_VOLUME_ID:-}"

READY=/opt/lab/.ready
CFN_SIGNAL=/opt/aws/bin/cfn-signal
ORACLE_IMAGE=container-registry.oracle.com/database/free:23.9.0.0
ORACLE_REPOSITORY=container-registry.oracle.com/database/free
APPROVED_ORACLE_DIGEST=sha256:66296e93ffe793012d424439db5771617491e94c782196953d993ffd869c3eb0
ORACLE_ENV=/etc/cloudlabs/oracle.env
SIGNALLED=0

stamp(){ date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log(){ printf '[%s] %s\n' "$(stamp)" "$*"; }
die(){ log "ERROR: $*"; return 1; }

signal_stack(){
  local result="$1"
  (( SIGNALLED == 0 )) || return 0
  SIGNALLED=1
  "$CFN_SIGNAL" --success "$result" --reason "Stage 1 bootstrap result=$result; inspect /var/log/cloudlabs-bootstrap.log" --stack "$CFN_STACK" --resource "$CFN_RESOURCE" --region "$AWS_REGION"
}
on_exit(){
  local rc=$?
  trap - EXIT INT TERM
  if (( rc != 0 )) && [[ -x "$CFN_SIGNAL" && -n "$CFN_STACK" ]]; then
    signal_stack false >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container_id(){
  local ids count id name
  ids="$(docker ps --filter name=oracle-free --filter status=running -q)"
  count="$(printf '%s\n' "$ids"|sed '/^$/d'|wc -l)"
  [[ "$count" -eq 1 ]] || return 1
  id="$(printf '%s\n' "$ids"|sed '/^$/d'|head -n1)"
  name="$(docker inspect --format '{{.Name}}' "$id")"
  [[ "$name" == /oracle-free ]] || return 1
  printf '%s\n' "$id"
}
dsql(){ docker exec -i "$1" bash -lc 'sqlplus -s / as sysdba'; }
drman(){ docker exec -i "$1" bash -lc 'rman target /'; }

main(){
  local os_id ssm_present wanted matches backup_device backup_uuid cid ready_ok
  local seed_check seed_mb actual_repo_digest repo_digest image_arch ORACLE_PASSWORD

  log "CloudLabs Stage 1 bootstrap start (deployment $DEPLOYMENT_ID, ODL $ODL_ID)"
  rm -f "$READY"
  [[ $(id -u) -eq 0 ]] || die "UserData must run as root"
  [[ -n "$ADMIN_USERNAME" ]] || die "ADMIN_USERNAME must be exported by the UserData wrapper"
  [[ -n "$ADMIN_PASSWORD" ]] || die "ADMIN_PASSWORD must be exported by the UserData wrapper"
  [[ -n "$CFN_STACK" && "$CFN_RESOURCE" == LabVm && -n "$BACKUP_VOLUME_ID" ]] || die "CloudFormation signaling and backup-volume inputs are required"
  [[ -x "$CFN_SIGNAL" ]] || die "/opt/aws/bin/cfn-signal is not present in the selected AMI"
  os_id="$(. /etc/os-release; printf '%s' "$ID")"
  [[ "$os_id" == amzn ]] || die "Amazon Linux 2023 is required"
  grep -q '^VERSION_ID="\?2023' /etc/os-release || die "Amazon Linux 2023 is required"

  ssm_present=0
  systemctl cat amazon-ssm-agent.service >/dev/null 2>&1 && ssm_present=1
  [[ -x /usr/bin/amazon-ssm-agent || -x /usr/local/bin/amazon-ssm-agent ]] && ssm_present=1
  (( ssm_present == 1 )) || die "amazon-ssm-agent is not present in the selected AMI"

  log "Installing Docker and host utilities"
  dnf install -y docker git unzip jq util-linux xfsprogs openssl sudo shadow-utils findutils coreutils
  systemctl enable --now docker
  systemctl is-active --quiet docker || die "Docker is not active"

  getent group docker >/dev/null || groupadd docker
  if ! id "$ADMIN_USERNAME" >/dev/null 2>&1; then useradd --create-home --shell /bin/bash "$ADMIN_USERNAME"; fi
  printf '%s:%s\n' "$ADMIN_USERNAME" "$ADMIN_PASSWORD" | chpasswd
  usermod -aG wheel,docker "$ADMIN_USERNAME"

  install -d -m 0755 /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/01-cloudlabs-password.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM yes
EOF
  chmod 0600 /etc/ssh/sshd_config.d/01-cloudlabs-password.conf
  sshd -t
  systemctl restart sshd
  sshd -T|grep -qi '^passwordauthentication yes$' || die "PasswordAuthentication is not effective"
  log "Configured password SSH; credentials were not written to the bootstrap log"

  log "Discovering backup EBS disk by normalized NVMe serial"
  wanted="$(printf '%s' "$BACKUP_VOLUME_ID"|tr -d '-'|tr '[:upper:]' '[:lower:]')"
  matches=""
  while read -r dev serial; do
    [[ -n "$dev" && -n "$serial" ]] || continue
    if [[ "$(printf '%s' "$serial"|tr -d '-'|tr '[:upper:]' '[:lower:]')" == "$wanted" ]]; then matches+="/dev/$dev"$'\n'; fi
  done < <(lsblk -dnro NAME,SERIAL)
  matches="$(printf '%s' "$matches"|sed '/^$/d'|sort -u)"
  [[ "$(printf '%s\n' "$matches"|sed '/^$/d'|wc -l)" -eq 1 ]] || die "BACKUP_VOLUME_ID did not resolve to exactly one NVMe disk"
  backup_device="$(printf '%s\n' "$matches"|head -n1)"
  [[ -b "$backup_device" && "$(lsblk -dnro TYPE "$backup_device")" == disk ]] || die "Resolved backup device is not a whole disk"
  [[ -z "$(lsblk -nro MOUNTPOINT "$backup_device"|sed '/^$/d')" ]] || die "Backup disk has an unexpected mount"
  install -d -m 0750 /u02/backup
  if ! blkid "$backup_device" >/dev/null 2>&1; then
    [[ -z "$(wipefs -n "$backup_device" 2>/dev/null)" ]] || die "Refusing to format a disk containing signatures"
    [[ -z "$(lsblk -nro NAME "$backup_device"|tail -n+2)" ]] || die "Refusing to format a disk containing partitions"
    mkfs.xfs -L CLBACKUP "$backup_device"
  fi
  [[ "$(blkid -s TYPE -o value "$backup_device")" == xfs ]] || die "Backup filesystem must be XFS"
  backup_uuid="$(blkid -s UUID -o value "$backup_device")"
  [[ -n "$backup_uuid" ]] || die "Backup filesystem UUID unavailable"
  sed -i '\|[[:space:]]/u02/backup[[:space:]]|d' /etc/fstab
  printf 'UUID=%s /u02/backup xfs defaults,nofail 0 2\n' "$backup_uuid" >>/etc/fstab
  mountpoint -q /u02/backup || mount /u02/backup
  [[ "$(findmnt -nro UUID /u02/backup)" == "$backup_uuid" ]] || die "Mounted backup UUID mismatch"

  if getent group 54321 >/dev/null; then
    [[ "$(getent group 54321|cut -d: -f1)" == oracledata ]] || die "GID 54321 already assigned unexpectedly"
  else groupadd -g 54321 oracledata; fi
  install -d -m 0750 -o 54321 -g 54321 /u01/oradata /u02/backup/rman /u02/backup/logs /u02/backup/state
  chown 54321:54321 /u01/oradata /u02/backup /u02/backup/rman /u02/backup/logs /u02/backup/state

  install -d -m 0700 /etc/cloudlabs
  if [[ -f "$ORACLE_ENV" ]]; then
    [[ ! -L "$ORACLE_ENV" ]] || die "Oracle password file must not be a symbolic link"
    [[ "$(wc -l <"$ORACLE_ENV")" -eq 1 ]] || die "Oracle password file has unexpected content"
    ORACLE_PASSWORD="$(sed -n 's/^ORACLE_PWD=//p' "$ORACLE_ENV")"
    [[ "$ORACLE_PASSWORD" =~ ^[A-Za-z][A-Za-z0-9]+$ ]] || die "Oracle password file has an invalid value"
    chown root:root "$ORACLE_ENV"
    chmod 0600 "$ORACLE_ENV"
    log "Reusing the existing protected Oracle password file"
  else
    if docker container inspect oracle-free >/dev/null 2>&1 || find /u01/oradata -mindepth 1 -print -quit | grep -q .; then
      die "Persistent Oracle state exists but the protected Oracle password file is missing"
    fi
    ORACLE_PASSWORD="O$(openssl rand -hex 12)"
    printf 'ORACLE_PWD=%s\n' "$ORACLE_PASSWORD" >"$ORACLE_ENV"
    chown root:root "$ORACLE_ENV"
    chmod 0600 "$ORACLE_ENV"
    log "Created a protected Oracle password file"
  fi

  log "Pulling pinned Oracle Database Free image"
  docker pull "$ORACLE_IMAGE" || die "Oracle image pull failed; verify OCR access, terms, and authentication"
  actual_repo_digest=""
  while IFS= read -r repo_digest; do
    if [[ "$repo_digest" == "$ORACLE_REPOSITORY@"* ]]; then actual_repo_digest="$repo_digest"; break; fi
  done < <(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ORACLE_IMAGE")
  [[ -n "$actual_repo_digest" ]] || die "Pinned Oracle tag did not resolve to a nonempty repository digest"
  image_arch="$(docker image inspect --format '{{.Architecture}}' "$ORACLE_IMAGE")"
  [[ "$image_arch" == amd64 ]] || die "Oracle image architecture is not amd64"
  printf '%s\n' "$actual_repo_digest" >/opt/oracle-image-digest.txt
  chmod 0644 /opt/oracle-image-digest.txt
  if [[ "$actual_repo_digest" == "$ORACLE_REPOSITORY@$APPROVED_ORACLE_DIGEST" ]]; then
    log "Verified Oracle image digest $APPROVED_ORACLE_DIGEST"
  else
    log "WARNING: Oracle image digest differs from approved digest; continuing with resolved digest $actual_repo_digest"
  fi

  if docker container inspect oracle-free >/dev/null 2>&1; then
    [[ "$(docker inspect --format '{{.Config.Image}}' oracle-free)" == "$ORACLE_IMAGE" ]] || die "Existing oracle-free uses unexpected image"
    docker start oracle-free >/dev/null
  else
    docker run -d --name oracle-free --restart unless-stopped -p 1521:1521 --env-file "$ORACLE_ENV" \
      --mount type=bind,src=/u01/oradata,dst=/opt/oracle/oradata \
      --mount type=bind,src=/u02/backup,dst=/u02/backup "$ORACLE_IMAGE" >/dev/null
  fi

  log "Waiting up to 30 minutes for Oracle readiness"
  ready_ok=0
  for _ in $(seq 1 120); do
    cid="$(container_id 2>/dev/null || true)"
    if [[ -n "$cid" ]] && docker logs oracle-free 2>&1 | grep -q 'DATABASE IS READY TO USE!'; then
      if readiness_count="$(dsql "$cid" <<'SQL' 2>/dev/null
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
select count(*) from v$database where open_mode='READ WRITE';
exit
SQL
)"; then
        readiness_count="$(printf '%s' "$readiness_count"|tr -d '[:space:]')"
        if [[ "$readiness_count" == 1 ]]; then ready_ok=1; break; fi
      fi
    fi
    sleep 15
  done
  if (( ready_ok == 0 )); then
    docker ps -a --filter name=oracle-free || true
    docker logs --tail 200 oracle-free 2>&1|sed -E 's/(ORACLE_PWD|password)[=:][^[:space:]]+/\1=<redacted>/Ig' || true
    die "Oracle did not become ready"
  fi
  cid="$(container_id)" || die "Exactly one running oracle-free container is required"

  log "Configuring ARCHIVELOG and RMAN"
  dsql "$cid" <<'SQL'
whenever sqlerror exit failure
shutdown immediate;
startup mount;
alter database archivelog;
alter database open;
alter pluggable database all open;
alter pluggable database FREEPDB1 save state;
exit
SQL
  cid="$(container_id)" || die "Container stopped during database transition"
  drman "$cid" <<'RMAN'
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE DEVICE TYPE DISK PARALLELISM 1 BACKUP TYPE TO BACKUPSET;
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '/u02/backup/rman/%d_%T_%U.bkp';
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;
exit
RMAN

  install -d -m 0755 /opt/lab /opt/lab/diagnostics /opt/lab/workload
  install -d -m 0750 /opt/lab/evidence
  install -d -m 0700 /opt/lab/state
  install -m 0600 /dev/null /opt/lab/evidence/injection-audit.log

  log "Seeding FREEPDB1"
  dsql "$cid" <<'SQL'
whenever sqlerror exit failure rollback
set echo off feedback off
alter session set container=FREEPDB1;
declare n number; begin
 select count(*) into n from dba_tablespaces where tablespace_name='LABRECOVERY';
 if n=0 then execute immediate q'[create tablespace LABRECOVERY datafile '/opt/oracle/oradata/FREE/FREEPDB1/labrecovery01.dbf' size 256M autoextend on next 64M maxsize 1G]'; end if;
 select count(*) into n from dba_users where username='LABAPP';
 if n=0 then execute immediate 'create user LABAPP no authentication default tablespace LABRECOVERY quota unlimited on LABRECOVERY'; end if;
 select count(*) into n from dba_tables where owner='LABAPP' and table_name='CUSTOMERS';
 if n=0 then execute immediate 'create table LABAPP.CUSTOMERS(customer_id number primary key,region varchar2(16),status varchar2(12),padding varchar2(200)) tablespace LABRECOVERY'; end if;
 select count(*) into n from dba_tables where owner='LABAPP' and table_name='ORDERS';
 if n=0 then execute immediate 'create table LABAPP.ORDERS(order_id number primary key,customer_id number not null,order_date date not null,status varchar2(12),amount number(12,2),marker varchar2(80),padding varchar2(200)) tablespace LABRECOVERY'; end if;
 select count(*) into n from dba_indexes where owner='LABAPP' and index_name='ORDERS_CUSTOMER_IX';
 if n=0 then execute immediate 'create index LABAPP.ORDERS_CUSTOMER_IX on LABAPP.ORDERS(customer_id) tablespace LABRECOVERY'; end if;
end;
/
merge into LABAPP.CUSTOMERS d using (select level id,case mod(level,4) when 0 then 'NORTH' when 1 then 'SOUTH' when 2 then 'EAST' else 'WEST' end region,case when mod(level,10)=0 then 'INACTIVE' else 'ACTIVE' end status from dual connect by level<=20000) s on(d.customer_id=s.id) when not matched then insert values(s.id,s.region,s.status,rpad('C',100,'C'));
merge into LABAPP.ORDERS d using (select level id,mod(level,20000)+1 customer_id,date '2025-01-01'+mod(level,365) order_date,case when mod(level,40)=0 then 'PENDING' else 'COMPLETE' end status,mod(level*17,100000)/100 amount from dual connect by level<=300000) s on(d.order_id=s.id) when not matched then insert values(s.id,s.customer_id,s.order_date,s.status,s.amount,'BASE-'||s.id,rpad('O',120,'O'));
commit;
begin dbms_stats.gather_table_stats('LABAPP','CUSTOMERS',cascade=>true); dbms_stats.gather_table_stats('LABAPP','ORDERS',cascade=>true); end;
/
merge into LABAPP.ORDERS d using (select 300000+level id,mod(level,100)+1 customer_id from dual connect by level<=120000) s on(d.order_id=s.id) when not matched then insert values(s.id,s.customer_id,trunc(sysdate)-mod(s.id,7),'PENDING',99.99,'BULK-'||s.id,rpad('B',120,'B'));
commit;
exit
SQL

  cat >/opt/lab/workload/regressed-query.sql <<'SQL'
set timing on lines 180 pages 100
alter session set container=FREEPDB1;
select /* CLOUDLABS_REPORT gather_plan_statistics */ c.region,count(*) order_count,round(sum(o.amount),2) total_amount from LABAPP.CUSTOMERS c join LABAPP.ORDERS o on o.customer_id=c.customer_id where o.status='PENDING' and o.order_date>=trunc(sysdate)-30 group by c.region order by c.region;
select * from table(dbms_xplan.display_cursor(null,null,'ALLSTATS LAST +PREDICATE'));
SQL
  cat >/opt/lab/workload/change.sql <<'SQL'
whenever sqlerror exit failure rollback
alter session set container=FREEPDB1;
merge into LABAPP.ORDERS d using(select 900000001 id from dual)s on(d.order_id=s.id) when not matched then insert values(s.id,1,sysdate,'COMPLETE',123.45,'WORKLOAD-CHANGE',rpad('W',120,'W'));
commit;
SQL
  cat >/opt/lab/diagnostics/seeded-awr-style-report.txt <<'EOF'
SIMULATED AWR-STYLE TRAINING REPORT — NOT GENERATED BY ORACLE AWR
Dominant SQL tag: CLOUDLABS_REPORT. Observed pattern: elevated user I/O after the bulk PENDING load.
LABAPP.ORDERS estimates predate that load. Corroborate with a live plan, runtime, V$SQL/V$SQL_PLAN, and checksum.
EOF
  cat >/opt/lab/diagnostics/seeded-ash-style-report.txt <<'EOF'
SIMULATED ASH-STYLE TRAINING REPORT — NOT GENERATED BY ORACLE ASH
Samples concentrate on CLOUDLABS_REPORT and user I/O, not blocking or CPU. Treat this only as a diagnostic lead.
EOF
  chmod 0644 /opt/lab/workload/*.sql /opt/lab/diagnostics/*.txt

  cat >/opt/lab/inject-ex1.sh <<'INJECT1'
#!/bin/bash
set -euo pipefail
set -E
umask 077
READY=/opt/lab/.ready; STATE=/opt/lab/state/ex1.env; LOG=/opt/lab/evidence/injection-audit.log
get_container(){ local ids count name; ids="$(docker ps --filter name=oracle-free --filter status=running -q)"; count="$(printf '%s\n' "$ids"|sed '/^$/d'|wc -l)"; [[ "$count" -eq 1 ]]||return 1; CONTAINER_ID="$(printf '%s\n' "$ids"|head -n1)"; name="$(docker inspect --format '{{.Name}}' "$CONTAINER_ID")"; [[ "$name" == /oracle-free ]]; }
[[ $(id -u) -eq 0 ]]||{ echo 'Run with sudo.' >&2; exit 1; }
[[ -f "$READY" ]]||{ echo 'Lab is not ready.' >&2; exit 1; }
mountpoint -q /u02/backup||{ echo 'Backup storage is not mounted.' >&2; exit 1; }
[[ ! -e "$STATE" ]]||{ echo 'Exercise 1 injection already exists.' >&2; exit 1; }
get_container||{ echo 'Exactly one running oracle-free container is required.' >&2; exit 1; }
ROW="$(docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba' <<'SQL'
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
select current_scn||'|'||resetlogs_change#||'|'||replace((select open_mode from v$pdbs where name='FREEPDB1'),' ','') from v$database where open_mode='READ WRITE';
exit
SQL
)"; ROW="$(printf '%s' "$ROW"|tr -d '[:space:]')"; [[ "$ROW" =~ ^[0-9]+\|[0-9]+\|READWRITE$ ]]||{ echo 'CDB/FREEPDB1 is not healthy.' >&2; exit 1; }
IFS='|' read -r TARGET_SCN BASE_RESETLOGS_SCN _ <<<"$ROW"; MARKER="BAD-${TARGET_SCN}"; ORDER_ID=$((910000000+TARGET_SCN%89999999))
docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba' <<SQL
whenever sqlerror exit failure rollback
alter session set container=FREEPDB1;
insert into LABAPP.ORDERS values($ORDER_ID,1,sysdate,'PENDING',999999.99,'$MARKER',rpad('X',120,'X'));
commit;
exit
SQL
cat >"$STATE" <<EOF
TARGET_SCN=$TARGET_SCN
BASE_RESETLOGS_SCN=$BASE_RESETLOGS_SCN
MARKER=$MARKER
UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "$STATE"; printf '%s ex1 target=%s marker=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_SCN" "$MARKER" >>"$LOG"
echo "Target SCN: $TARGET_SCN"; echo "Bad transaction marker: $MARKER"; echo 'Recover the whole CDB to the target SCN and OPEN RESETLOGS.'
INJECT1

  cat >/opt/lab/inject-ex2.sh <<'INJECT2'
#!/bin/bash
set -euo pipefail
set -E
umask 077
READY=/opt/lab/.ready; EX1=/opt/lab/state/ex1.env; STATE=/opt/lab/state/ex2.env; LOG=/opt/lab/evidence/injection-audit.log
SAFETY_TAG=CLOUDLABS_EX2_SAFETY_L0; CONTAINER_ID=""; CURRENT_RESETLOGS_SCN=""; BACKUP_PROVENANCE=""
stamp(){ date -u +'%Y-%m-%dT%H:%M:%SZ'; }
audit(){ printf '%s %s\n' "$(stamp)" "$*" >>"$LOG"; }
warn(){ printf 'WARNING: %s\n' "$*" >&2; audit "warning=$*"; }
get_container(){ local ids count name; ids="$(docker ps --filter name=oracle-free --filter status=running -q)"; count="$(printf '%s\n' "$ids"|sed '/^$/d'|wc -l)"; [[ "$count" -eq 1 ]]||return 1; CONTAINER_ID="$(printf '%s\n' "$ids"|sed '/^$/d'|head -n1)"; name="$(docker inspect --format '{{.Name}}' "$CONTAINER_ID")"; [[ "$name" == /oracle-free ]]; }
sql(){ docker exec -i "$CONTAINER_ID" bash -lc 'sqlplus -s / as sysdba'; }
rman(){ docker exec -i "$CONTAINER_ID" bash -lc 'rman target /'; }
assess_current_l0(){
  local row usable safety
  rman <<'RMAN' >/u02/backup/logs/ex2-crosscheck.log 2>&1 || return 1
crosscheck backup;
exit
RMAN
  row="$(sql <<SQL
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
select count(*)||'|'||nvl(sum(case when upper(nvl(x.tag,'-')) like '${SAFETY_TAG}%' then 1 else 0 end),0) from (
 select bs.set_stamp,bs.set_count,max(bs.tag) tag from v\$backup_set_details bs
 where bs.backup_type='D' and bs.incremental_level=0 and bs.resetlogs_change#=${CURRENT_RESETLOGS_SCN} and bs.status='A'
 and (select count(distinct bd.file#) from v\$backup_datafile bd where bd.set_stamp=bs.set_stamp and bd.set_count=bs.set_count and bd.file#>0)=(select count(*) from v\$datafile)
 and exists (select 1 from v\$backup_piece_details bp where bp.set_stamp=bs.set_stamp and bp.set_count=bs.set_count)
 and not exists (select 1 from v\$backup_piece_details bp where bp.set_stamp=bs.set_stamp and bp.set_count=bs.set_count and (bp.status<>'A' or bp.deleted='YES'))
 group by bs.set_stamp,bs.set_count) x;
exit
SQL
)" || return 1
  row="$(printf '%s' "$row"|tr -d '[:space:]')"; [[ "$row" =~ ^[0-9]+\|[0-9]+$ ]]||return 1
  IFS='|' read -r usable safety <<<"$row"; (( usable > 0 ))||return 1
  rman <<'RMAN' >/u02/backup/logs/ex2-restore-validate.log 2>&1 || return 1
restore database validate;
exit
RMAN
  if (( safety == usable )); then BACKUP_PROVENANCE=INJECTOR_CREATED; else BACKUP_PROVENANCE=LEARNER_CREATED; fi
}
[[ $(id -u) -eq 0 ]]||{ echo 'Run with sudo.' >&2; exit 1; }
[[ -f "$READY" ]]||{ echo 'General lab readiness is missing.' >&2; exit 1; }
mountpoint -q /u02/backup||{ echo 'Backup storage is not mounted.' >&2; exit 1; }
[[ ! -e "$STATE" ]]||{ echo 'Exercise 2 injection already exists.' >&2; exit 1; }
get_container||{ echo 'Exactly one running oracle-free container is required.' >&2; exit 1; }
HEALTH="$(sql <<'SQL'
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
select resetlogs_change#||'|'||replace(open_mode,' ','')||'|'||replace((select open_mode from v$pdbs where name='FREEPDB1'),' ','') from v$database;
exit
SQL
)"; HEALTH="$(printf '%s' "$HEALTH"|tr -d '[:space:]')"; [[ "$HEALTH" =~ ^[0-9]+\|READWRITE\|READWRITE$ ]]||{ echo 'CDB/FREEPDB1 is not healthy.' >&2; exit 1; }
IFS='|' read -r CURRENT_RESETLOGS_SCN _ _ <<<"$HEALTH"
if [[ ! -f "$EX1" ]]; then warn 'Exercise 1 evidence is absent; Exercise 2 will continue independently.'
else
  EX1_PROVEN=0; BASE="$(sed -n 's/^BASE_RESETLOGS_SCN=//p' "$EX1"|head -n1)"; MARK="$(sed -n 's/^MARKER=//p' "$EX1"|head -n1)"
  if [[ "$BASE" =~ ^[0-9]+$ && "$MARK" =~ ^BAD-[0-9]+$ ]]; then
    BAD_COUNT="$(sql <<SQL
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
alter session set container=FREEPDB1;
select count(*) from LABAPP.ORDERS where marker='$MARK';
exit
SQL
)" || true; BAD_COUNT="$(printf '%s' "$BAD_COUNT"|tr -d '[:space:]')"
    [[ "$BAD_COUNT" == 0 ]] && (( CURRENT_RESETLOGS_SCN > BASE )) && EX1_PROVEN=1
  fi
  (( EX1_PROVEN == 1 )) || warn 'Exercise 1 PITR/RESETLOGS is not proven; Exercise 2 will continue independently.'
fi
audit "ex2 current_resetlogs_scn=$CURRENT_RESETLOGS_SCN assessing_current_incarnation_level0"
if ! assess_current_l0; then
  warn 'No usable current-incarnation level 0 was proven; creating an injector safety backup that earns no Exercise 1 credit.'
  rman <<RMAN >/u02/backup/logs/ex2-safety-backup.log 2>&1
sql 'alter system archive log current';
backup incremental level 0 database tag '${SAFETY_TAG}';
backup archivelog all not backed up 1 times tag 'CLOUDLABS_EX2_SAFETY_ARC';
backup current controlfile tag 'CLOUDLABS_EX2_SAFETY_CTL';
backup spfile tag 'CLOUDLABS_EX2_SAFETY_SPFILE';
exit
RMAN
  BACKUP_PROVENANCE=INJECTOR_CREATED; audit "ex2 safety_backup=created tag=$SAFETY_TAG resetlogs_scn=$CURRENT_RESETLOGS_SCN credit_ex1=NO"
  assess_current_l0 || { audit 'ex2 safety_backup=verification_failed'; echo 'Safety backup verification failed; loss was not injected.' >&2; exit 1; }
  BACKUP_PROVENANCE=INJECTOR_CREATED
else audit "ex2 usable_level0=existing provenance=$BACKUP_PROVENANCE resetlogs_scn=$CURRENT_RESETLOGS_SCN"; fi
ROW="$(sql <<'SQL'
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
alter session set container=FREEPDB1;
select file_id||'|'||file_name||'|'||(select count(*)||':'||nvl(sum(order_id),0) from LABAPP.ORDERS) from dba_data_files where tablespace_name='LABRECOVERY';
exit
SQL
)"; ROW="$(printf '%s' "$ROW"|sed '/^[[:space:]]*$/d'|tail -n1)"
[[ "$(printf '%s' "$ROW"|grep -o '|'|wc -l)" -eq 2 ]]||{ echo 'Training datafile identity is ambiguous.' >&2; exit 1; }
IFS='|' read -r FILE_NO CONTAINER_FILE PRELOSS_CHECKSUM <<<"$ROW"; FILE_NO="${FILE_NO//[[:space:]]/}"; CONTAINER_FILE="${CONTAINER_FILE//[[:space:]]/}"; PRELOSS_CHECKSUM="${PRELOSS_CHECKSUM//[[:space:]]/}"
[[ "$FILE_NO" =~ ^[0-9]+$ && "$CONTAINER_FILE" == /opt/oracle/oradata/FREE/FREEPDB1/labrecovery01.dbf ]]||{ echo 'Safety check rejected datafile.' >&2; exit 1; }
case "${CONTAINER_FILE,,}" in *system*|*sysaux*|*undo*|*temp*|*control*|*redo*) echo 'Protected file rejected.' >&2; exit 1;; esac
REL="${CONTAINER_FILE#/opt/oracle/oradata/}"; HOST_FILE="$(realpath -e "/u01/oradata/$REL")"
[[ "$HOST_FILE" == /u01/oradata/* && -f "$HOST_FILE" && ! -L "$HOST_FILE" ]]||{ echo 'Safe host bind path could not be proven.' >&2; exit 1; }
sql <<'SQL'
whenever sqlerror exit failure
alter session set container=FREEPDB1;
alter tablespace LABRECOVERY offline immediate;
exit
SQL
unlink -- "$HOST_FILE"; [[ ! -e "$HOST_FILE" ]]||{ echo 'Datafile removal failed.' >&2; exit 1; }
cat >"$STATE" <<EOF
FILE_NO=$FILE_NO
CONTAINER_FILE=$CONTAINER_FILE
HOST_FILE=$HOST_FILE
PRELOSS_CHECKSUM=$PRELOSS_CHECKSUM
RESETLOGS_SCN=$CURRENT_RESETLOGS_SCN
BACKUP_PROVENANCE=$BACKUP_PROVENANCE
INJECTOR_BACKUP_TAG=$([[ "$BACKUP_PROVENANCE" == INJECTOR_CREATED ]] && printf '%s' "$SAFETY_TAG" || printf 'NONE')
EX1_BACKUP_CREDIT=NO
UTC=$(stamp)
EOF
chmod 0600 "$STATE"; audit "ex2 injected file_no=$FILE_NO host_file=$HOST_FILE backup_provenance=$BACKUP_PROVENANCE ex1_credit=NO"
echo "Training datafile $FILE_NO was removed from its safe host bind path."; echo "Backup provenance: $BACKUP_PROVENANCE (never awards Exercise 1 credit)."; echo 'Restore and recover only this FREEPDB1 training datafile.'
INJECT2
  chown root:root /opt/lab/inject-ex1.sh /opt/lab/inject-ex2.sh
  chmod 0750 /opt/lab/inject-ex1.sh /opt/lab/inject-ex2.sh

  dsql "$cid" <<'SQL' >/opt/lab/state/seed-baseline.txt
whenever sqlerror exit failure
set pages 0 feedback off heading off
alter session set container=FREEPDB1;
select count(*)||':'||nvl(sum(order_id),0) from LABAPP.ORDERS;
exit
SQL
  chmod 0600 /opt/lab/state/seed-baseline.txt

  log "Proving database shutdown/mount/RMAN tooling keeps the container running"
  dsql "$cid" <<'SQL'
whenever sqlerror exit failure
shutdown immediate;
exit
SQL
  cid="$(container_id)" || die "Container stopped when database shut down"
  dsql "$cid" <<'SQL'
whenever sqlerror exit failure
startup mount;
exit
SQL
  cid="$(container_id)" || die "Container stopped in mount state"
  drman "$cid" <<'RMAN' >/u02/backup/logs/bootstrap-rman-validate.log
validate database;
exit
RMAN
  cid="$(container_id)" || die "Container stopped during RMAN validation"
  dsql "$cid" <<'SQL'
whenever sqlerror exit failure
alter database open;
alter pluggable database all open;
alter pluggable database FREEPDB1 save state;
exit
SQL

  mountpoint -q /u02/backup || die "Backup mount check failed"
  [[ "$(stat -c '%u:%g' /u01/oradata)" == 54321:54321 ]] || die "Oracle data ownership check failed"
  [[ "$(stat -c '%u:%g' /u02/backup)" == 54321:54321 ]] || die "Backup ownership check failed"
  [[ "$(stat -c '%U:%G:%a' "$ORACLE_ENV")" == root:root:600 ]] || die "Oracle password file permissions are unsafe"
  systemctl is-active --quiet docker || die "Docker check failed"
  cid="$(container_id)" || die "Container check failed"
  seed_check="$(dsql "$cid" <<'SQL'
set pages 0 feedback off heading off echo off verify off
select (select replace(open_mode,' ','') from v$pdbs where name='FREEPDB1')||'|'||(select round(nvl(sum(bytes),0)/1024/1024) from cdb_segments where con_id=(select con_id from v$pdbs where name='FREEPDB1') and owner='LABAPP')||'|'||(select count(*) from v$datafile d join v$containers c on c.con_id=d.con_id where c.name='FREEPDB1' and lower(d.name) like '%labrecovery01.dbf') from dual;
exit
SQL
)"; seed_check="$(printf '%s' "$seed_check"|tr -d '[:space:]')"
  [[ "$seed_check" =~ ^READWRITE\|[0-9]+\|1$ ]] || die "CDB/PDB seed check failed"
  seed_mb="$(printf '%s' "$seed_check"|cut -d'|' -f2)"; (( seed_mb < 2048 )) || die "Seed exceeds 2 GiB"
  [[ "$(stat -c '%U:%G:%a' /opt/lab/inject-ex1.sh)" == root:root:750 ]] || die "inject-ex1 permissions unsafe"
  [[ "$(stat -c '%U:%G:%a' /opt/lab/inject-ex2.sh)" == root:root:750 ]] || die "inject-ex2 permissions unsafe"

  systemctl enable amazon-ssm-agent
  systemctl restart amazon-ssm-agent
  systemctl is-active --quiet amazon-ssm-agent || die "SSM Agent is not active"
  cat >"$READY" <<EOF
READY_UTC=$(stamp)
BACKUP_UUID=$backup_uuid
CONTAINER=oracle-free
CDB=FREE
PDB=FREEPDB1
EOF
  chown root:root "$READY"; chmod 0644 "$READY"
  signal_stack true
  log "CloudLabs Stage 1 bootstrap complete"
}
main
