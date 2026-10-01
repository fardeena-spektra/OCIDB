#!/bin/bash
set -Eeuo pipefail
exec > >(tee -a /var/log/cloudlabs-bootstrap.log) 2>&1
umask 077

# The CloudFormation UserData wrapper must export every value below. There are
# intentionally no credential, Region, stack, resource, or volume defaults.
: "${ADMIN_USERNAME:?wrapper must export ADMIN_USERNAME}"
: "${ADMIN_PASSWORD:?wrapper must export ADMIN_PASSWORD}"
: "${AWS_REGION:?wrapper must export AWS_REGION}"
: "${CFN_STACK:?wrapper must export CFN_STACK}"
: "${CFN_RESOURCE:?wrapper must export CFN_RESOURCE=LabVm}"
: "${BACKUP_VOLUME_ID:?wrapper must export BACKUP_VOLUME_ID}"
[[ "$CFN_RESOURCE" == "LabVm" ]] || { echo "CFN_RESOURCE must be LabVm" >&2; exit 2; }
[[ "$AWS_REGION" == "us-east-1" ]] || { echo "This lab supports only us-east-1" >&2; exit 2; }

READY=/opt/lab/.ready
ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export ORACLE_HOME ORACLE_SID=FREE PATH="$ORACLE_HOME/bin:$PATH"
CFN_SIGNAL=
SIGNALLED=0

stamp() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[%s] %s\n' "$(stamp)" "$*"; }
die() { log "ERROR: $*"; return 1; }

# This script is the sole owner of CloudFormation signaling. The EXIT trap sends
# failure once, using the same pip-installed executable used for success.
on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && SIGNALLED == 0 )) && [[ -n "$CFN_SIGNAL" && -x "$CFN_SIGNAL" ]]; then
    "$CFN_SIGNAL" --success false \
      --reason "Stage 1 bootstrap failed; inspect /var/log/cloudlabs-bootstrap.log" \
      --stack "$CFN_STACK" --resource "$CFN_RESOURCE" --region "$AWS_REGION" || true
    SIGNALLED=1
  fi
  exit "$rc"
}
trap on_exit EXIT

log "CloudLabs Stage 1 bootstrap starting"
rm -f "$READY"
[[ $(id -u) -eq 0 ]] || die "UserData must run as root"
[[ $(uname -m) == x86_64 ]] || die "Oracle Database Free OL9 RPM requires x86_64"
grep -qE '^PLATFORM_ID=.*el9' /etc/os-release || die "Oracle Linux 9 is required"

# AWS documents pip installation of this archive on non-Amazon-Linux systems.
# Install it before resolving or invoking cfn-signal.
dnf install -y python3 python3-pip curl wget unzip jq git util-linux xfsprogs openssl sudo shadow-utils cronie
pip3 install --disable-pip-version-check --no-cache-dir --upgrade \
  https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz
CFN_SIGNAL="$(command -v cfn-signal)"
[[ -x "$CFN_SIGNAL" ]] || die "pip3 did not install an executable cfn-signal"
install -d -m 0700 /var/lib/cloudlabs
printf '%s\n' "$CFN_SIGNAL" >/var/lib/cloudlabs/cfn-signal.path
chmod 0600 /var/lib/cloudlabs/cfn-signal.path

# AWS's Oracle Linux instructions publish this Region-local RPM form. Install
# the package before any enable/start/status operation on its service.
SSM_RPM=/var/tmp/amazon-ssm-agent.rpm
SSM_RPM_URL="https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/linux_amd64/amazon-ssm-agent.rpm"
curl --fail --silent --show-error --location --retry 3 "$SSM_RPM_URL" --output "$SSM_RPM"
rpm -K "$SSM_RPM"
dnf install -y "$SSM_RPM"
rpm -q amazon-ssm-agent >/dev/null
rm -f "$SSM_RPM"

# Configure the requested SSH principal. The password is consumed through stdin,
# is never placed in argv, and is never persisted in a credentials file.
if ! id "$ADMIN_USERNAME" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$ADMIN_USERNAME"
fi
printf '%s:%s\n' "$ADMIN_USERNAME" "$ADMIN_PASSWORD" | chpasswd
usermod -aG wheel "$ADMIN_USERNAME"
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/60-cloudlabs-password.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM yes
EOF
chmod 0600 /etc/ssh/sshd_config.d/60-cloudlabs-password.conf
sshd -t
systemctl restart sshd
sshd -T | grep -qi '^passwordauthentication yes$'

