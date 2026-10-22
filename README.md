# aws-kafka-sec-codepipeline

The `aws-kafka-sec` stack delivered by **AWS CodePipeline + CodeBuild** instead of GitHub Actions. The Kafka stack, controls and policies are unchanged; `pipeline/` and `buildspecs/` are new.

Terraform-based AWS security automation for Kafka infrastructure, featuring AWS Config compliance checks, automated remediation, Conformance Packs, and security controls.

This repository takes an Apache Kafka broker on EC2 (KRaft mode) and adds security and compliance controls on top of it:

| Area | What it provides |
|---|---|
| **Kafka infrastructure** | VPC across two AZs, EC2 broker with IMDSv2 and encrypted EBS, SSM Session Manager access (no SSH, no public Kafka port) |
| **Secrets Manager + Kafka auth** | Terraform generates the Kafka credential into Secrets Manager; the broker reads it at boot and enforces SASL/SCRAM, so every client must authenticate with it |
| **Detective control** | Custom AWS Config rule (Lambda) that reports S3 buckets without versioning |
| **Reactive control** | Custom AWS Config rule (Lambda) that finds S3 buckets without full Public Access Block, with automatic remediation by a custom SSM Automation document |
| **Conformance pack** | Both rules and the remediation deployed as one unit |
| **Policy as code (OPA)** | Rego policies checked with `conftest` against every Terraform plan; a violation fails the PR and blocks the deploy |
| **CI/CD** | AWS CodePipeline + CodeBuild: validate + plan + policy check on PR; validate → plan → policy check → manual approval → apply → tests on `main`, one IAM role per stage |

## How it works

```text
                       Terraform
                           │
     ┌─────────────────────┼──────────────────────────┐
     ▼                     ▼                          ▼
 VPC + EC2 Kafka     Secrets Manager          Rule Lambdas + IAM roles
     │                     │                          │
     └─ SASL/SCRAM login ──┘                          ▼
                                            Conformance pack
                                       ┌──────────────┴──────────────┐
                                       ▼                             ▼
                              Detective rule                   Reactive rule
                              (every 24h)                      (on bucket change)
                                       │                             │
                                       ▼                             ▼
                              versioning on?                 all 4 Public Access
                              → report only                  Block settings on?
                                                                     │ no
                                                                     ▼
                                                     SSM Automation remediation
                                                     → re-evaluated → COMPLIANT
```

### Detective: S3 versioning (detect → report)

1. Every 24 hours AWS Config invokes the detective Lambda.
2. The Lambda finds buckets carrying the scope tag (one Resource Groups Tagging API call) in its own region.
3. For each one it reads the versioning status: `Enabled` → `COMPLIANT`, otherwise `NON_COMPLIANT`.
4. Results are sent back to Config (`PutEvaluations`). Nothing is changed.

### Reactive: S3 Public Access Block (detect → remediate → verify)

1. A tagged bucket's configuration changes; the AWS Config recorder records it.
2. Config invokes the reactive Lambda with the configuration item.
3. If any of `BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets` is off → `NON_COMPLIANT`.
4. Config automatically runs our SSM Automation document `<project>-<env>-s3-public-access-remediation` under a dedicated least-privilege role. Its three steps (Python in `modules/config_controls/remediation/`, unit-tested):
   - **VerifyScopeTag:** refuses to touch a bucket without the scope tag
   - **EnablePublicAccessBlock:** turns on all four settings, recording the prior state
   - **VerifyPublicAccessBlock:** confirms all four settings are on, or fails the run
5. The fix is itself a change, so the rule re-evaluates → `COMPLIANT`.

The Lambda only decides; it never modifies the bucket. Remediation is done by SSM Automation, with retries and an audit trail.

### Kafka authentication: Secrets Manager → SASL/SCRAM

```text
terraform apply ─► random_password ─► Secrets Manager {username, password}
                                             │ (IAM: broker role may read this secret only)
EC2 first boot ──────────────────────────────┘
  1. read the secret with the instance role (user data holds only the ARN)
  2. kafka-storage.sh format --add-scram  → credential stored as a salted hash in cluster metadata
  3. port 9092 = SASL_PLAINTEXT, mechanism SCRAM-SHA-512 → no credential, no access
Clients ─► kafka-client-config fetches the secret at run time → temporary config → connect
```

