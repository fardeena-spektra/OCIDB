# Oracle Backup, Recovery & Diagnostics

This AWS package provisions a disposable, intermediate Oracle Database Free assessment on Amazon Linux 2023. Learners create and prove an RMAN backup chain, perform whole-CDB point-in-time recovery, independently recover a removed `FREEPDB1` datafile, diagnose a query regression from simulated AWR/ASH-style evidence, improve its plan with targeted optimizer statistics, and automate Docker-aware RMAN verification.

The three exercises are independently scored. Exercise 2 remains attemptable if Exercise 1 is incomplete or unsuccessful; an injector-created safety backup may support Exercise 2 but earns no Exercise 1 credit.

## Canonical deployment artifacts

- `DeploymentPackage/deploy-01.json` — the single AWS CloudFormation stage.
- `DeploymentPackage/deploy-01.parameters.json` — CloudLabs parameter bindings.
- `DeploymentPackage/Scripts/userdata.sh` — the canonical, self-contained Amazon Linux 2023 bootstrap, with Unix LF line endings and `#!/bin/bash` as line one.

`DeploymentPackage/Scripts/userdata-01.sh`, if it remains in the package, is a legacy artifact only. Do not publish it as the bootstrap, reference it from CloudFormation or the parameter file, or use it in deployment instructions. The canonical published bootstrap is always `DeploymentPackage/Scripts/userdata.sh`.

## PAYNOTIFY-compatible CloudFormation contract

### Parameters

The template exposes these exact parameter names:

- `CloudLabsDeploymentID` — `String`; identifies the CloudLabs deployment and participates in resource Name tags.
- `CheckAcknowledgement` — `String`; default `TRUE`; allowed values `TRUE` and `FALSE`.
- `AmazonECSTaskExecutionRolePolicy` — `String`; default `arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy`.
- `VMUserName` — Linux user created for lab access.
- `VMPassword` — `NoEcho` password used for lab SSH. It is intentionally returned in Outputs; Outputs are not secret storage.
- `AdminCidr` — IPv4 CIDR for the normal SSH security group; default `0.0.0.0/0` for this disposable lab.
- `InstanceType` — EC2 instance type; default `t3.large`.
- `BootstrapScriptUrl` — HTTPS location of the standalone bootstrap; default `https://raw.githubusercontent.com/fardeena-spektra/OCIDB/refs/heads/main/Userdata/userdata.sh`.

The parameter file must bind these PAYNOTIFY parameters and must not reference `userdata-01.sh`.

### Resources and naming

The stage creates:

- A VPC, internet gateway, gateway attachment, public subnet, route table, default internet route, and subnet route-table association.
- A normal VM security group for password SSH from `AdminCidr`.
- `clgSg`, a second security group with unrestricted IPv4 and IPv6 ingress and egress, as required by the PAYNOTIFY pattern.
- An EC2 IAM role and instance profile. The role trusts `ec2.amazonaws.com` and attaches `AmazonSSMManagedInstanceCore`.
- `TaskExecutionRole`, which trusts `ecs-tasks.amazonaws.com` for `sts:AssumeRole` and attaches the managed policy ARN supplied by `AmazonECSTaskExecutionRolePolicy`.
- One Amazon Linux 2023 EC2 instance whose logical resource is `LabVm` and whose `Name` tag is exactly `labvm`.
- An encrypted gp3 root volume and a separate encrypted 30 GiB gp3 EBS backup volume.

The VPC, internet gateway, subnet, route table, and security-group Name tags include `${CloudLabsDeploymentID}`. The EC2 instance remains exactly `labvm`, enabling guides and validators to locate it consistently.

The instance uses this Region-local AWS public Systems Manager parameter dynamic reference for `ImageId`:

```text
{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}
```

Its encrypted gp3 root volume is mapped as `/dev/xvda`; persistent Oracle data is stored under `/u01/oradata`. The separate encrypted 30 GiB gp3 volume is discovered from `BACKUP_VOLUME_ID` by its normalized NVMe EBS serial and mounted at `/u02/backup`.

