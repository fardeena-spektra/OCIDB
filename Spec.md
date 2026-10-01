Oracle Backup, Recovery & Diagnostics

Lab Overview
• Cloud: AWS
• Duration: 105 minutes
• Exercises: 3 (Full/incremental backup and whole-CDB PITR, Independent FREEPDB1 datafile recovery, Diagnose tune and automate)
• Validations: 3
• Deployed services: AWS CloudFormation, Amazon VPC, internet gateway, public subnet and route table, normal VM security group, unrestricted IPv4/IPv6 clgSg, Amazon EC2 t3.large instance named labvm with Amazon Linux 2023, encrypted gp3 root volume, encrypted 30 GiB gp3 backup volume, EC2 IAM role and instance profile with AmazonSSMManagedInstanceCore, ECS TaskExecutionRole with AmazonECSTaskExecutionRolePolicy, AWS Systems Manager, Docker, Oracle Database Free 23.9.0.0 container, and canonical DeploymentPackage/Scripts/userdata.sh bootstrap; PAYNOTIFY resources use CloudLabsDeploymentID in network Name tags and publish CloudLabsDeploymentID, AWSAccountID, Region, VpcId, vmSubnetId, vmSecurityGroupId, clusterSecurityGroupId, TaskExecutionRole, InstanceId, VMName, VMPublicIP, VMPrivateIP, VMPublicDNSName, VMPrivateDNSName, VMUserName, VMPassword, BackupVolumeId, BackupMount, OracleContainerName, OracleServices, OracleListenerPort, and SSMTarget
• Scenario: As the on-call DBA for an Oracle Database Free transaction system running in Docker on labvm, the learner establishes an RMAN backup chain, performs whole-CDB point-in-time recovery, and independently restores a lost FREEPDB1 datafile. The learner then diagnoses simulated AWR/ASH-style evidence, applies targeted optimizer statistics, proves improvement, and schedules Docker-aware RMAN verification; the disposable environment intentionally includes open password SSH and an unrestricted clgSg and uses BootstrapScriptUrl default https://raw.githubusercontent.com/fardeena-spektra/OCIDB/refs/heads/main/Userdata/userdata.sh with immediate failed cfn-signal handling if curl cannot download it.

This Package Includes

Deliverables Included in the Package
• Lab Guide
• Master Document
• Inline Validations
• Inline Questions / Assessments

Inline Validations
Pre-configured inline validations enabled

Inline Assessment Questions
Single-choice questions (Simple question types only)

Lab Guide Preview
Preview link for the lab guide documentation:
[\[CloudLabs LabGuide Preview\]](https://experience.cloudlabs.ai/#labguidepreview/<GUID>/1)

Lab Environment Setup & Deployment
Lab provisioning and setup include one or more of the following components:
• ARM template deployment
• Custom Script Extension (CSE)
• Custom image-based environment setup
• Supporting deployment configurations as required

Exclusions
This package does not include:
• Scoring or grading mechanisms for inline validations
• Complex or advanced inline question types