# Oracle Backup, Recovery & Diagnostics

This package provisions a disposable, task-based Oracle recovery and diagnostics assessment on AWS. Learners prove an RMAN backup chain, perform whole-CDB recovery to an injected SCN, recover a removed `FREEPDB1` training datafile, diagnose a seeded SQL regression, gather targeted optimizer statistics, and automate RMAN verification.

## Deployment summary

The single CloudFormation stage is intentionally limited to **`us-east-1`**. It creates:

- A VPC, public subnet, internet gateway, public route, route table, and security group.
- One x86-64 Oracle Linux 9 EC2 instance. `InstanceType` defaults to **`t3.large`** and allows `t3.medium`, `t3.large`, or `t3.xlarge`.
- An encrypted 50 GiB gp3 root volume.
- A separate encrypted 30 GiB gp3 EBS volume mounted by filesystem UUID at `/u02/backup`.
- An EC2 IAM role and instance profile with `AmazonSSMManagedInstanceCore`.
- Password SSH on TCP 22 from `AdminCidr`.
- IMDSv2 with tokens required and metadata hop limit 1.
- Oracle Database Free with CDB `FREE`, PDB `FREEPDB1`, ARCHIVELOG mode, deterministic RMAN settings, seeded workload, and diagnostic assets.

The EC2 resource has a 90-minute `CreationPolicy`. Bootstrap creates `/opt/lab/.ready` and calls `cfn-signal` only after Oracle, the listener, `FREEPDB1`, `/u02/backup`, SSH, injection-script permissions, and SSM Agent pass readiness checks.

## Oracle Linux 9 and Oracle prerequisites

Complete these checks before publication:

1. **Oracle Linux AMI:** `DeploymentPackage/deploy-01.json` currently maps `us-east-1` to Oracle owner `131827586825`, AMI `ami-0dd239e274077553a` (`OL9.3-x86_64-HVM-2024-02-02`). The template metadata marks current availability unresolved. Revalidate it with `ec2:DescribeImages` and deployment-test it. Do not silently substitute a third-party image.
2. **Oracle Database Free:** the Bash bootstrap is pinned to Oracle Database Free 23ai for EL9, RPM `oracle-database-free-23ai-1.0-1.el9.x86_64.rpm`, under `/opt/oracle/product/23ai/dbhomeFree`. Confirm that Oracle still publishes the preinstall package and database RPM and that both work on the selected OL9 image. Oracle package documentation may have advanced to a newer release; surface incompatibility rather than silently changing the OS or database version.
3. **Internet egress:** bootstrap needs Oracle repositories/downloads, Oracle Linux repositories, the Region-local SSM Agent S3 endpoint, and the AWS CloudFormation Python helper archive.
4. **Bootstrap URL:** `DeploymentPackage/deploy-01.parameters.json` currently points `BootstrapScriptUrl` at a `.ps1` URL, but the package bootstrap is `DeploymentPackage/Scripts/userdata-01.sh`. Publish the Bash file at an HTTPS URL and correct this parameter before launch.
5. **End-to-end test:** verify package installation, database creation, seed placement, backup-volume mounting, `cfn-signal`, SSM registration, and all validation paths in a disposable account.

The template has only a `us-east-1` AMI mapping, so use in another Region fails rather than choosing an unverified image.

## Password-output and SSH warning

`AdminCidr` defaults to `0.0.0.0/0`, and password SSH is enabled. This is an intentionally insecure disposable-lab default; narrow the CIDR before launch whenever possible.

`VMPassword` is declared `NoEcho`, but the template intentionally returns it in the `VMPassword` and `vmServerPassword` stack outputs. **CloudFormation outputs are not a secret store.** AWS documents that `NoEcho` does not redact values placed in `Outputs`. Anyone able to inspect stack outputs can obtain this password. Use the package only in an isolated, short-lived account, do not export the password output, and delete the stack after use.

Bootstrap must not use shell tracing or expose the password in logs, readiness markers, command history, or SSM output.

