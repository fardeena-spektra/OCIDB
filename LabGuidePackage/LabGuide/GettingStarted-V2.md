# Getting Started

## Lab overview

You are the on-call DBA for an Oracle Database Free transaction system hosted in Docker on an Amazon Linux 2023 EC2 instance. In this task-based assessment, you will establish an RMAN backup chain, perform whole-container-database (CDB) point-in-time recovery, recover a deliberately removed `FREEPDB1` training datafile, diagnose a regressed query from simulated AWR/ASH-style evidence, improve its plan with targeted optimizer statistics, and automate backup verification.

Each exercise is scored independently. In particular, **Exercise 2 remains attemptable and scorable even if Exercise 1 was incomplete or unsuccessful**.

Oracle data persists outside the container under `/u01/oradata`. RMAN backups persist on a separate encrypted 30 GiB gp3 EBS volume mounted at `/u02/backup`.

> [!Important]
> Wait until the CloudFormation stack reaches `CREATE_COMPLETE` before connecting. The EC2 resource has a 60-minute creation timeout and signals success only after storage, Docker, Oracle, seed data, SSH, Systems Manager, and recovery-readiness checks pass and `/opt/lab/.ready` is written.

## Architecture

```mermaid
graph TD
    Learner[Candidate workstation] -->|AWS console and CLI| AWS[AWS account]
    Learner -->|Password SSH on TCP 22| SG[EC2 security group]
    Learner -->|Session Manager fallback| SSM[AWS Systems Manager]
    AWS --> CFN[CloudFormation stack]
    CFN --> VPC[VPC]
    VPC --> Subnet[Public subnet and internet gateway]
    Subnet --> SG
    SG --> EC2[Amazon Linux 2023 EC2 host]
    SSM -->|SSM Agent and instance profile| EC2
    EC2 --> Docker[Docker service]
    Docker --> Oracle[oracle-free container]
    Oracle -->|Port 1521| Services[FREE and FREEPDB1 services]
    EC2 --> Root[Encrypted gp3 root EBS]
    Root --> Data[/u01/oradata]
    Data -->|Bind mount| OraData[/opt/oracle/oradata in container]
    EC2 --> Backup[Encrypted 30 GiB gp3 EBS]
    Backup --> BackupPath[/u02/backup]
    BackupPath -->|Bind mount| RMAN[/u02/backup in container]
```

The public subnet provides deployment-time internet egress and DNS for Amazon Linux packages and `container-registry.oracle.com`. Docker runs the image `container-registry.oracle.com/database/free:23.9.0.0` in a container named `oracle-free`, publishes listener port `1521`, and uses restart policy `unless-stopped`. The host paths `/u01/oradata` and `/u02/backup` are owned by numeric UID/GID 54321.

Database shutdown, mount, restore, recovery, and open operations affect Oracle **inside the long-running container**. Do not stop, remove, or recreate `oracle-free` during any exercise.

## Sign in to AWS

AWS documentation confirms that an IAM user signs in with an account-specific URL, user name, and password.

1. Open the lab-provided AWS sign-in URL:

   <inject key="AwsConsoleUrl"></inject>

2. Enter the IAM user name:

   <inject key="IamUserName"></inject>

3. Enter the temporary IAM user password:

   <inject key="IamUserPassword"></inject>

4. In the console Region selector, choose:

   <inject key="AwsRegion"></inject>

5. Confirm that the account shown in the console is:

   <inject key="AwsAccountId"></inject>

Your CloudLabs deployment ID is:

<inject key="DeploymentID"></inject>

Use the deployment ID to distinguish your stack and resources from other lab deployments in the account.

## Understand access and security

CloudFormation creates an EC2 role that trusts `ec2.amazonaws.com` and attaches `AmazonSSMManagedInstanceCore`. This permits the preinstalled SSM Agent to register the instance as a managed node. Bootstrap verifies that SSM Agent and `/opt/aws/bin/cfn-signal` are present in Amazon Linux 2023; it does not install substitutes when either dependency is absent.

