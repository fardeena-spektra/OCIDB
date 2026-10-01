# Getting Started

## Lab overview

You are the on-call DBA for an Oracle Database Free transaction-processing environment on Amazon EC2. In the exercises, you will establish and test an RMAN backup chain, perform whole-container-database recovery to an SCN, recover one deliberately removed `FREEPDB1` datafile, investigate a SQL regression, and automate backup verification.

The environment is deployed only in **US East (N. Virginia), `us-east-1`**. The CloudFormation template has an Oracle Linux 9 AMI mapping only for that Region and is intended to fail rather than silently select a different image elsewhere.

> [!Important]
> Wait for the CloudFormation stack to reach `CREATE_COMPLETE` before connecting. The EC2 resource sends its success signal only after Oracle, the seed data, the backup filesystem, SSH, and SSM Agent pass bootstrap checks and `/opt/lab/.ready` has been created.

## Architecture

```mermaid
graph TD
    Learner[Candidate workstation] -->|AWS console or CLI| AWS[AWS account]
    Learner -->|Password SSH / TCP 22| SG[EC2 security group]
    Learner -->|Session Manager fallback| SSM[AWS Systems Manager]
    AWS --> CFN[AWS CloudFormation stack]
    CFN --> VPC[VPC in us-east-1]
    VPC --> Subnet[Public subnet and internet gateway]
    Subnet --> SG
    SG --> EC2[Oracle Linux 9 EC2 instance]
    SSM -->|IAM-authorized session| Agent[SSM Agent]
    Agent --> EC2
    EC2 --> Root[Encrypted root EBS volume]
    EC2 --> Backup[Encrypted 30 GiB gp3 EBS volume]
    Backup --> Mount[/u02/backup]
    EC2 --> CDB[Oracle Database Free CDB: FREE]
    CDB --> PDB[FREEPDB1]
    PDB --> Data[Application, workload, and recovery-training data]
```

The public subnet supplies deployment-time internet egress for Oracle packages, the official SSM Agent RPM, and bootstrap dependencies. Oracle database files and lab assets use the encrypted root volume. RMAN backup artifacts use the separate encrypted 30 GiB gp3 volume mounted at `/u02/backup` by filesystem UUID.

## Sign in to AWS

1. Open the lab-provided AWS sign-in URL:

   <inject key="AwsConsoleUrl"></inject>

2. Enter the IAM user name:

   <inject key="IamUserName"></inject>

3. Enter the temporary IAM user password:

   <inject key="IamUserPassword"></inject>

4. In the AWS console Region selector, choose **US East (N. Virginia) — `us-east-1`**.
5. Confirm that the account shown in the console is:

   <inject key="AwsAccountId"></inject>

Your CloudLabs deployment ID is:

<inject key="DeploymentID"></inject>

Use it to distinguish your resources if the account contains more than one lab deployment.

## Understand the IAM plumbing

CloudFormation creates a dedicated EC2 IAM role and attaches it to the instance through an instance profile. The role trusts `ec2.amazonaws.com` and carries the AWS managed policy `AmazonSSMManagedInstanceCore`, allowing the installed SSM Agent to register the VM as a managed node. The instance role is not the same identity as your candidate IAM user and does not grant broad administrator or S3 access; backups remain on EBS.

Your candidate permissions support the expected CloudFormation, EC2, pass-role, and Systems Manager path. Package guardrails use explicit IAM `Deny` statements—not an AWS Organizations service control policy—to constrain the lab to `us-east-1`, approved `t3` instance types, encrypted EBS, the designated instance role, and protected lab resources. An explicit deny always takes precedence over an allow, so do not alter the role, instance profile, encryption settings, security group, or lab control-plane resources.

## Inspect stack status and outputs

1. In the AWS console, open **CloudFormation**.
2. Confirm the selected Region is **US East (N. Virginia)**.
3. On **Stacks**, choose the stack associated with your deployment ID.
4. Confirm **Stack status** is `CREATE_COMPLETE`. If creation is still in progress, wait; do not connect to a partially bootstrapped database.
5. Open the **Outputs** tab.
6. Record the values supplied for:
   - EC2 instance ID
   - public IPv4 address and public DNS name
   - SSH command hint
   - SSM target
   - Oracle services
   - backup mount path
   - `VMUserName`
   - `VMPassword`

> [!Warning]
> CloudFormation does not redact values placed in stack outputs. Although `VMPassword` is a `NoEcho` parameter, this assessment intentionally also returns it as an output. Anyone who can inspect the stack outputs can read it. Use this environment only as an isolated, short-lived lab, do not reuse the password, do not paste it into commands or evidence, and delete the stack when instructed.

### Optional CLI check

The assigned AWS Region is:

<inject key="AwsRegion"></inject>

On a terminal with the preconfigured lab AWS CLI profile, set `AWS_REGION` to that displayed value and enter the stack name you selected in the console:

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

Verify that the returned account is the lab account displayed above and that the stack is `CREATE_COMPLETE`. Do not save the password output to a shared file or terminal transcript.

## Connect with password SSH

The template deliberately enables password authentication for the stack-output user.

1. Copy the `VMUserName` and public DNS name from the stack **Outputs** tab.
2. From a local terminal, enter the values when prompted:

```bash
read -r -p "VM user name: " VM_USER
read -r -p "Public DNS name: " PUBLIC_DNS
ssh "$VM_USER@$PUBLIC_DNS"
```