- **No secret in code, user data or logs.** User data carries only the secret's ARN; command tracing is turned off while the credential is handled, and the e2e tests check that the value appears in neither user data nor the provisioning logs.
- **On disk only where Kafka needs it.** The broker's own login (for inter-broker authentication) lives in `server.properties`, readable only by the `kafka` user (`600`).
- **New credential, new broker.** The secret's version is part of user data, so a changed password replaces the broker and it is formatted with the new credential.

Connect from the broker (`ssm_connect_command`):

```bash
CFG=$(kafka-client-config)          # temporary client config with the credential
/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --command-config "$CFG" --list
rm -f "$CFG"
```

### Safety in a shared account: tagged buckets only

Because the reactive control changes buckets automatically, both rules only act on buckets tagged:

```text
Phase3Scope = <project_name>-<environment>      (default: kafka-on-ec2-cp-dev)
```

- **Reactive:** the Config rule scope is the tag, and the Lambda re-checks the tag before reporting `NON_COMPLIANT`, so remediation can never reach an untagged bucket.
- **Detective:** periodic rules have no change scope, so the Lambda itself queries only tagged buckets.

### AWS Config recorder

This repository does **not** create an AWS Config recorder or delivery channel. AWS allows one recorder per account and region; in a Control Tower account it already exists (`aws-controltower-BaselineConfigRecorder`) and is owned by Control Tower. The rules use that recorder. In an account without AWS Config, enable the recorder first.

## Policy as code (OPA)