The candidate and deployment permissions allow required CloudFormation, EC2, IAM pass-role, Systems Manager, and volume-inspection operations. Lab guardrails are identity-based IAM explicit `Deny` statements, not an AWS Organizations service control policy. Do not alter the role, instance profile, encrypted volumes, security group, or protected resources.

> [!Warning]
> This disposable assessment intentionally enables password SSH. `AdminCidr` defaults to `0.0.0.0/0`, exposing TCP 22 to the internet, and `VMPassword` is intentionally repeated in CloudFormation outputs. Outputs are not secret storage. If you control deployment, restrict `AdminCidr` to a trusted public IPv4 CIDR. Never reuse this password or copy this access design into production.

The Oracle password differs from the Linux password. Bootstrap stores it only in a root-owned mode-0600 environment file. Do not display, copy, or modify that file.

## Inspect stack status and outputs

1. In the AWS console, open **CloudFormation**.
2. Confirm that the console uses the assigned Region.
3. Choose **Stacks**, then select the stack associated with your deployment ID.
4. Confirm that **Stack status** is `CREATE_COMPLETE`. If creation is still running, wait rather than connecting to a partially initialized database.
5. Open the **Outputs** tab.
6. Record the instance ID, public IPv4 address or public DNS name, backup volume ID, Oracle service information, `VMUserName`, and `VMPassword`.

### Optional CLI check

On the Lab VM, CloudLabs bootstrap credentials, when provided, are stored at `$LAB_HOME/cloudlabs-creds.env`; `LAB_HOME` is `/home/ec2-user` on this Amazon Linux host. Load that file only if your lab environment requires it. Then enter the assigned Region and stack name when prompted:

```bash
read -r -p "AWS Region: " AWS_REGION
read -r -p "CloudFormation stack name: " STACK_NAME
aws sts get-caller-identity --region "$AWS_REGION"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}' \
  --output table \
  --region "$AWS_REGION"
```

Verify that the returned account is the lab account shown in the sign-in section and that stack status is `CREATE_COMPLETE`. Do not save the password output in a shared file or terminal transcript.

## Connect with password SSH

AWS guidance requires a reachable instance, the correct host and user, and a security-group rule allowing inbound TCP 22 from the client. This lab supplies password authentication instead of an SSH key.

1. Copy `VMUserName` and the public DNS name from the stack **Outputs** tab.
2. From a local terminal, enter them when prompted:

```bash
read -r -p "VM user name: " VM_USER
read -r -p "Public DNS name: " PUBLIC_DNS
ssh "$VM_USER@$PUBLIC_DNS"
```

3. If prompted to trust the host key, verify the destination against the stack output before accepting it.
4. At the password prompt, enter `VMPassword`. Never place the password in the command or shell history.

The learner account belongs to the `wheel` and `docker` groups. A fresh SSH login supports `sudo` and Docker commands. If a shell was opened before bootstrap completed, disconnect and reconnect to refresh group membership.

## Use Session Manager as the fallback

Session Manager provides an interactive shell without depending on inbound SSH. Use it if TCP 22 is blocked or password SSH fails.

### AWS console method

1. Open **EC2** in the assigned Region.
2. Choose **Instances** and select the instance ID from the stack output.
3. Choose **Connect**.
4. Select **Session Manager**, then choose **Connect**.

You can alternatively open **Systems Manager** > **Session Manager**, choose **Start session**, select the managed instance, and start the session.

A Session Manager shell commonly starts as `ssm-user`. Switch to the stack-output learner account:

```bash
read -r -p "VM user name from CloudFormation outputs: " VM_USER
sudo -iu "$VM_USER"
```

If the instance is not offered as a Session Manager target, confirm that the stack is `CREATE_COMPLETE`, the instance is running, and the console uses the correct Region. The instance also needs its instance profile, a running SSM Agent, and outbound connectivity to Systems Manager endpoints.