## SSM and IAM setup

The instance role trusts `ec2.amazonaws.com`, is attached with an instance profile, and uses the AWS managed `AmazonSSMManagedInstanceCore` policy. It has no S3 backup access because RMAN data remains on EBS.

Oracle Linux is not assumed to include SSM Agent. UserData downloads and installs the official x86-64 RPM from the Region-local AWS S3 endpoint before enabling or restarting `amazon-ssm-agent`. Outbound HTTPS and DNS are required for installation and Systems Manager registration.

The deployment/candidate IAM policy supplies CloudFormation and EC2 lifecycle operations, EC2 describe calls, role/profile plumbing, `iam:PassRole`, and Systems Manager command/session access. Validation 1 calls `aws ec2 describe-volumes` directly; guest and Oracle checks run through SSM Run Command.

The explicit-deny document restricts non-`us-east-1` requests, non-`t3` launches, unencrypted EBS creation, IAM privilege escalation, and protected-resource changes. Explicit deny overrides allow, so test the combined policies against stack creation and deletion, role passing, SSM registration, direct `ec2:DescribeVolumes`, and every validator.

Despite its existing path, `permissions/CustomIAMPolicy/aws-scp.json` is used by this package as an IAM explicit-deny policy document, not as an AWS Organizations SCP.

## AWS documentation references

Recheck current AWS guidance and live API behavior before release:

- CloudFormation `NoEcho` caveat: <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/parameters-section-structure.html>
- Creation policies: <https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-creationpolicy.html>
- `cfn-signal`: <https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/cfn-signal.html>
- SSM Agent on Oracle Linux: <https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-ol.html>
- `AmazonSSMManagedInstanceCore`: <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html>
- EC2 instance profiles: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html>
- IMDS options: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-options.html>
- EBS encryption: <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption.html>
- gp3 volumes: <https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html>
- IAM evaluation and deny precedence: <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html>

Static AMI identifiers and external package URLs can become stale; current documentation and live API results take precedence.

## Simulated AWR/ASH disclosure

Oracle Database Free in this lab does **not** generate licensed AWR or ASH reports. These assets are clearly labeled training simulations:

- `/opt/lab/diagnostics/seeded-awr-style-report.txt`
- `/opt/lab/diagnostics/seeded-ash-style-report.txt`

They must never be described as Oracle-generated AWR/ASH output. Learners use them only as diagnostic leads and corroborate them with live execution plans, runtime measurements, result checksums, `V$SQL`, `V$SQL_PLAN`, and available non-AWR dynamic performance views in `FREEPDB1`.

## Artifact inventory

### Deployment

- `DeploymentPackage/deploy-01.json` — CloudFormation JSON template.
- `DeploymentPackage/deploy-01.parameters.json` — CloudFormation parameter values.
- `DeploymentPackage/Scripts/userdata-01.sh` — Oracle Linux Bash bootstrap and seed logic.

### Lab guide

- `LabGuidePackage/Lab Guide/Lab Guide/GettingStarted-V2.md`
- `LabGuidePackage/Lab Guide/Lab Guide/Exercise-01.md`
- `LabGuidePackage/Lab Guide/Lab Guide/Exercise-02.md`
- `LabGuidePackage/Lab Guide/Lab Guide/Exercise-03.md`

### Questions

- `Inline-Questions/question-01.md`
- `Inline-Questions/question-02.md`
- `Inline-Questions/question-03.md`
- `Inline-Questions/question-04.md`
- `Inline-Questions/question-05.md`

### Validations

- `Validations/Backup Chain and Whole-CDB PITR.sh`
- `Validations/02-task-freepdb1-datafile-recovery.sh`
- `Validations/FREEPDB1 Plan and RMAN Schedule.sh`

The existing validators use Bash, AWS CLI, direct EC2 API calls, and SSM Run Command. Package lint warns that CloudLabs inline validation registration supports PowerShell V2 and Python rather than Bash. Convert them to a supported format before publication if they must run through the inline validation service.