normalize_vol() { printf '%s' "$1" | tr -d '-' | tr '[:upper:]' '[:lower:]'; }
find_backup_device() {
  local wanted dev serial root_source root_parent candidates
  wanted="$(normalize_vol "$BACKUP_VOLUME_ID")"
  for dev in /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*; do
    [[ -e "$dev" ]] || continue
    serial="$(basename "$dev" | sed 's/^nvme-Amazon_Elastic_Block_Store_//')"
    if [[ $(normalize_vol "$serial") == "$wanted" ]]; then readlink -f "$dev"; return 0; fi
  done
  while read -r dev serial; do
    if [[ $(normalize_vol "$serial") == "$wanted" ]]; then printf '/dev/%s\n' "$dev"; return 0; fi
  done < <(lsblk -dnro NAME,SERIAL)
  root_source="$(findmnt -nro SOURCE /)"
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n1)"
  candidates="$(lsblk -bdnpo NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT | awk -v root="/dev/$root_parent" '$2=="disk" && $1!=root && $3>=28000000000 && $4=="" && $5=="" {print $1}')"
  [[ $(sed '/^$/d' <<<"$candidates" | wc -l) -eq 1 ]] || return 1
  printf '%s\n' "$candidates"
}
BACKUP_DEVICE="$(find_backup_device)" || die "Could not uniquely identify backup volume $BACKUP_VOLUME_ID"
[[ -b "$BACKUP_DEVICE" ]] || die "Backup device is not a block device"
install -d -m 0750 /u02/backup
if ! blkid "$BACKUP_DEVICE" >/dev/null 2>&1; then
  ! wipefs -n "$BACKUP_DEVICE" | grep -q . || die "Refusing to format a disk with existing signatures"
  mkfs.xfs -f -L CLBACKUP "$BACKUP_DEVICE"
fi
BACKUP_UUID="$(blkid -s UUID -o value "$BACKUP_DEVICE")"
[[ -n "$BACKUP_UUID" ]] || die "Backup filesystem has no UUID"
if ! grep -qE "^[^#]*UUID=${BACKUP_UUID}[[:space:]]+/u02/backup[[:space:]]" /etc/fstab; then
  sed -i '\|[[:space:]]/u02/backup[[:space:]]|d' /etc/fstab
  printf 'UUID=%s /u02/backup xfs defaults,nofail 0 2\n' "$BACKUP_UUID" >>/etc/fstab
fi
mountpoint -q /u02/backup || mount /u02/backup
[[ $(findmnt -nro UUID /u02/backup) == "$BACKUP_UUID" ]] || die "Mounted backup UUID mismatch"
install -d -m 0750 /u02/backup/rman /u02/backup/logs

# Install only Oracle-published Database Free media.
dnf install -y oracle-database-preinstall-23ai
ORACLE_RPM=/var/tmp/oracle-database-free-23ai-1.0-1.el9.x86_64.rpm
ORACLE_RPM_URL=https://download.oracle.com/otn-pub/otn_software/db-free/oracle-database-free-23ai-1.0-1.el9.x86_64.rpm
if ! rpm -q oracle-database-free-23ai >/dev/null 2>&1; then
  curl --fail --location --retry 3 "$ORACLE_RPM_URL" --output "$ORACLE_RPM"
  rpm -K "$ORACLE_RPM" | grep -Eq 'digests signatures OK|digests OK'
  dnf localinstall -y "$ORACLE_RPM"
  rm -f "$ORACLE_RPM"
fi
[[ -x "$ORACLE_HOME/bin/sqlplus" ]] || die "sqlplus was not installed"
if [[ ! -f /opt/oracle/oradata/FREE/system01.dbf ]]; then
  # The Oracle configurator requires an administrative password twice. It is
  # supplied only on stdin and is not retained by this script.
  printf '%s\n%s\n' "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" | /etc/init.d/oracle-free-23ai configure
fi
chown -R oracle:oinstall /u02/backup
chmod 0750 /u02/backup /u02/backup/rman /u02/backup/logs

sql_sys() {
  su - oracle -c "export ORACLE_SID=FREE; export PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba"
}

