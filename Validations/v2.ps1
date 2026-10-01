using namespace System.Net

<#
Oracle Backup, Recovery & Diagnostics
Validation 2
Checks:
  1. Exactly one running EC2 instance is tagged CloudLabsDeploymentID=<deployment id> and Name=labvm.
  2. The instance is online in AWS Systems Manager.
  3. The Exercise 2 injector state contains valid FILE_NO, CONTAINER_FILE, HOST_FILE, PRELOSS_CHECKSUM, RESETLOGS_SCN, BACKUP_PROVENANCE, and UTC values.
  4. The recorded FREEPDB1 datafile is ONLINE and AVAILABLE.
  5. V$RECOVER_FILE contains zero rows.
  6. The LABRECOVERY tablespace is ONLINE.
  7. The recovered LABAPP.ORDERS checksum matches PRELOSS_CHECKSUM.
  8. The database RESETLOGS SCN is unchanged from the injector state.
  9. /u02/backup/logs/ex2-rman-recovery.log proves targeted RESTORE DATAFILE and RECOVER DATAFILE operations for the recorded datafile.
Read-only: this validator never changes the environment.
#>

$ErrorActionPreference='Stop'
$did = "$deploymentid".Trim()
$DID = $did
$null = "$sub"
Write-Host "Deployment ID: $did"

$region = "$region".Trim()
if ([string]::IsNullOrWhiteSpace($region)) { $region = "$($env:AWS_REGION)".Trim() }
if ([string]::IsNullOrWhiteSpace($region)) { $region = "$($env:AWS_DEFAULT_REGION)".Trim() }
if ([string]::IsNullOrWhiteSpace($region) -and -not [string]::IsNullOrWhiteSpace($did)) {
    $regionFilters = @(
        @{ Name = 'tag:CloudLabsDeploymentID'; Values = @($did) },
        @{ Name = 'tag:Name'; Values = @('labvm') },
        @{ Name = 'instance-state-name'; Values = @('running') }
    )
    foreach ($candidateRegion in @(Get-AWSRegion | ForEach-Object { $_.Region } | Where-Object { $_ } | Sort-Object -Unique)) {
        try {
            $regionMatches = @(Get-EC2Instance -Region $candidateRegion -Filter $regionFilters | ForEach-Object { $_.Instances } | Where-Object { $null -ne $_ })
            if ($regionMatches.Count -gt 0) { $region = $candidateRegion; break }
        } catch { }
    }
}
if ([string]::IsNullOrWhiteSpace($region)) { $region = 'us-east-1' }
Set-DefaultAWSRegion -Region $region
Write-Host "Region: $region"

$status = 'Failed'
$script:passes = 0
$script:fails = [System.Collections.Generic.List[string]]::new()

function Add-Check([bool]$ok, [string]$failText) {
    if ($ok) { $script:passes++ } else { $script:fails.Add($failText) }
}

function Test-SSMOnline {
    param([string]$InstanceId)
    $filter = New-Object Amazon.SimpleSystemsManagement.Model.InstanceInformationStringFilter
    $filter.Key = 'InstanceIds'
    $filter.Values = [string[]]@($InstanceId)
    return (@(Get-SSMInstanceInformation -Filter @($filter) | Where-Object {
        $_.InstanceId -eq $InstanceId -and $_.PingStatus -eq 'Online'
    }).Count -eq 1)
}

