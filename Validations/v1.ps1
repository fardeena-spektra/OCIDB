using namespace System.Net

<#
Lab: Oracle Backup, Recovery & Diagnostics
Title: Validation 1 - Storage, backup chain, and whole-CDB PITR
Checks:
  1. Exactly one running EC2 instance is tagged CloudLabsDeploymentID=<deployment id> and Name=labvm.
  2. The instance is online in AWS Systems Manager.
  3. Exactly one attached backup volume is encrypted, gp3, and 30 GiB.
  4. /u02/backup is mounted.
  5. RMAN level 0 backup tag CL_EX1_L0 exists in the baseline incarnation.
  6. RMAN level 1 backup tag CL_EX1_L1 exists in the baseline incarnation.
  7. Archived-log backup tags CL_EX1_L0_ARC and CL_EX1_L1_ARC exist in the baseline incarnation.
  8. Control-file backup tag CL_EX1_L0_CTL exists in the baseline incarnation.
  9. SPFILE backup tag CL_EX1_L0_SPFILE exists in the baseline incarnation.
 10. The current RESETLOGS SCN is newer than BASE_RESETLOGS_SCN in ex1.env.
 11. Post-RESETLOGS level 0 backup tag CL_EX1_POST_RESETLOGS_L0 exists in the current incarnation.
 12. The injected bad marker is absent from FREEPDB1.LABAPP.ORDERS.
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
    $regionFilters = @(
        @{ Name = 'tag:CloudLabsDeploymentID'; Values = @($did) },
        @{ Name = 'tag:Name'; Values = @('labvm') },
        @{ Name = 'instance-state-name'; Values = @('running') }
    )
    try {
        $candidateRegions = @(Get-AWSRegion | ForEach-Object { $_.Region } | Where-Object { $_ } | Sort-Object -Unique)
    } catch {
        $candidateRegions = @()
    }
    foreach ($candidateRegion in $candidateRegions) {
        try {
            $regionMatches = @(Get-EC2Instance -Region $candidateRegion -Filter $regionFilters |
                ForEach-Object { $_.Instances } | Where-Object { $null -ne $_ })
            if ($regionMatches.Count -eq 1) {
                $region = $candidateRegion
                break
            }
        } catch { }
    }
}
if ([string]::IsNullOrWhiteSpace($region)) { $region = 'us-east-1' }
Set-DefaultAWSRegion -Region $region
Write-Host "Region: $region"

$status = 'Failed'
$message = $null
$script:passes = 0
$script:fails  = New-Object System.Collections.Generic.List[string]

function Add-Check([bool]$ok, [string]$failText) {
    if ($ok) {
        $script:passes++
    } else {
        $script:fails.Add($failText)
    }
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
            -Comment 'CloudLabs read-only Oracle Validation 1' `
            -Parameter @{ commands = @($command); executionTimeout = @('150') } -TimeoutSecond 150
        if ([string]::IsNullOrWhiteSpace("$($sent.CommandId)")) {
            return [pscustomobject]@{ Status = 'Failed'; Output = 'Systems Manager did not return a command ID.' }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(150)
        $terminal = @('Success', 'Cancelled', 'TimedOut', 'Failed', 'Cancelling')
        $invocation = $null
        do {
            try {
                $invocation = Get-SSMCommandInvocationDetail -CommandId $sent.CommandId -InstanceId $InstanceId
            } catch {
                $invocation = $null
            }
            if ($null -eq $invocation -or $terminal -notcontains "$($invocation.Status)") {
                Start-Sleep -Seconds 5
            }
        } while (($null -eq $invocation -or $terminal -notcontains "$($invocation.Status)") -and [DateTime]::UtcNow -lt $deadline)
        if ($null -eq $invocation -or $terminal -notcontains "$($invocation.Status)") {
            return [pscustomobject]@{ Status = 'TimedOut'; Output = 'The Systems Manager command did not finish within 150 seconds.' }
        }
        $output = [string]$invocation.StandardOutputContent
        if ("$($invocation.Status)" -ne 'Success' -or [int]$invocation.ResponseCode -ne 0) {
            return [pscustomobject]@{
                Status = "$($invocation.Status)"
                Output = "$output`n$($invocation.StandardErrorContent)".Trim()
            }
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
    $count = 0
    $found = $false
    $instances = @()
    do {
        $count++
        try {
            $instances = @(Get-EC2Instance -Filter $instanceFilters |
                ForEach-Object { $_.Instances } | Where-Object { $null -ne $_ })
            $found = ($instances.Count -eq 1)
        } catch {
            $instances = @()
            $found = $false
        }
        if (-not $found -and $count -lt 3) { Start-Sleep -Seconds 10 }
    } while ($count -lt 3 -and -not $found)
    Add-Check ($instances.Count -eq 1) "Ensure exactly one running EC2 instance is tagged CloudLabsDeploymentID=$did and Name=labvm."
    if (-not $found) { throw 'Instance discovery did not return exactly one running labvm.' }
    $instanceId = [string]$instances[0].InstanceId

    $count = 0
    $found = $false
    do {
        $count++
        try { $found = Test-SSMOnline -InstanceId $instanceId } catch { $found = $false }
        if (-not $found -and $count -lt 3) { Start-Sleep -Seconds 10 }
    } while ($count -lt 3 -and -not $found)
    Add-Check $found "Start or reconnect SSM Agent on '$instanceId' until PingStatus is Online."
    if (-not $found) { throw "Instance '$instanceId' is not Online in Systems Manager." }

    $volumeFilter = New-Object Amazon.EC2.Model.Filter
    $volumeFilter.Name = 'attachment.instance-id'
    $volumeFilter.Values = [string[]]@($instanceId)
    $attachedVolumes = @(Get-EC2Volume -Filter @($volumeFilter))
    $backupVolumes = @($attachedVolumes | Where-Object {
        [string]$_.VolumeType -eq 'gp3' -and [int]$_.Size -eq 30 -and [bool]$_.Encrypted -and
        @($_.Attachments | Where-Object {
            $_.InstanceId -eq $instanceId -and [string]$_.State -eq 'attached'
        }).Count -eq 1
    })
    Add-Check ($backupVolumes.Count -eq 1) "Attach exactly one encrypted 30 GiB gp3 backup volume to '$instanceId'."

    $payload = @'