# SHUTDOWN is never issued from PL/SQL or EXECUTE IMMEDIATE. Query the running
# CDB first, then perform the ARCHIVELOG transition as top-level SQL*Plus commands.
LOG_MODE="$(sql_sys <<'SQL'
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
select trim(log_mode) from v$database;
exit
SQL
)"
LOG_MODE="${LOG_MODE//[[:space:]]/}"
if [[ "$LOG_MODE" != ARCHIVELOG ]]; then
  sql_sys <<'SQL'
whenever sqlerror exit failure
shutdown immediate;
startup mount;
alter database archivelog;
alter database open;
exit
SQL
fi
sql_sys <<'SQL'
whenever sqlerror exit failure rollback
alter pluggable database FREEPDB1 open;
alter pluggable database FREEPDB1 save state;
alter system set db_recovery_file_dest_size=10G scope=both;
exit
SQL
su - oracle -c "export ORACLE_SID=FREE; export PATH=$ORACLE_HOME/bin:\$PATH; rman target /" <<'RMAN'
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE DEVICE TYPE DISK PARALLELISM 1 BACKUP TYPE TO BACKUPSET;
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '/u02/backup/rman/%d_%T_%U.bkp';
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;
RMAN

install -d -m 0755 /opt/lab /opt/lab/diagnostics /opt/lab/workload
install -d -m 0770 /opt/lab/evidence
install -d -m 0700 /opt/lab/state
chown -R root:root /opt/lab

# All schema objects are in FREEPDB1. Conditional DDL and keyed MERGE statements
# make reruns deterministic; the bulk skew is not appended repeatedly.
sql_sys <<'SQL'
whenever sqlerror exit failure rollback
set echo off feedback off
alter session set container=FREEPDB1;
declare n number; begin
  select count(*) into n from dba_tablespaces where tablespace_name='LABRECOVERY';
  if n=0 then execute immediate q'[create tablespace LABRECOVERY datafile '/opt/oracle/oradata/FREE/FREEPDB1/labrecovery01.dbf' size 256M autoextend on next 64M maxsize 1G]'; end if;
  select count(*) into n from dba_users where username='LABAPP';
  if n=0 then execute immediate 'create user LABAPP no authentication default tablespace LABRECOVERY quota unlimited on LABRECOVERY'; end if;
  select count(*) into n from dba_tables where owner='LABAPP' and table_name='CUSTOMERS';
  if n=0 then execute immediate 'create table LABAPP.CUSTOMERS (customer_id number primary key, region varchar2(16), status varchar2(12), padding varchar2(200)) tablespace LABRECOVERY'; end if;
  select count(*) into n from dba_tables where owner='LABAPP' and table_name='ORDERS';
  if n=0 then execute immediate 'create table LABAPP.ORDERS (order_id number primary key, customer_id number not null, order_date date not null, status varchar2(12), amount number(12,2), marker varchar2(80), padding varchar2(200)) tablespace LABRECOVERY'; end if;
  select count(*) into n from dba_indexes where owner='LABAPP' and index_name='ORDERS_CUSTOMER_IX';
  if n=0 then execute immediate 'create index LABAPP.ORDERS_CUSTOMER_IX on LABAPP.ORDERS(customer_id) tablespace LABRECOVERY'; end if;
end;
/
grant create table, create procedure to LABAPP;
merge into LABAPP.CUSTOMERS d using (
 select level customer_id,
        case mod(level,4) when 0 then 'NORTH' when 1 then 'SOUTH' when 2 then 'EAST' else 'WEST' end region,
        case when mod(level,10)=0 then 'INACTIVE' else 'ACTIVE' end status,
        rpad('C',100,'C') padding
 from dual connect by level <= 20000
) s on (d.customer_id=s.customer_id)
when not matched then insert (customer_id,region,status,padding) values (s.customer_id,s.region,s.status,s.padding);
merge into LABAPP.ORDERS d using (
 select level order_id, mod(level,20000)+1 customer_id, date '2025-01-01'+mod(level,365) order_date,
        case when mod(level,40)=0 then 'PENDING' else 'COMPLETE' end status,
        mod(level*17,100000)/100 amount, 'BASE-'||to_char(level) marker, rpad('O',120,'O') padding
 from dual connect by level <= 300000
) s on (d.order_id=s.order_id)
when not matched then insert (order_id,customer_id,order_date,status,amount,marker,padding)
 values (s.order_id,s.customer_id,s.order_date,s.status,s.amount,s.marker,s.padding);
