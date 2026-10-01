using namespace System.Net

<#
Oracle Backup, Recovery & Diagnostics
Validation 3
Checks:
  1. Exactly one running EC2 instance is tagged CloudLabsDeploymentID=<deployment id> and Name=labvm.
  2. The instance is online in AWS Systems Manager.
  3. Exactly one running Docker container named oracle-free is dynamically resolved.
  4. LABAPP.ORDERS statistics are newer than the seed and latest exercise injection.
  5. /opt/lab/evidence/ex3/baseline-plan.txt and after-plan.txt prove a changed, correct, improved plan.
  6. /usr/local/sbin/rman-verify.sh is executable and contains CROSSCHECK and RESTORE DATABASE VALIDATE.
  7. rman-verify.timer is enabled or cron schedules /usr/local/sbin/rman-verify.sh.
  8. A recent log under /u02/backup/logs contains the exact phrase verification succeeded.
Read-only: this validator never changes the environment.
#>

$ErrorActionPreference = 'Stop'
$did = "$deploymentid".Trim()
$DID = $did
$null = "$sub"
Write-Host "Deployment ID: $did"

$region = "$region".Trim()
if ([string]::IsNullOrWhiteSpace($region)) { $region = "$($env:AWS_REGION)".Trim() }
if ([string]::IsNullOrWhiteSpace($region)) { $region = "$($env:AWS_DEFAULT_REGION)".Trim() }
if ([string]::IsNullOrWhiteSpace($region) -and -not [string]::IsNullOrWhiteSpace($did)) {
    $likelyRegions = @('us-east-1','us-east-2','us-west-2','us-west-1','eu-west-1','eu-central-1','ap-south-1','ap-southeast-1','ap-southeast-2')
    foreach ($candidateRegion in $likelyRegions) {
        try {
            $regionFilters = @(
                @{ Name = 'tag:CloudLabsDeploymentID'; Values = @($did) },
                @{ Name = 'tag:Name'; Values = @('labvm') },
                @{ Name = 'instance-state-name'; Values = @('running') }
            )
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
$script:fails = New-Object System.Collections.Generic.List[string]

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
            -Comment 'CloudLabs read-only Oracle Validation 3' `
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

mapfile -t ids < <(docker ps --filter name=oracle-free --filter status=running -q 2>/dev/null)
cid=''
if [ ${#ids[@]} -eq 1 ] && [ "$(docker inspect --format '{{.Name}}' "${ids[0]}" 2>/dev/null)" = /oracle-free ]; then
    cid=${ids[0]}
    pass 'Exactly one running oracle-free container was dynamically resolved.'
else
    fail 'Start exactly one intended Docker container named oracle-free.'
fi

reference_epoch=0
for state_file in /opt/lab/.ready /opt/lab/state/ex1.env /opt/lab/state/ex2.env; do
    [ -r "$state_file" ] || continue
    timestamp=$(sed -nE 's/^(READY_UTC|UTC)=//p' "$state_file" | tail -n 1)
    epoch=$(date -u -d "$timestamp" +%s 2>/dev/null || printf '0')
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > reference_epoch )); then reference_epoch=$epoch; fi
done
stats_ok=false
if [ -n "$cid" ] && (( reference_epoch > 0 )); then
    stats_value=$(docker exec -i "$cid" bash -lc 'sqlplus -s / as sysdba' 2>/dev/null <<'SQL'
whenever sqlerror exit failure
set pages 0 feedback off heading off echo off verify off trimspool on
select round((s.last_analyzed-date '1970-01-01')*86400)
from cdb_tab_statistics s join v$containers c on c.con_id=s.con_id
where c.name='FREEPDB1' and s.owner='LABAPP' and s.table_name='ORDERS' and s.partition_name is null;
exit
SQL
)
    stats_rc=$?
    stats_epoch=$(printf '%s\n' "$stats_value" | sed '/^[[:space:]]*$/d' | tail -n 1 | tr -d '[:space:]')
    if [ $stats_rc -eq 0 ] && [[ "$stats_epoch" =~ ^[0-9]+$ ]] && (( stats_epoch > reference_epoch )); then stats_ok=true; fi
fi
if $stats_ok; then
    pass 'LABAPP.ORDERS statistics are newer than the seed and latest exercise injection.'
else
    fail 'Gather targeted LABAPP.ORDERS optimizer statistics in FREEPDB1 after the seed and latest exercise injection.'
fi

baseline=/opt/lab/evidence/ex3/baseline-plan.txt
after=/opt/lab/evidence/ex3/after-plan.txt
plans_ok=true
[ -s "$baseline" ] && [ -s "$after" ] || plans_ok=false
if $plans_ok; then
    grep -Eiq '(^|[[:space:]])container[=:][[:space:]]*FREEPDB1' "$baseline" || plans_ok=false
    grep -Eiq '(^|[[:space:]])container[=:][[:space:]]*FREEPDB1' "$after" || plans_ok=false
    grep -Eiq '(^|[[:space:]])object[=:][[:space:]]*LABAPP\.ORDERS' "$baseline" || plans_ok=false
    grep -Eiq '(^|[[:space:]])object[=:][[:space:]]*LABAPP\.ORDERS' "$after" || plans_ok=false
    grep -Eiq 'E-Rows|A-Rows|Starts' "$baseline" || plans_ok=false
    grep -Eiq 'E-Rows|A-Rows|Starts' "$after" || plans_ok=false
    grep -Eiq 'TABLE ACCESS|INDEX .*SCAN|HASH JOIN|NESTED LOOPS' "$baseline" || plans_ok=false
    grep -Eiq 'TABLE ACCESS|INDEX .*SCAN|HASH JOIN|NESTED LOOPS' "$after" || plans_ok=false

    baseline_hash=$(sed -nE 's/.*(PLAN_HASH_VALUE|Plan hash value)[=: ]+([0-9]+).*/\2/p' "$baseline" | tail -n 1)
    after_hash=$(sed -nE 's/.*(PLAN_HASH_VALUE|Plan hash value)[=: ]+([0-9]+).*/\2/p' "$after" | tail -n 1)
    baseline_sum=$(sed -nE 's/.*(checksum|sha256)[=: ]+([^[:space:]]+).*/\2/ip' "$baseline" | tail -n 1)
    after_sum=$(sed -nE 's/.*(checksum|sha256)[=: ]+([^[:space:]]+).*/\2/ip' "$after" | tail -n 1)
    [[ "$baseline_hash" =~ ^[0-9]+$ && "$after_hash" =~ ^[0-9]+$ && "$baseline_hash" != "$after_hash" ]] || plans_ok=false
    [ -n "$baseline_sum" ] && [ "$baseline_sum" = "$after_sum" ] || plans_ok=false

    baseline_buffers=$(sed -nE 's/.*buffer_gets[=: ]+([0-9]+).*/\1/ip' "$baseline" | tail -n 1)
    after_buffers=$(sed -nE 's/.*buffer_gets[=: ]+([0-9]+).*/\1/ip' "$after" | tail -n 1)
    baseline_ms=$(sed -nE 's/.*elapsed_ms[=: ]+([0-9]+([.][0-9]+)?).*/\1/ip' "$baseline" | tail -n 1)
    after_ms=$(sed -nE 's/.*elapsed_ms[=: ]+([0-9]+([.][0-9]+)?).*/\1/ip' "$after" | tail -n 1)
    improved=false
    if [[ "$baseline_buffers" =~ ^[0-9]+$ && "$after_buffers" =~ ^[0-9]+$ ]] && (( baseline_buffers > 0 && after_buffers * 100 <= baseline_buffers * 80 )); then improved=true; fi
    if [[ "$baseline_ms" =~ ^[0-9]+([.][0-9]+)?$ && "$after_ms" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v b="$baseline_ms" -v a="$after_ms" 'BEGIN { exit !(b > 0 && a <= b * 0.8) }'; then improved=true; fi
    $improved || plans_ok=false
fi
if $plans_ok; then
    pass 'Baseline and after-plan evidence preserves results and proves an improved changed plan.'
else
    fail 'Retain /opt/lab/evidence/ex3/baseline-plan.txt and after-plan.txt with FREEPDB1 executed plans, different plan hashes, equal checksums, and at least 20 percent improvement.'
fi

verifier=/usr/local/sbin/rman-verify.sh
verifier_ok=false
if [ -x "$verifier" ] && grep -Eiq 'CROSSCHECK[[:space:]]+BACKUP' "$verifier" && grep -Eiq 'RESTORE[[:space:]]+DATABASE[[:space:]]+VALIDATE' "$verifier"; then
    verifier_ok=true
fi
if $verifier_ok; then
    pass '/usr/local/sbin/rman-verify.sh is executable and contains CROSSCHECK and RESTORE DATABASE VALIDATE.'
else
    fail 'Make /usr/local/sbin/rman-verify.sh executable and include literal CROSSCHECK BACKUP and RESTORE DATABASE VALIDATE operations.'
fi

schedule_ok=false
if systemctl is-enabled rman-verify.timer >/dev/null 2>&1; then schedule_ok=true; fi
if grep -RhsEv '^[[:space:]]*(#|$)' /etc/cron.d /var/spool/cron 2>/dev/null | grep -Fq '/usr/local/sbin/rman-verify.sh'; then schedule_ok=true; fi
if $schedule_ok; then
    pass 'rman-verify.timer is enabled or cron schedules /usr/local/sbin/rman-verify.sh.'
else
    fail 'Enable rman-verify.timer or install a recurring cron entry for /usr/local/sbin/rman-verify.sh.'
fi

successful_log=''
while IFS= read -r candidate; do
    if grep -Fq 'verification succeeded' "$candidate"; then successful_log=$candidate; break; fi
done < <(find /u02/backup/logs -xdev -type f -mmin -2880 -size +0c -size -10M -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
if [ -n "$successful_log" ]; then
    pass 'A recent log under /u02/backup/logs contains the exact phrase verification succeeded.'
else
    fail 'Run the verifier successfully and retain a log from the last 48 hours under /u02/backup/logs containing the exact phrase verification succeeded.'
fi
'@

    $inspection = Invoke-SSMShell -InstanceId $instanceId -Script $payload
    if ($inspection.Status -ne 'Success') { throw "The read-only Systems Manager inspection failed with status $($inspection.Status): $($inspection.Output)" }
    $lines = @($inspection.Output -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL)\|' })
    if ($lines.Count -ne 6) { throw "Expected 6 guest check results but received $($lines.Count)." }
    foreach ($line in $lines) {
        $parts = $line -split '\|', 2
        Add-Check ($parts[0] -eq 'PASS') $parts[1]
    }
} catch {
    $script:fails.Add("Validation could not complete: $($_.Exception.Message)")
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