3. If prompted to trust the host key, compare the destination with the stack output, then accept it.
4. At the SSH password prompt, enter the `VMPassword` shown in the stack outputs. The password is entered interactively and should not appear in the command or shell history.

> [!Caution]
> The lab security group intentionally allows TCP 22 from `AdminCidr`, whose assessment default is `0.0.0.0/0`. AWS recommends restricting SSH to your computer's public IPv4 address or trusted network range. Public SSH plus password authentication is an intentionally insecure disposable-lab configuration. If you control deployment parameters, narrow `AdminCidr` before launch; do not copy this design into production.

## Use Session Manager as the fallback

Use Session Manager if SSH is blocked by your network or the password connection fails. The bootstrap installs SSM Agent, enables it, and attaches an instance profile backed by `AmazonSSMManagedInstanceCore`. Session Manager does not require inbound SSH access.

### AWS console method

1. Open **EC2** in **US East (N. Virginia)**.
2. Choose **Instances**, select the instance ID from the CloudFormation output, and choose **Connect**.
3. Select the **Session Manager** tab.
4. Choose **Connect**.

Alternatively, open **Systems Manager** > **Session Manager**, choose **Start session**, select the output instance ID, and choose **Start session**.

If the instance is not listed, first confirm the stack is `CREATE_COMPLETE`. Then verify that the instance is running, its instance profile is attached, and SSM Agent had outbound HTTPS connectivity during bootstrap. Do not remove and recreate IAM resources as a workaround.

A Session Manager shell commonly starts as `ssm-user`. Switch to the learner account only when ownership matters:

```bash
sudo -iu "$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "ssm-user" {print $1; exit}')"
```

### AWS CLI method

The CLI method requires the Session Manager plugin on the computer running the AWS CLI. Set the displayed Region and copy the instance ID from the stack output:

```bash
read -r -p "AWS Region: " AWS_REGION
read -r -p "EC2 instance ID: " INSTANCE_ID
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

## Confirm readiness

After connecting by SSH or Session Manager, run these read-only checks before starting Exercise 1:

```bash
sudo test -f /opt/lab/.ready && echo "Bootstrap readiness marker: present"
sudo stat -c '%U:%G %a %n' /opt/lab/.ready
findmnt /u02/backup
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
systemctl is-active amazon-ssm-agent
sudo test -x /opt/lab/inject-ex1.sh && echo "Exercise 1 injector: available"
sudo test -x /opt/lab/inject-ex2.sh && echo "Exercise 2 injector: available"
```

Expected results:

- `/opt/lab/.ready` exists.
- `/u02/backup` is a separate mounted filesystem backed by the 30 GiB volume.
- `amazon-ssm-agent` reports `active`.
- Both injection scripts exist and are executable; they remain root-owned and must be invoked with `sudo` only when an exercise instructs you to do so.

Check the Oracle CDB and PDB state:

```bash
sudo -iu oracle bash -lc 'export ORACLE_SID=FREE; sqlplus -s / as sysdba <<"SQL"
set pages 100 lines 180
select name, open_mode, log_mode from v\$database;
show pdbs
alter session set container=FREEPDB1;
select sys_context('\''USERENV'\'', '\''CON_NAME'\'') as current_container from dual;
exit
SQL'
```

Confirm that:

- the CDB is `FREE` and uses `ARCHIVELOG` mode;
- `FREEPDB1` is open read/write;
- `CURRENT_CONTAINER` is `FREEPDB1` after the container switch.

The application schema, slow workload, and dedicated recovery-training tablespace/datafile are all in `FREEPDB1`, not `CDB$ROOT`. Maintain explicit container awareness throughout the lab. Exercise 1 performs whole-CDB recovery even though its business transaction is in `FREEPDB1`; Exercise 2 deliberately uses PDB/datafile scope.

> [!Note]
> Diagnostic files described as **AWR/ASH-style** are seeded simulations. Oracle Database Free does not generate licensed AWR/ASH data for this lab. You will corroborate those files with live execution plans, runtime measurements, and dynamic performance views.

If any readiness check fails, stop. Recheck the CloudFormation **Events** tab for a resource-signal failure and report the failed check rather than creating `/opt/lab/.ready`, remounting disks, changing IAM, or modifying the protected injection scripts yourself.

## Lab conventions

- Store requested evidence only in the exercise-defined evidence locations under `/opt/lab` or `/u02/backup`.
- Never place the VM password in a script, log, SSM command, screenshot, command history, or evidence file.
- Do not run either fault-injection script early. Each script enforces prerequisites and records protected incident metadata.
- Do not edit or delete injection records.
- Keep RMAN backups on `/u02/backup`; this lab does not use Amazon S3.
- The backup volume is EBS-only. Availability Zone or account-level disaster recovery is outside the assessment scope.

## After publishing

> [!Note] These steps run **after** you push the template to CloudLabs — they verify CloudLabs can actually serve this lab guide to candidates.

- **Verify docs-proxy access:** open Templates → your template → **Lab Guide Settings** in <https://admin.cloudlabs.ai> and confirm CloudLabs can reach this repo via the docs proxy. If the repo is private, configure GitHub access at the template level.
- **Verify inline questions and inline validations:** sign in to <https://admin.cloudlabs.ai>, open your template, and walk through one full lab run to confirm every `<question>` and `<validation step="..."/>` renders correctly. Fix any that don't resolve.