commit;
begin
 dbms_stats.gather_table_stats('LABAPP','CUSTOMERS',cascade=>true);
 dbms_stats.gather_table_stats('LABAPP','ORDERS',cascade=>true);
end;
/
merge into LABAPP.ORDERS d using (
 select 300000+level order_id, mod(level,100)+1 customer_id, trunc(sysdate)-mod(level,7) order_date,
        'PENDING' status, 99.99 amount, 'BULK-'||to_char(level) marker, rpad('B',120,'B') padding
 from dual connect by level <= 120000
) s on (d.order_id=s.order_id)
when not matched then insert (order_id,customer_id,order_date,status,amount,marker,padding)
 values (s.order_id,s.customer_id,s.order_date,s.status,s.amount,s.marker,s.padding);
commit;
exit
SQL

cat >/opt/lab/workload/regressed-query.sql <<'SQL'
set timing on lines 180 pages 100
alter session set container=FREEPDB1;
select /* CLOUDLABS_REPORT */ c.region, count(*) order_count, round(sum(o.amount),2) total_amount
from LABAPP.CUSTOMERS c join LABAPP.ORDERS o on o.customer_id=c.customer_id
where o.status='PENDING' and o.order_date >= trunc(sysdate)-30
group by c.region order by c.region;
select * from table(dbms_xplan.display_cursor(null,null,'ALLSTATS LAST +PREDICATE'));
SQL
cat >/opt/lab/workload/change.sql <<'SQL'
whenever sqlerror exit failure rollback
alter session set container=FREEPDB1;
merge into LABAPP.ORDERS d using (select 900000001 order_id from dual) s on (d.order_id=s.order_id)
when not matched then insert (order_id,customer_id,order_date,status,amount,marker,padding)
values (900000001,1,sysdate,'COMPLETE',123.45,'WORKLOAD-CHANGE',rpad('W',120,'W'));
commit;
SQL
cat >/opt/lab/diagnostics/seeded-awr-style-report.txt <<'EOF'
SIMULATED AWR-STYLE TRAINING REPORT — NOT GENERATED BY ORACLE AWR
Dominant SQL tag: CLOUDLABS_REPORT
Observed pattern: elevated db file scattered/sequential reads after bulk PENDING-order load.
Object focus: LABAPP.ORDERS; estimates predate the bulk load and understate PENDING rows.
Corroborate with a live plan, V$SQL/V$SQL_PLAN, runtime, and a result checksum.
EOF
cat >/opt/lab/diagnostics/seeded-ash-style-report.txt <<'EOF'
SIMULATED ASH-STYLE TRAINING REPORT — NOT GENERATED BY ORACLE ASH
Sample concentration: CLOUDLABS_REPORT, SQL execution, user I/O waits on LABAPP.ORDERS.
No dominant blocking-session or CPU-run-queue signature is represented.
Use this only as a lead; prove the diagnosis with non-AWR live evidence.
EOF
chmod 0644 /opt/lab/workload/*.sql /opt/lab/diagnostics/*.txt

cat >/opt/lab/inject-ex1.sh <<'INJECT1'
#!/bin/bash
set -Eeuo pipefail
umask 077
READY=/opt/lab/.ready
STATE=/opt/lab/state/ex1.env
LOG=/opt/lab/evidence/injection-audit.log
ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export ORACLE_HOME ORACLE_SID=FREE PATH="$ORACLE_HOME/bin:$PATH"
[[ $(id -u) -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ -f "$READY" ]] || { echo 'Lab is not ready.' >&2; exit 1; }
[[ ! -e "$STATE" ]] || { echo 'Exercise 1 injection already recorded; refusing duplicate.' >&2; exit 1; }
systemctl is-active --quiet oracle-free-23ai || { echo 'CDB service is not healthy.' >&2; exit 1; }
PDB_MODE="$(su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba" <<'SQL'
set pages 0 feedback off heading off
select trim(open_mode) from v$pdbs where name='FREEPDB1';
SQL
)"
grep -q 'READ WRITE' <<<"$PDB_MODE" || { echo 'FREEPDB1 is not READ WRITE.' >&2; exit 1; }
IFS='|' read -r TARGET_SCN RESETLOGS_SCN <<<"$(su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba" <<'SQL'
set pages 0 feedback off heading off echo off verify off
select current_scn||'|'||resetlogs_change# from v$database;
SQL
)"
TARGET_SCN="${TARGET_SCN//[[:space:]]/}"; RESETLOGS_SCN="${RESETLOGS_SCN//[[:space:]]/}"
[[ "$TARGET_SCN" =~ ^[0-9]+$ && "$RESETLOGS_SCN" =~ ^[0-9]+$ ]] || { echo 'Could not capture recovery state.' >&2; exit 1; }
MARKER="BAD-${TARGET_SCN}"
su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba" <<SQL
whenever sqlerror exit failure rollback
alter session set container=FREEPDB1;
insert into LABAPP.ORDERS(order_id,customer_id,order_date,status,amount,marker,padding)
values (910000000+mod($TARGET_SCN,89999999),1,sysdate,'PENDING',999999.99,'$MARKER',rpad('X',120,'X'));
commit;
SQL
cat >"$STATE" <<EOF
TARGET_SCN=$TARGET_SCN
BASE_RESETLOGS_SCN=$RESETLOGS_SCN
MARKER=$MARKER
UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "$STATE"
printf '%s ex1 target=%s marker=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TARGET_SCN" "$MARKER" >>"$LOG"
echo "Target SCN: $TARGET_SCN"
echo "Bad transaction marker: $MARKER"
echo 'Objective: recover the entire CDB to the target SCN, then OPEN RESETLOGS.'
INJECT1

cat >/opt/lab/inject-ex2.sh <<'INJECT2'
#!/bin/bash
set -Eeuo pipefail
umask 077
READY=/opt/lab/.ready
EX1=/opt/lab/state/ex1.env
STATE=/opt/lab/state/ex2.env
LOG=/opt/lab/evidence/injection-audit.log
ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree
export ORACLE_HOME ORACLE_SID=FREE PATH="$ORACLE_HOME/bin:$PATH"
[[ $(id -u) -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ -f "$READY" && -f "$EX1" ]] || { echo 'Exercise 1 state/readiness is missing.' >&2; exit 1; }
[[ ! -e "$STATE" ]] || { echo 'Exercise 2 injection already recorded; refusing duplicate.' >&2; exit 1; }
# shellcheck disable=SC1090
. "$EX1"
# Produce exactly one delimited SQL row so both values are parsed atomically.
RECOVERY_ROW="$(su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba" <<SQL
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off
select d.resetlogs_change#||'|'||(select count(*) from LABAPP.ORDERS@FREEPDB1 where marker='$MARKER')
from v\$database d;
SQL
)"
RECOVERY_ROW="${RECOVERY_ROW//[[:space:]]/}"
[[ "$RECOVERY_ROW" =~ ^[0-9]+\|[0-9]+$ ]] || { echo 'Could not parse Exercise 1 recovery evidence.' >&2; exit 1; }
IFS='|' read -r CURRENT_RESETLOGS BAD_COUNT <<<"$RECOVERY_ROW"
(( BAD_COUNT == 0 && CURRENT_RESETLOGS > BASE_RESETLOGS_SCN )) || { echo 'Successful Exercise 1 RESETLOGS recovery is not proven.' >&2; exit 1; }
BACKUPS="$(su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba" <<SQL
set pages 0 feedback off heading off echo off verify off
select count(*) from v\$backup_set where status='A' and backup_type='D' and resetlogs_change#=$CURRENT_RESETLOGS;
SQL
)"
BACKUPS="${BACKUPS//[[:space:]]/}"
if (( BACKUPS == 0 )); then
  su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; rman target / log=/u02/backup/logs/ex2-post-resetlogs-backup.log" <<'RMAN'
backup database plus archivelog;
RMAN
fi
IFS='|' read -r FILE_NO FILE_NAME CHECKSUM <<<"$(su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba" <<'SQL'
set pages 0 feedback off heading off echo off verify off
alter session set container=FREEPDB1;
select file_id||'|'||file_name||'|'||(select count(*)||':'||nvl(sum(order_id),0) from LABAPP.ORDERS)
from dba_data_files where tablespace_name='LABRECOVERY';
SQL
)"
FILE_NO="${FILE_NO//[[:space:]]/}"; FILE_NAME="${FILE_NAME//[[:space:]]/}"; CHECKSUM="${CHECKSUM//[[:space:]]/}"
[[ "$FILE_NAME" == */FREEPDB1/labrecovery01.dbf ]] || { echo 'Safety check rejected unexpected datafile.' >&2; exit 1; }
[[ "$FILE_NAME" != *system* && "$FILE_NAME" != *sysaux* && "$FILE_NAME" != *undo* && "$FILE_NAME" != *temp* ]] || { echo 'Safety check rejected protected file.' >&2; exit 1; }
su - oracle -c "export ORACLE_SID=FREE PATH=$ORACLE_HOME/bin:\$PATH; sqlplus -s / as sysdba" <<'SQL'
whenever sqlerror exit failure
alter session set container=FREEPDB1;
alter tablespace LABRECOVERY offline immediate;
SQL
[[ -f "$FILE_NAME" ]] || { echo 'Training datafile was already absent; refusing ambiguous injection.' >&2; exit 1; }
rm -- "$FILE_NAME"
cat >"$STATE" <<EOF
FILE_NO=$FILE_NO
FILE_NAME=$FILE_NAME
PRELOSS_CHECKSUM=$CHECKSUM
RESETLOGS_SCN=$CURRENT_RESETLOGS
UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "$STATE"
printf '%s ex2 file_no=%s file=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FILE_NO" "$FILE_NAME" >>"$LOG"
echo "Training datafile $FILE_NO has been removed."
echo 'Objective: restore and recover only this FREEPDB1 datafile at PDB scope.'
INJECT2
chown root:root /opt/lab/inject-ex1.sh /opt/lab/inject-ex2.sh
chmod 0750 /opt/lab/inject-ex1.sh /opt/lab/inject-ex2.sh