`LabVm` retains `CreationPolicy.ResourceSignal.Timeout` set to `PT60M`. CloudFormation therefore waits for one resource signal before considering instance creation complete.

### Exact outputs

The PAYNOTIFY outputs are exactly:

- `CloudLabsDeploymentID`
- `AWSAccountID`
- `Region`
- `VpcId`
- `vmSubnetId`
- `vmSecurityGroupId`
- `clusterSecurityGroupId`
- `TaskExecutionRole` — the ECS task execution role ARN
- `InstanceId`
- `VMName` — `labvm`
- `VMPublicIP`
- `VMPrivateIP`
- `VMPublicDNSName`
- `VMPrivateDNSName`
- `VMUserName`
- `VMPassword`

The retained Oracle-specific outputs are exactly:

- `BackupVolumeId`
- `BackupMount`
- `OracleContainerName`
- `OracleServices`
- `OracleListenerPort`
- `SSMTarget`

Legacy output names `PublicIPv4` and `PublicDnsName` are removed. Consumers must use `VMPublicIP` and `VMPublicDNSName`. Do not add aliases for the removed names.

## UserData download and signaling contract

The CloudFormation UserData wrapper performs only the download handoff and pre-execution checks:

1. Export the deployment ID, stack name, `LabVm` resource name, VM username and password, AWS Region, and backup-volume ID required by the standalone script, without printing secrets.
2. Download `BootstrapScriptUrl` to a protected local file.
3. If `curl` fails, immediately run `/opt/aws/bin/cfn-signal --success false` for resource `LabVm` with a nonsecret reason, then exit nonzero.
4. Verify that the downloaded file begins with `#!/bin/bash`, preserve or normalize Unix LF handling, make the file executable, and run it.
5. Do not send a second success signal from the wrapper. After a successful download, `userdata.sh` owns normal failure trapping, readiness checks, and the one final success signal.

This division prevents a failed download from waiting for the full 60-minute creation-policy timeout while also preventing duplicate success signals.

## Canonical standalone bootstrap

`DeploymentPackage/Scripts/userdata.sh` is complete and self-contained. It provides:

- strict error handling and verbose, nonsecret logging to `/var/log/cloudlabs-bootstrap.log` without shell tracing;
- creation of `VMUserName`, membership in `wheel` and `docker`, password assignment, password-SSH configuration validation, and `sshd` restart;
- NVMe serial discovery for `BACKUP_VOLUME_ID` and persistent mounting at `/u02/backup`;
- `/u01/oradata` creation with numeric UID/GID `54321` ownership;
- Docker installation and startup;
- pull and digest verification for `container-registry.oracle.com/database/free:23.9.0.0` against approved x86-64 repository digest `sha256:66296e93ffe793012d424439db5771617491e94c782196953d993ffd869c3eb0`;
- secure creation and readiness of container `oracle-free`, ARCHIVELOG and RMAN configuration, and `FREEPDB1` seeding below 2 GiB;
- complete generation of `/opt/lab/inject-ex1.sh` and independent `/opt/lab/inject-ex2.sh`;
- proof that database shutdown, mount, and recovery operations do not stop the Docker container;
- final enable/restart of SSM Agent;
- creation of `/opt/lab/.ready` only after readiness succeeds;
- a `/opt/aws/bin/cfn-signal` failure trap and exactly one final success signal.

The persistent Docker bind mounts are:

```text
/u01/oradata:/opt/oracle/oradata
/u02/backup:/u02/backup
```

Recovery changes database state inside the still-running container. Learners and automation must not stop or remove the container.

## Access and security risks

This deployment intentionally uses insecure conventions suitable only for a short-lived, isolated lab:

- `AdminCidr` defaults to `0.0.0.0/0`, exposing password SSH to all IPv4 sources.
- `clgSg` permits unrestricted IPv4 and IPv6 ingress and egress.
- `VMPassword` is marked `NoEcho` but is intentionally included in stack Outputs. CloudFormation Outputs are not a secret store, and `NoEcho` does not protect a value placed in Outputs.
- Membership in the `docker` group is effectively root-equivalent.

Narrow `AdminCidr` and remove the open `clgSg`, password Outputs, password SSH, and Docker-group access in any non-lab implementation.