### AWS CLI method

The client running this command must have the Session Manager plugin. Enter the assigned Region and output instance ID:

```bash
read -r -p "AWS Region: " AWS_REGION
read -r -p "EC2 instance ID: " INSTANCE_ID
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

## Confirm host and storage readiness

Run these read-only checks after connecting:

```bash
sudo test -f /opt/lab/.ready && echo "Bootstrap readiness marker: present"
sudo stat -c '%U:%G %a %n' /opt/lab/.ready
findmnt /u02/backup
findmnt /u01/oradata || true
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
systemctl is-active docker
systemctl is-active amazon-ssm-agent
sudo stat -c '%u:%g %a %n' /u01/oradata /u02/backup
sudo test -x /opt/lab/inject-ex1.sh && echo "Exercise 1 injector: available"
sudo test -x /opt/lab/inject-ex2.sh && echo "Exercise 2 injector: available"
```

`/u01/oradata` is a directory on the encrypted root filesystem, so it need not appear as a separate mount. `/u02/backup` must be a separate filesystem backed by the encrypted 30 GiB gp3 volume. Both persistent paths must report owner UID/GID `54321:54321`. Docker and SSM Agent must report `active`.

## Verify the pinned Oracle image

The only approved image reference for this release is:

- Tag: `container-registry.oracle.com/database/free:23.9.0.0`
- Approved release-tested x86-64 digest: `sha256:66296e93ffe793012d424439db5771617491e94c782196953d993ffd869c3eb0`

Bootstrap pulls that exact tag, inspects its resolved repository digest, writes the observed value to `/opt/oracle-image-digest.txt`, and compares it with the approved digest. Verification is **fail closed**: a missing, ambiguous, or different digest aborts bootstrap, prevents `/opt/lab/.ready`, and sends a failed CloudFormation resource signal. It must never silently accept or substitute another image.

Inspect the recorded and running-image evidence:

```bash
sudo cat /opt/oracle-image-digest.txt
docker inspect oracle-free --format '{{.Config.Image}}'
docker image inspect container-registry.oracle.com/database/free:23.9.0.0 \
  --format '{{join .RepoDigests "\n"}}'
```

Confirm that the configured image ends in `:23.9.0.0` and that the Oracle repository digest contains the approved digest shown above. Do not pull, retag, or replace the image during the assessment.

> [!Important]
> Oracle Container Registry is an external dependency. The publisher must satisfy Oracle terms or authentication prerequisites and perform a fresh x86-64 registry pull test before publication because Oracle can republish or retire tags. A digest mismatch is a release blocker; do not change the approved value merely to make deployment continue. Registry credentials are not embedded in this package.

## Confirm the running container

Dynamically resolve exactly one intended running container and inspect its mounts:

```bash
mapfile -t IDS < <(docker ps \
  --filter name=oracle-free \
  --filter status=running \
  --format '{{.ID}}')