sql_sys <<'SQL' >/opt/lab/state/seed-baseline.txt
set pages 0 feedback off heading off
alter session set container=FREEPDB1;
select count(*)||':'||nvl(sum(order_id),0) from LABAPP.ORDERS;
SQL
chmod 0600 /opt/lab/state/seed-baseline.txt

# Fail-closed readiness checks precede both the marker and success signal.
systemctl is-active --quiet oracle-free-23ai
lsnrctl status >/dev/null 2>&1
mountpoint -q /u02/backup
touch /u02/backup/.write-test && rm -f /u02/backup/.write-test
SEED_CHECK="$(sql_sys <<'SQL'
set pages 0 feedback off heading off echo off verify off
select (select trim(open_mode) from v$pdbs where name='FREEPDB1')||'|'||
       (select round(nvl(sum(bytes),0)/1024/1024) from cdb_segments where con_id=(select con_id from v$pdbs where name='FREEPDB1') and owner='LABAPP')||'|'||
       (select count(*) from v$datafile d join v$containers c on c.con_id=d.con_id where c.name='FREEPDB1' and d.name like '%labrecovery01.dbf')
from dual;
SQL
)"
SEED_CHECK="$(tr -d '[:space:]' <<<"$SEED_CHECK")"
[[ "$SEED_CHECK" =~ ^READWRITE\|[0-9]+\|1$ ]] || die "PDB placement/size/readiness check failed"
SEED_MB="$(cut -d'|' -f2 <<<"$SEED_CHECK")"
(( SEED_MB < 2048 )) || die "Seeded LABAPP segments exceed 2 GiB"
[[ $(stat -c '%U:%G:%a' /opt/lab/inject-ex1.sh) == root:root:750 ]]
[[ $(stat -c '%U:%G:%a' /opt/lab/inject-ex2.sh) == root:root:750 ]]
sshd -T | grep -qi '^passwordauthentication yes$'

# No service operation occurred before the SSM RPM installation above.
systemctl enable amazon-ssm-agent
systemctl restart amazon-ssm-agent
systemctl is-active --quiet amazon-ssm-agent

cat >"$READY" <<EOF
READY_UTC=$(stamp)
BACKUP_UUID=$BACKUP_UUID
ORACLE_SID=FREE
PDB=FREEPDB1
EOF
chown root:root "$READY"
chmod 0644 "$READY"
[[ -f "$READY" ]]

"$CFN_SIGNAL" --success true --stack "$CFN_STACK" --resource "$CFN_RESOURCE" --region "$AWS_REGION"
SIGNALLED=1
trap - EXIT
log "CloudLabs Stage 1 bootstrap complete"
exit 0