Every Terraform plan is converted to JSON and checked against the Rego policies in `policy/` with [conftest](https://www.conftest.dev/). The policies see everything that will exist after the change, including unchanged resources, so the whole stack is checked on every run.

```text
terraform plan -out=tfplan ─► terraform show -json ─► plan.json ─► conftest test (policy/*.rego)
                                                                     │
                                         any deny ─► job fails ─► PR blocked / apply never runs
```

| ID | Rule | Why |
|---|---|---|
| EC2-001 | EC2 must require IMDSv2 | Stops credential theft via the metadata service (SSRF) |
| EC2-002 | Root/data volumes encrypted; root volume declared explicitly | Data at rest, independent of account defaults |
| EC2-003 | Instance types only from `t3`, `t3a` | Cost guardrail |
| NET-001 | No inbound from `0.0.0.0/0` or `::/0` | Kafka and SSH never public; access is via SSM |
| TAG-001 | `Project`, `Environment`, `ManagedBy` on every taggable resource | Ownership and cost allocation |
| SEC-001 | Secrets Manager values must not be literals in code | Checks how the value is written, never the value itself |
| IAM-001 / IAM-002 | No `Action "*"` on `Resource "*"`; no `AdministratorAccess` attachments | Least privilege |
| LOG-001 / LOG-002 | Log groups have retention; every Lambda's log group is managed in code | No orphaned, never-expiring logs |

Where it runs:

| Where | Check |
|---|---|
| PR check | `conftest verify` |
| Deploy pipeline, Validate stage | `conftest verify` |
| Deploy pipeline, Plan stage | `conftest test` on the plan that is then approved and applied (`terraform apply tfplan`) |

## Repository structure

```text
aws-kafka-sec-codepipeline/
├── pipeline/                       CI/CD infrastructure (own Terraform root + state, applied by an admin)
│   ├── main.tf                     naming, GitHub connection (CodeConnections)
│   ├── boundary.tf                 permissions boundary every stack role must carry
│   ├── artifacts.tf                KMS key, artifact bucket, approval topic
│   ├── iam.tf                      one role per stage + the CodePipeline role
│   ├── codebuild.tf                stage projects + PR check
│   └── codepipeline.tf             deploy and destroy pipelines
├── buildspecs/                     validate (also the PR check), plan, apply, integration, destroy
├── modules/
│   ├── vpc/                        VPC, public/private subnets, routing
│   ├── security_group/             broker SG (Kafka ports only from itself)
│   ├── iam/                        broker role: SSM + read the secret
│   ├── ec2_kafka/                  broker instance + Kafka install with SASL/SCRAM (user data)
│   ├── secrets_manager/            generated Kafka credential
│   └── config_controls/
│       ├── main.tf                 Lambdas, IAM roles, log groups, conformance pack
│       ├── templates/conformance_pack.yaml
│       ├── templates/remediation_document.yaml   custom SSM Automation runbook
│       ├── remediation/s3_public_access_block.py  its three remediation steps
│       └── lambda/
│           ├── detective/handler.py
│           └── reactive/handler.py
├── policy/                         OPA policies (Rego) + their unit tests (*_test.rego)
│   ├── lib/                        plan helpers and test builders
│   ├── ec2.rego  network.rego  tagging.rego  secrets.rego  iam.rego  logging.rego
├── tests/
│   ├── test_phase3_logic.py        unit tests for both rule Lambdas (mocked AWS)
│   ├── test_remediation.py         unit tests for the remediation steps (mocked AWS)
│   └── test_kafka_e2e.py           on the broker via SSM: authenticated produce/consume,
│                                   auth rejection, credential-leak checks
├── scripts/
│   ├── ci/                         tool install, terraform init, wait-for-broker
│   ├── create_test_resources.sh    creates two tagged, non-compliant test buckets
│   └── cleanup.sh                  deletes those test buckets
├── main.tf  variables.tf  outputs.tf  providers.tf
├── terraform.tfvars
└── backend.hcl.example
```

## Prerequisites

- Terraform >= 1.11, AWS CLI, Python 3.12
- AWS credentials (SSO) for local runs
- An existing S3 bucket for Terraform state
- AWS Config recording in the target region (see above)

## Deploy

Deploy through the pipeline (see [CI/CD](#cicd)). Local runs skip the review and approval, so use them only to inspect:

```bash
cp backend.hcl.example backend.hcl
terraform init -backend-config=backend.hcl
terraform plan
```

Key outputs:

| Output | Use |
|---|---|
| `ssm_connect_command` | Open a shell on the broker |
| `phase3_secret_arn` | The Secrets Manager secret holding the Kafka credential |
| `phase3_conformance_pack_name` | The conformance pack |
| `compliance_scope_tag_key` / `compliance_scope_tag_value` | Tag a bucket with these to bring it under the rules |

## Test

**Unit tests** (no AWS needed):

```bash
pip install -r tests/requirements.txt
pytest tests/test_phase3_logic.py tests/test_remediation.py -v
```

**OPA policies** (install [conftest](https://www.conftest.dev/install/)):

```bash
conftest verify --policy policy                       # policy unit tests, no AWS needed

terraform plan -out=tfplan                            # needs AWS credentials
terraform show -json tfplan > plan.json
conftest test plan.json --policy policy --all-namespaces
rm -f plan.json                                       # contains planned values, incl. sensitive ones
```

**Controls in AWS:** create two deliberately non-compliant, tagged buckets:

```bash
export AWS_REGION=us-east-1
bash scripts/create_test_resources.sh
```

Then check results. AWS Config adds a suffix to rule names inside a conformance pack, so list them first:

```bash
PACK="$(terraform output -raw phase3_conformance_pack_name)"

aws configservice describe-conformance-pack-compliance --conformance-pack-name "$PACK"
aws configservice get-conformance-pack-compliance-details --conformance-pack-name "$PACK"

# Run the periodic detective rule now instead of waiting 24h
aws configservice start-config-rules-evaluation --config-rule-names <detective rule name>

# Remediation history for the reactive rule
aws configservice describe-remediation-execution-status --config-rule-name <reactive rule name>

# Step-by-step runs of the custom remediation document
aws ssm describe-automation-executions \
  --filters Key=DocumentNamePrefix,Values="$(terraform output -raw phase3_remediation_document_name)"
```

Expected: the versioning bucket is `NON_COMPLIANT` (reported only); the Public Access Block bucket goes `NON_COMPLIANT` → remediated → `COMPLIANT` within a few minutes.

**Kafka end-to-end** (run by the pipeline's Integration stage; locally after a deploy):

```bash
export KAFKA_INSTANCE_ID="$(terraform output -raw instance_id)"
export KAFKA_TOPIC_NAME="$(terraform output -raw kafka_topic_name)"
export KAFKA_SECRET_ARN="$(terraform output -raw phase3_secret_arn)"
pytest tests/test_kafka_e2e.py -v
```

Covers: authenticated produce/consume; a client with no credential and one with a wrong password are both rejected; `server.properties` is `600 kafka`; the credential is in neither EC2 user data nor the provisioning logs.

## CI/CD

```text
Pull request to main ─► CodeBuild (validate.yml, no AWS access) ─► status check on the PR

push to main ─► deploy pipeline (Markdown-only pushes are skipped)
  Source       GitHub via CodeConnections
  Validate     fmt, validate, unit tests, conftest verify      role: validate
  Plan         plan -out=tfplan, conftest test                 role: plan (read-only)
  Approve      manual approval, emailed via SNS
  Apply        terraform apply tfplan  (the approved plan)     role: deploy
  Integration  start broker, wait for SSM, Kafka e2e tests     role: integration

Release change (manual) ─► destroy pipeline
  Source ─► PlanDestroy (plan -destroy) ─► Approve ─► Destroy (apply that plan)
```

**Security model**

| Concern | How it is handled |
|---|---|
| No stored credentials | Every job runs under its own CodeBuild role (`pipeline/iam.tf`) |
| Stack roles are capped | Every stack role carries a permissions boundary (`pipeline/boundary.tf`); the deploy role cannot create or change a role without it |
| Pipeline cannot change itself | The deploy role is denied the pipeline's roles, projects, pipelines, key, buckets and topic; `pipeline/` is applied by an administrator |
| Own state only | Plan and deploy can only access this stack's state file and the pipeline artifacts, not other state files in the bucket |
| PR builds | Static checks only, with no AWS access; only PRs from allow-listed GitHub users run |
| Reviewed plan = applied plan | Apply uses the approved `tfplan`; Terraform rejects it if the state changed |
| Supply chain | Terraform and conftest pinned and checksum-verified |

**Known limitations**

- Anyone in the account with `codepipeline:PutApprovalResult` can approve; restricting approvers needs an account-level policy.
- The plan role uses `ReadOnlyAccess`, which can still read some data (for example CloudWatch Logs); only reviewed code from `main` runs with it.
- The boundary allows `s3:PutBucketPublicAccessBlock` on any bucket (S3 cannot scope it by tag); the scope-tag checks decide which buckets change.

**Separate from the original `aws-kafka-sec` stack:** project name `kafka-on-ec2-cp` and state keys under `aws-kafka-sec-codepipeline/`, so no resource is shared.

**Bootstrap (once, by an administrator):**

```bash
cd pipeline
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply -target=aws_codestarconnections_connection.github
#   Console → Developer Tools → Settings → Connections → complete the pending connection
terraform apply
```

1. Confirm the SNS subscription email.
2. Both pipelines run once when created: **reject** the destroy approval; review the deploy Plan log and **approve**.
3. Changes to `pipeline/` are applied by hand (`terraform apply` in `pipeline/`), never by the pipeline.

> Run the destroy pipeline (**Release change**) when finished to avoid EC2 cost.
>
> If Apply fails with **Saved plan is stale**, start a new run with **Release change** instead of **Retry**.

## Cleanup

```bash
export PHASE3_VERSIONING_BUCKET=<bucket>
export PHASE3_REACTIVE_BUCKET=<bucket>
bash scripts/cleanup.sh
```

Then remove the stack with the destroy pipeline (**Release change** → review the PlanDestroy log → approve). To remove the pipeline itself afterwards, run `terraform destroy` in `pipeline/` as an administrator.

## Roadmap

- Three-broker Kafka cluster across three AZs
- TLS (`SASL_SSL`): SCRAM already keeps the password off the wire, but message data is not yet encrypted in transit
- Credential rotation (rotation Lambda that also updates the Kafka SCRAM credential)