((${#IDS[@]} == 1)) || {
  echo "Expected exactly one running oracle-free container; found ${#IDS[@]}" >&2
  exit 1
}
CONTAINER_ID=${IDS[0]}
docker ps --filter id="$CONTAINER_ID"
docker inspect "$CONTAINER_ID" \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Confirm these mappings:

- `/u01/oradata` to `/opt/oracle/oradata`
- `/u02/backup` to `/u02/backup`

Do not hardcode the displayed container ID. Every script and validator must dynamically resolve exactly one running `oracle-free` container.

## Confirm Oracle readiness

Use SQL*Plus inside the container:

```bash
docker exec -i oracle-free sqlplus -s / as sysdba <<'SQL'
set pages 100 lines 180
select name, open_mode, log_mode from v$database;
show pdbs
alter session set container=FREEPDB1;
select sys_context('USERENV', 'CON_NAME') as current_container from dual;
exit
SQL
```

Confirm that the CDB is `FREE` in `ARCHIVELOG` mode, `FREEPDB1` is open read/write, and `CURRENT_CONTAINER` is `FREEPDB1`.

Optionally inspect RMAN configuration and incarnation history without changing database state:

```bash
docker exec -i oracle-free rman target / <<'RMAN'
show all;
list incarnation of database;
exit
RMAN
```

The application schema, workload, and dedicated recovery tablespace/datafile reside in `FREEPDB1`, not `CDB$ROOT`. Exercise 1 performs whole-CDB recovery. Exercise 2 restores and recovers only the missing training datafile.

> [!Important]
> When RMAN requires shutdown, mount, restore, recover, or open operations, issue database commands inside `oracle-free`. The Docker container must remain running. After each database state transition, check it with `docker ps --filter name=oracle-free --filter status=running`.

## Understand Exercise 2 independence

Exercise 2 does **not** require Exercise 1 success, PITR evidence, or even an Exercise 1 state file. Run `/opt/lab/inject-ex2.sh` when Exercise 2 instructs you to do so regardless of your Exercise 1 outcome.

Before removing the dedicated training datafile, the Exercise 2 injector determines the current database incarnation and resetlogs SCN. It checks both RMAN metadata and physical pieces for a usable level 0 whole-CDB backup in that current incarnation. If none exists, it creates and verifies an independent safety level 0 backup with archived redo and control-file/SPFILE protection. If that safeguard cannot be created, injection aborts without deleting the training datafile.

If Exercise 1 evidence exists but PITR and `RESETLOGS` cannot be proven, the injector writes a warning to stderr and its protected audit log, then continues safely. Its state records whether the usable backup was learner-created or injector-created. An injector-created safeguard enables Exercise 2 recovery but gives no Exercise 1 credit. Exercise 2 scoring depends only on correctly diagnosing, restoring, recovering, and validating the targeted `FREEPDB1` datafile.

## Diagnostic evidence and lab conventions

The supplied AWR/ASH-style reports are explicitly simulated. They are not Oracle-generated AWR or ASH output. In Exercise 3, corroborate their observations with live execution plans, runtime measurements, checksums, and available dynamic performance views.

Follow these conventions throughout the lab:

- Use `docker exec -it oracle-free rman target /` for an interactive RMAN session.
- Use `docker exec -it oracle-free sqlplus / as sysdba` for an interactive SQL*Plus session.
- Keep `oracle-free` running; never stop, remove, or recreate it.
- Keep Oracle data under `/u01/oradata` and RMAN artifacts under `/u02/backup`.
- Run `/opt/lab/inject-ex1.sh` and `/opt/lab/inject-ex2.sh` with `sudo` only when instructed.
- Never edit or delete protected incident records, state files, audit logs, or injection scripts.
- Never expose Linux or Oracle passwords in commands, logs, screenshots, evidence, or shell history.
- This lab does not use Amazon S3 for backups. Cross-Availability Zone and cross-account resilience are outside scope.

If readiness fails, stop and inspect the CloudFormation **Events** tab and `/var/log/cloudlabs-bootstrap.log`. The bootstrap log is verbose but must not disclose passwords. Report the failed check. Do not create `/opt/lab/.ready`, format or remount disks, reinstall SSM Agent or CloudFormation helpers, recreate the container, alter the approved image check, or modify protected scripts.

## After publishing

> [!Note] These steps run **after** you push the template to CloudLabs — they verify CloudLabs can actually serve this lab guide to candidates.

- **Verify docs-proxy access:** open Templates → your template → **Lab Guide Settings** in <https://admin.cloudlabs.ai> and confirm CloudLabs can reach this repo via the docs proxy. If the repo is private, configure GitHub access at the template level.
- **Verify inline questions and inline validations:** sign in to <https://admin.cloudlabs.ai>, open your template, and walk through one full lab run to confirm every `<question>` and `<validation step="..."/>` renders correctly. Fix any that don't resolve.