function Invoke-SSMShell {
    param([string]$InstanceId, [string]$Script)
    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
        $command = "echo '$encoded' | base64 -d | bash"
        $sent = Send-SSMCommand -InstanceId @($InstanceId) -DocumentName 'AWS-RunShellScript' `
            -Comment 'CloudLabs read-only Oracle Validation 2' `
            -Parameter @{ commands = @($command); executionTimeout = @('150') } -TimeoutSecond 150
        if ([string]::IsNullOrWhiteSpace("$($sent.CommandId)")) {
            return [pscustomobject]@{ Status = 'Failed'; Output = 'Systems Manager did not return a command ID.' }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(150)
        $terminal = @('Success','Cancelled','TimedOut','Failed','Cancelling')
        $invocation = $null
        do {
            try { $invocation = Get-SSMCommandInvocationDetail -CommandId $sent.CommandId -InstanceId $InstanceId } catch { $invocation = $null }
            if ($null -eq $invocation -or $terminal -notcontains "$($invocation.Status)") { Start-Sleep -Seconds 5 }
        } while (($null -eq $invocation -or $terminal -notcontains "$($invocation.Status)") -and [DateTime]::UtcNow -lt $deadline)
        if ($null -eq $invocation -or $terminal -notcontains "$($invocation.Status)") {
            return [pscustomobject]@{ Status = 'TimedOut'; Output = 'The Systems Manager command did not finish within 150 seconds.' }
        }
        $output = [string]$invocation.StandardOutputContent
        if ("$($invocation.Status)" -ne 'Success' -or [int]$invocation.ResponseCode -ne 0) {
            return [pscustomobject]@{ Status = "$($invocation.Status)"; Output = "$output`n$($invocation.StandardErrorContent)".Trim() }
        }
        return [pscustomobject]@{ Status = 'Success'; Output = $output }
    } catch {
        return [pscustomobject]@{ Status = 'Failed'; Output = $_.Exception.Message }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($did)) { throw 'The deployment ID was not supplied to the validator.' }
    $instanceFilters = @(
        @{ Name = 'tag:CloudLabsDeploymentID'; Values = @($did) },
        @{ Name = 'tag:Name'; Values = @('labvm') },
        @{ Name = 'instance-state-name'; Values = @('running') }
    )
    $count = 0; $found = $false; $instances = @()
    do {
        $count++
        try {
            $instances = @(Get-EC2Instance -Filter $instanceFilters | ForEach-Object { $_.Instances } | Where-Object { $null -ne $_ })
            $found = ($instances.Count -eq 1)
        } catch { $instances = @(); $found = $false }
        if (-not $found -and $count -lt 3) { Start-Sleep -Seconds 10 }
    } while ($count -lt 3 -and -not $found)
    Add-Check ($instances.Count -eq 1) "Ensure exactly one running EC2 instance is tagged CloudLabsDeploymentID=$did and Name=labvm."
    if (-not $found) { throw 'Instance discovery did not return exactly one running labvm.' }
    $instanceId = [string]$instances[0].InstanceId

    $count = 0; $found = $false
    do {
        $count++
        try { $found = Test-SSMOnline -InstanceId $instanceId } catch { $found = $false }
        if (-not $found -and $count -lt 3) { Start-Sleep -Seconds 10 }
    } while ($count -lt 3 -and -not $found)
    Add-Check $found "Start or reconnect SSM Agent on '$instanceId' until PingStatus is Online."
    if (-not $found) { throw "Instance '$instanceId' is not Online in Systems Manager." }

    $payload = @'
#!/bin/bash
set -uo pipefail
pass(){ printf 'PASS|%s\n' "$1"; }
fail(){ printf 'FAIL|%s\n' "$1"; }

state=/opt/lab/state/ex2.env
transcript=/u02/backup/logs/ex2-rman-recovery.log
field(){ sed -n "s/^$1=//p" "$state" 2>/dev/null | tail -n 1; }

mapfile -t ids < <(docker ps --filter name=oracle-free --filter status=running -q 2>/dev/null)
cid=''
if [[ ${#ids[@]} -eq 1 ]] && [[ "$(docker inspect --format '{{.Name}}' "${ids[0]}" 2>/dev/null)" == /oracle-free ]]; then
    cid=${ids[0]}
fi

FILE_NO=$(field FILE_NO)
CONTAINER_FILE=$(field CONTAINER_FILE)
HOST_FILE=$(field HOST_FILE)
PRELOSS_CHECKSUM=$(field PRELOSS_CHECKSUM)
RESETLOGS_SCN=$(field RESETLOGS_SCN)
BACKUP_PROVENANCE=$(field BACKUP_PROVENANCE)
UTC=$(field UTC)

state_ok=true
[[ -r "$state" ]] || state_ok=false
[[ -n "$cid" ]] || state_ok=false
[[ "$FILE_NO" =~ ^[0-9]+$ ]] || state_ok=false
[[ "$CONTAINER_FILE" == /opt/oracle/oradata/* && "$CONTAINER_FILE" != *"'"* && "$CONTAINER_FILE" != *'/../'* ]] || state_ok=false
[[ "$HOST_FILE" == /u01/oradata/* && "$HOST_FILE" != *'/../'* ]] || state_ok=false
[[ "$PRELOSS_CHECKSUM" =~ ^[0-9]+:[0-9]+$ ]] || state_ok=false
[[ "$RESETLOGS_SCN" =~ ^[0-9]+$ ]] || state_ok=false
[[ "$BACKUP_PROVENANCE" == LEARNER_CREATED || "$BACKUP_PROVENANCE" == INJECTOR_CREATED ]] || state_ok=false
[[ "$UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || state_ok=false
if $state_ok; then
    pass 'Exercise 2 state and the dynamically resolved oracle-free container are valid.'
else
    fail 'Run sudo /opt/lab/inject-ex2.sh in a fresh lab and ensure exactly one container named oracle-free is running.'
fi

sql_out=''
sql_rc=1
if $state_ok; then
    sql_out=$(docker exec -i "$cid" bash -lc 'sqlplus -s / as sysdba' 2>/dev/null <<SQL
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off trimspool on lines 4000
select 'RESETLOGS='||resetlogs_change# from v\$database;
select 'ROOT_STATUS='||count(*)
from v\$datafile d join v\$containers c on c.con_id=d.con_id
where c.name='FREEPDB1' and d.file#=$FILE_NO and d.name='$CONTAINER_FILE' and d.status='ONLINE';
select 'RECOVER_ROWS='||count(*) from v\$recover_file;
alter session set container=FREEPDB1;
select 'PDB_STATUS='||count(*) from dba_data_files
where file_id=$FILE_NO and file_name='$CONTAINER_FILE' and tablespace_name='LABRECOVERY' and status='AVAILABLE';
select 'TS_ONLINE='||count(*) from dba_tablespaces where tablespace_name='LABRECOVERY' and status='ONLINE';
select 'CHECKSUM='||count(*)||':'||nvl(sum(order_id),0) from LABAPP.ORDERS;
exit
SQL
    )
    sql_rc=$?
fi
value(){ printf '%s\n' "$sql_out" | sed -n "s/^[[:space:]]*$1=//p" | tail -n 1 | tr -d '[:space:]'; }

if [[ $sql_rc -eq 0 && "$(value ROOT_STATUS)" == 1 && "$(value PDB_STATUS)" == 1 && -f "$HOST_FILE" ]]; then
    pass 'The recorded FREEPDB1 datafile is ONLINE and AVAILABLE.'
else
    fail 'Restore and recover only the recorded FREEPDB1 datafile, then bring its datafile and tablespace online.'
fi

if [[ $sql_rc -eq 0 && "$(value RECOVER_ROWS)" == 0 ]]; then
    pass 'V$RECOVER_FILE contains zero rows.'
else
    fail 'Complete media recovery until V$RECOVER_FILE contains zero rows.'
fi

if [[ $sql_rc -eq 0 && "$(value TS_ONLINE)" == 1 ]]; then
    pass 'The LABRECOVERY tablespace is ONLINE.'
else
    fail 'Bring the LABRECOVERY tablespace online in FREEPDB1.'
fi

if [[ $sql_rc -eq 0 && "$(value CHECKSUM)" == "$PRELOSS_CHECKSUM" ]]; then
    pass 'The recovered checksum matches PRELOSS_CHECKSUM.'
else
    fail 'Recover the original LABAPP.ORDERS contents so the checksum matches PRELOSS_CHECKSUM.'
fi

if [[ $sql_rc -eq 0 && "$(value RESETLOGS)" == "$RESETLOGS_SCN" ]]; then
    pass 'The database RESETLOGS SCN is unchanged.'
else
    fail 'Repeat Exercise 2 as targeted datafile recovery without opening the CDB with RESETLOGS.'
fi

restore_ok=false
recover_ok=false
if $state_ok && [[ -s "$transcript" ]]; then
    base=$(basename "$CONTAINER_FILE")
    if grep -Eiq "restore[[:space:]]+datafile[[:space:]]+([^;]*([^0-9]|^)$FILE_NO([^0-9]|$)|[^;]*$base)" "$transcript"; then restore_ok=true; fi
    if grep -Eiq "recover[[:space:]]+datafile[[:space:]]+([^;]*([^0-9]|^)$FILE_NO([^0-9]|$)|[^;]*$base)" "$transcript"; then recover_ok=true; fi
fi
if $restore_ok && $recover_ok; then
    pass 'The RMAN transcript proves targeted RESTORE DATAFILE and RECOVER DATAFILE operations.'
else
    fail 'Use RMAN log=/u02/backup/logs/ex2-rman-recovery.log and issue targeted RESTORE DATAFILE and RECOVER DATAFILE commands for the recorded file.'
fi
'@
    $inspection = Invoke-SSMShell -InstanceId $instanceId -Script $payload
    if ($inspection.Status -ne 'Success') { throw "The read-only Systems Manager inspection failed with status $($inspection.Status): $($inspection.Output)" }
    $lines = @($inspection.Output -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL)\|' })
    if ($lines.Count -ne 7) { throw "Expected 7 guest check results but received $($lines.Count)." }
    foreach ($line in $lines) { $parts = $line -split '\|', 2; Add-Check ($parts[0] -eq 'PASS') $parts[1] }
} catch {
    $errorText = $_.Exception.Message.Trim().TrimEnd('.')
    $script:fails.Add("The validation could not complete: $errorText. Try again shortly, and contact your instructor if it persists.")
}

$total = $script:passes + $script:fails.Count
if ($script:fails.Count -eq 0) {
    $status = 'Succeeded'; $message = "All $total checks passed."
} else {
    $status = 'Failed'
    if ($script:fails.Count -eq 1) { $fixes = $script:fails[0] } else {
        $numbered = for ($i = 0; $i -lt $script:fails.Count; $i++) { "$($i + 1)) $($script:fails[$i])" }
        $fixes = $numbered -join "`n"
    }
    $message = "$($script:passes) of $total checks passed. To fix:`n$fixes"
}
Write-Host $message
$body = @{ Status = $status; Message = $message } | ConvertTo-Json -Compress
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $body })