### Solution, permissions, and package documents

- `solution-guide/solution.md`
- `permissions/CustomIAMPolicy/iam-custom-policy.json`
- `permissions/CustomIAMPolicy/aws-scp.json`
- `README.md`
- `Spec.md`

## Static validation commands

Run from the package root with AWS CLI v2, `jq`, and ShellCheck installed:

```bash
export AWS_REGION=us-east-1

aws cloudformation validate-template \
  --region "$AWS_REGION" \
  --template-body file://DeploymentPackage/deploy-01.json

jq empty \
  DeploymentPackage/deploy-01.json \
  DeploymentPackage/deploy-01.parameters.json \
  permissions/CustomIAMPolicy/iam-custom-policy.json \
  permissions/CustomIAMPolicy/aws-scp.json

bash -n DeploymentPackage/Scripts/userdata-01.sh
bash -n "Validations/Backup Chain and Whole-CDB PITR.sh"
bash -n Validations/02-task-freepdb1-datafile-recovery.sh
bash -n "Validations/FREEPDB1 Plan and RMAN Schedule.sh"

shellcheck DeploymentPackage/Scripts/userdata-01.sh
shellcheck "Validations/Backup Chain and Whole-CDB PITR.sh" \
  Validations/02-task-freepdb1-datafile-recovery.sh \
  "Validations/FREEPDB1 Plan and RMAN Schedule.sh"
```

Verify the mapped OL9 image is present, available, x86-64, HVM, and Oracle-owned:

```bash
aws ec2 describe-images \
  --region us-east-1 \
  --owners 131827586825 \
  --image-ids ami-0dd239e274077553a \
  --query 'Images[0].{ImageId:ImageId,State:State,OwnerId:OwnerId,Architecture:Architecture,VirtualizationType:VirtualizationType,Name:Name}' \
  --output table
```

An empty result, API error, non-`available` state, wrong owner, or incompatible architecture is a release blocker.

## Post-deployment validation commands

Set the actual CloudFormation stack name after deployment:

```bash
export AWS_REGION=us-east-1
export STACK_NAME=oracle-backup-recovery-lab

aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}'

INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)

BACKUP_VOLUME_ID=$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='BackupVolumeId'].OutputValue" \
  --output text)

aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,Type:InstanceType,ImageId:ImageId,IamProfile:IamInstanceProfile.Arn,Metadata:MetadataOptions}' \
  --output table

aws ec2 describe-volumes \
  --region "$AWS_REGION" \
  --volume-ids "$BACKUP_VOLUME_ID" \
  --query 'Volumes[0].{Type:VolumeType,SizeGiB:Size,Encrypted:Encrypted,State:State,Attachment:Attachments[0].State,InstanceId:Attachments[0].InstanceId}' \
  --output table

aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].{PingStatus:PingStatus,Platform:PlatformName,PlatformVersion:PlatformVersion,AgentVersion:AgentVersion}' \
  --output table
```

Run non-secret guest readiness checks through SSM:

```bash
COMMAND_ID=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["set -e","test -f /opt/lab/.ready","systemctl is-active amazon-ssm-agent","systemctl is-active oracle-free-23ai","mountpoint /u02/backup","findmnt /u02/backup"]' \
  --query 'Command.CommandId' \
  --output text)

aws ssm wait command-executed \
  --region "$AWS_REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID"

aws ssm get-command-invocation \
  --region "$AWS_REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Code:ResponseCode,Output:StandardOutputContent,Error:StandardErrorContent}'
```

Do not place `VMPassword` in command lines, logs, CI output, SSM parameters, or validation transcripts.

## Scope

Seeded application data is under 2 GiB and resides in `FREEPDB1`, including the dedicated `LABRECOVERY` tablespace/datafile. Learner-run fault scripts are root-owned and require `sudo`; deployment does not execute them. Backups remain on the separate EBS volume, so cross-AZ, cross-Region, and account-level resilience are outside scope.