#!/bin/bash
set -uo pipefail
pass(){ printf 'PASS|%s\n' "$1"; }
fail(){ printf 'FAIL|%s\n' "$1"; }
if mountpoint -q /u02/backup && [[ "$(findmnt -rn -T /u02/backup -o TARGET 2>/dev/null)" == /u02/backup ]]; then pass 'mount'; else fail 'Mount the separate backup EBS filesystem at /u02/backup.'; fi
mapfile -t ids < <(docker ps --filter name=oracle-free --filter status=running -q 2>/dev/null)
cid=''
if [[ ${#ids[@]} -eq 1 ]] && [[ "$(docker inspect --format '{{.Name}}' "${ids[0]}" 2>/dev/null)" == /oracle-free ]]; then cid=${ids[0]}; fi
if [[ -z "$cid" ]]; then
 fail 'Start exactly one running Docker container named oracle-free, then create RMAN backup tag CL_EX1_L0.'
 fail 'Start exactly one running Docker container named oracle-free, then create RMAN backup tag CL_EX1_L1.'
 fail 'Start oracle-free and create archived-log backups tagged CL_EX1_L0_ARC and CL_EX1_L1_ARC.'
 fail 'Start oracle-free and create a control-file backup tagged CL_EX1_L0_CTL.'
 fail 'Start oracle-free and create an SPFILE backup tagged CL_EX1_L0_SPFILE.'
 fail 'Start oracle-free and open the recovered CDB with RESETLOGS after recovery to the target SCN.'
 fail 'Start oracle-free and create level 0 backup tag CL_EX1_POST_RESETLOGS_L0 in the current incarnation.'
 fail 'Start oracle-free and recover the whole CDB to the injected target SCN so the bad marker is absent.'
 exit 0
fi
state=/opt/lab/state/ex1.env
base=$(sed -n 's/^BASE_RESETLOGS_SCN=//p' "$state" 2>/dev/null | tail -n 1)
marker=$(sed -n 's/^MARKER=//p' "$state" 2>/dev/null | tail -n 1)
report=''
if [[ "$base" =~ ^[0-9]+$ && "$marker" =~ ^BAD-[0-9]+$ ]]; then
 report=$(docker exec -i "$cid" bash -lc 'sqlplus -s / as sysdba' 2>/dev/null <<SQL
whenever sqlerror exit failure
set pages 0 feedback off heading off verify off echo off lines 32767 trimspool on
select 'L0|'||count(*) from v\$backup_set where tag='CL_EX1_L0' and incremental_level=0 and backup_type in ('D','I') and resetlogs_change#=$base and upper(nvl(tag,'-')) not like 'CLOUDLABS_EX2_SAFETY_%';
select 'L1|'||count(*) from v\$backup_set where tag='CL_EX1_L1' and incremental_level=1 and backup_type in ('D','I') and resetlogs_change#=$base and upper(nvl(tag,'-')) not like 'CLOUDLABS_EX2_SAFETY_%';
select 'ARC|'||count(distinct tag) from v\$backup_set where tag in ('CL_EX1_L0_ARC','CL_EX1_L1_ARC') and backup_type='L' and resetlogs_change#=$base and upper(nvl(tag,'-')) not like 'CLOUDLABS_EX2_SAFETY_%';
select 'CTL|'||count(*) from v\$backup_set where tag='CL_EX1_L0_CTL' and controlfile_included='YES' and resetlogs_change#=$base and upper(nvl(tag,'-')) not like 'CLOUDLABS_EX2_SAFETY_%';
select 'SPF|'||count(*) from v\$backup_spfile s join v\$backup_set b on b.set_stamp=s.set_stamp and b.set_count=s.set_count where b.tag='CL_EX1_L0_SPFILE' and b.resetlogs_change#=$base and upper(nvl(b.tag,'-')) not like 'CLOUDLABS_EX2_SAFETY_%';
select 'RESET|'||case when resetlogs_change#>$base then 1 else 0 end from v\$database;
select 'POST|'||count(*) from v\$backup_set b cross join v\$database d where b.tag='CL_EX1_POST_RESETLOGS_L0' and b.incremental_level=0 and b.backup_type in ('D','I') and b.resetlogs_change#=d.resetlogs_change# and upper(nvl(b.tag,'-')) not like 'CLOUDLABS_EX2_SAFETY_%';
alter session set container=FREEPDB1;
select 'BAD|'||count(*) from LABAPP.ORDERS where marker='$marker';
exit
SQL
) || report=''
fi
metric(){ printf '%s\n' "$report" | sed -n "s/^[[:space:]]*$1|//p" | tr -d '[:space:]' | tail -n 1; }
l0=$(metric L0); l1=$(metric L1); arc=$(metric ARC); ctl=$(metric CTL); spf=$(metric SPF); reset=$(metric RESET); post=$(metric POST); bad=$(metric BAD)
[[ "${l0:-0}" -gt 0 ]] && pass 'level zero' || fail 'Create an RMAN level 0 backup tagged CL_EX1_L0; CLOUDLABS_EX2_SAFETY_* backups do not count.'
[[ "${l1:-0}" -gt 0 ]] && pass 'level one' || fail 'Create an RMAN level 1 backup tagged CL_EX1_L1; CLOUDLABS_EX2_SAFETY_* backups do not count.'
[[ "${arc:-0}" -eq 2 ]] && pass 'archived logs' || fail 'Create archived-log backups tagged CL_EX1_L0_ARC and CL_EX1_L1_ARC; CLOUDLABS_EX2_SAFETY_* backups do not count.'
[[ "${ctl:-0}" -gt 0 ]] && pass 'control file' || fail 'Create a control-file backup tagged CL_EX1_L0_CTL; CLOUDLABS_EX2_SAFETY_* backups do not count.'
[[ "${spf:-0}" -gt 0 ]] && pass 'spfile' || fail 'Create an SPFILE backup tagged CL_EX1_L0_SPFILE; CLOUDLABS_EX2_SAFETY_* backups do not count.'
[[ "$reset" == 1 ]] && pass 'resetlogs' || fail 'Recover the whole CDB to TARGET_SCN and open it with RESETLOGS so the current RESETLOGS SCN is newer than BASE_RESETLOGS_SCN.'
[[ "${post:-0}" -gt 0 ]] && pass 'post resetlogs level zero' || fail 'Create an RMAN level 0 backup tagged CL_EX1_POST_RESETLOGS_L0 in the current incarnation; CLOUDLABS_EX2_SAFETY_* backups do not count.'
[[ "$bad" == 0 ]] && pass 'bad marker absent' || fail 'Recover the whole CDB to TARGET_SCN so the injected marker is absent from FREEPDB1.LABAPP.ORDERS.'
'@

    $inspection = Invoke-SSMShell -InstanceId $instanceId -Script $payload
    if ($inspection.Status -ne 'Success') {
        throw "The read-only Systems Manager inspection failed with status $($inspection.Status): $($inspection.Output)"
    }
    $lines = @($inspection.Output -split "`r?`n" | Where-Object { $_ -match '^(PASS|FAIL)\|' })
    if ($lines.Count -ne 9) { throw "Expected 9 guest check results but received $($lines.Count)." }
    foreach ($line in $lines) {
        $parts = $line -split '\|', 2
        Add-Check ($parts[0] -eq 'PASS') $parts[1]
    }
} catch {
    $status = 'Failed'
    $message = "The validation could not complete: $($_.Exception.Message). Try again shortly, and contact your instructor if it persists."
}

if ([string]::IsNullOrWhiteSpace($message)) {
    $total = $script:passes + $script:fails.Count
    if ($script:fails.Count -eq 0 -and $script:passes -gt 0) {
        $status = 'Succeeded'
        $message = "All $total checks passed."
    } else {
        $status = 'Failed'
        if ($script:fails.Count -eq 1) {
            $fixes = $script:fails[0]
        } elseif ($script:fails.Count -gt 1) {
            $numbered = for ($i = 0; $i -lt $script:fails.Count; $i++) { "$($i + 1)) $($script:fails[$i])" }
            $fixes = $numbered -join "`n"
        } else {
            $fixes = 'Run the validation again after the lab environment is ready.'
        }
        $message = "$($script:passes) of $total checks passed. To fix:`n$fixes"
    }
}

Write-Host $message
$body = @{ Status = $status; Message = $message } | ConvertTo-Json -Compress
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [System.Net.HttpStatusCode]::OK; Body = $body })