IAM guardrails in this package are identity-based explicit `Deny` statements, not an AWS Organizations service control policy. Applicable explicit denies override allows. Candidate/deployment permissions include the constrained IAM create, tag, delete, and pass-role operations required for both the EC2 role and `TaskExecutionRole`.

## Exercise model

- **Exercise 1 — Full/incremental backup and whole-CDB PITR (35 minutes):** create level 0/1 backups, inject a transaction, recover the whole CDB to the target SCN, open with `RESETLOGS`, verify `FREEPDB1`, and create a post-resetlogs backup.
- **Exercise 2 — Independent `FREEPDB1` datafile recovery (30 minutes):** run the independent injector regardless of Exercise 1 outcome, diagnose the removed training file, restore and recover only that datafile, and prove integrity.
- **Exercise 3 — Diagnose, tune, and automate (30 minutes):** analyze simulated reports, corroborate live evidence, gather targeted statistics, prove improvement, and schedule Docker-aware RMAN verification.

The AWR/ASH-style reports are training simulations, not Oracle-generated AWR or ASH output.

## Package inventory

### Deployment

- `DeploymentPackage/deploy-01.json`
- `DeploymentPackage/deploy-01.parameters.json`
- `DeploymentPackage/Scripts/userdata.sh`

### Learning and assessment

- `LabGuidePackage/Lab Guide/Lab Guide/GettingStarted-V2.md`
- `LabGuidePackage/Lab Guide/Lab Guide/Exercise-01.md`
- `LabGuidePackage/Lab Guide/Lab Guide/Exercise-02.md`
- `LabGuidePackage/Lab Guide/Lab Guide/Exercise-03.md`
- `Inline-Questions/question-01.md` through `Inline-Questions/question-05.md`
- `solution-guide/solution.md`

### Validation and permissions

- Three AWS CLI/SSM Bash validators under `Validations/`
- IAM allow and identity-based explicit-Deny policy artifacts under `permissions/`

If `DeploymentPackage/Scripts/userdata-01.sh` remains physically present, it is legacy-only and is deliberately excluded from the canonical deployment inventory.

## Release checks

Validate the template and canonical script from the package root:

```bash
export AWS_REGION=us-east-1
aws cloudformation validate-template \
  --region "$AWS_REGION" \
  --template-body file://DeploymentPackage/deploy-01.json

jq empty DeploymentPackage/deploy-01.json DeploymentPackage/deploy-01.parameters.json
bash -n DeploymentPackage/Scripts/userdata.sh
shellcheck DeploymentPackage/Scripts/userdata.sh
```

Before publication, resolve and deployment-test the current AL2023 AMI in every supported Region. Also pull the pinned Oracle tag on x86-64 and verify its repository digest. A missing tag, failed pull, architecture mismatch, or digest mismatch is a release blocker.

## AWS fact verification

The AWS contract was checked against AWS documentation for the relevant platform behavior:

- Amazon Linux 2023 AMI discovery through public SSM parameters: <https://docs.aws.amazon.com/linux/al2023/ug/launching-using-ssm-parameter.html>
- CloudFormation dynamic references: <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/dynamic-references.html>
- `CreationPolicy` resource signals and timeout behavior: <https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-attribute-creationpolicy.html>
- `cfn-signal` failure/success signaling: <https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/cfn-signal.html>
- IAM role trust principals and `sts:AssumeRole`: <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_terms-and-concepts.html>
- `AmazonECSTaskExecutionRolePolicy`: <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonECSTaskExecutionRolePolicy.html>
- `AmazonSSMManagedInstanceCore`: <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html>
- CloudFormation `NoEcho` caveats: <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/parameters-section-structure.html>
- EBS encryption and gp3 volumes: <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption.html> and <https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html>
- NVMe EBS volume identification: <https://docs.aws.amazon.com/ebs/latest/userguide/identify-nvme-ebs-device.html>
- IAM evaluation and explicit-deny precedence: <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html>

AWS-managed image contents, public parameter values, and third-party registry mappings can change. Runtime checks and release deployment tests remain authoritative.