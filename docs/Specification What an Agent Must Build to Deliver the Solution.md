# Specification: What an Agent Must Build to Deliver the Solution

Draft 0.1, 24 November 2026. Companion to the Solution Design (requirements and acceptance criteria) and the Infrastructure Design (diagrams and detail tables). Requirement IDs (FR, LC, SEC, OPS, DEL) and acceptance criteria IDs (AC) refer to the Solution Design.

## 1. How an agent uses this document

This document lists every artifact an agent must create, where it goes, what it takes in, what it produces, and how it is judged. The agent works through the deliverables in the order in section 7.

Rules for the agent:

1. Never invent a value. Every environment-specific value (names, IDs, paths, accounts, sizes) comes from configuration or from a person. A missing value stops the work and is reported as a question.
2. Every deliverable ships with its tests, and each test names the acceptance criterion (AC) it proves.
3. Where a decision is still open (section 3), build behind an interface so the choice can change without rewriting the rest.
4. Everything is idempotent: running it twice changes nothing the second time.
5. No secrets, passwords or keys in the repository, in logs or in outputs. Secrets are referenced by name from Secrets Manager.

## 2. Scope

**Build:** infrastructure templates, a golden image definition, declarative host configuration, lifecycle automation, health and acceptance checks, delivery pipelines, a local test pipeline on the AWS Emulator, and the supporting documentation.

**Do not build:** network design (VPC, subnets, firewall rules) beyond consuming them as parameters; changes to the SSIS packages or reports themselves; the Active Directory itself.

## 3. Open decisions the agent must design around

| ID | Decision | Default the agent builds first | Interface that keeps the choice swappable |
| --- | --- | --- | --- |
| D1 | Configuration tooling (Ansible, WinGet Configuration, SSM documents, custom runner) | Ansible with the Windows collections \[confirm\] | One role or module per concern, driven by the same YAML schema |
| D2 | What triggers SSIS runs once the databases are on RDS | A run wrapper script invoked by a scheduler on the host | Run wrapper takes a package name and returns an exit code, whatever calls it |
| D3 | Install in the image or at every launch | Heavy installs run the same steps in both modes | Each install step is a role that works at image build time and at boot |
| D4 | SQL cluster design (cluster, availability group, both) | Deliver only if the cluster nodes are confirmed to remain (Q2 in the Solution Design) | Cluster deliverable is optional and isolated |
| D5 | Backup target | FSx \[confirm\] | Backup path is a configuration value |
| D6 | Service account type | gMSA where possible | Account name and type come from configuration |
| D7 | Scheduling mechanism | Auto Scaling scheduled action | Schedule expression is a template parameter |

## 4. Repository layout

```
repo/
  infra/            CloudFormation templates and parameter files
  image/            image pipeline definition and media manifest
  config/           YAML schema, defaults, per-environment values
  roles/            one role per concern (base, domain-join, sql, ssis, ssrs, certs, spn, octopus, monitoring)
  scripts/          run wrapper, migrated PowerShell helpers
  lifecycle/        launch and termination hook handlers
  checks/           health and acceptance checks, canary package and job
  pipelines/        GitHub Actions workflows
  emulator/         patches and harness for the AWS Emulator fork
  tests/            unit, integration and end-to-end tests
  docs/             README, runbook, decision records, generated config reference
```

## 5. Deliverables

For each deliverable: what to create, what it takes in, what it produces, and which acceptance criteria it supports.

### 5.1 Infrastructure templates (CloudFormation)

| ID | Deliverable | Takes in | Produces | Supports |
| --- | --- | --- | --- | --- |
| A1 | Host template: launch template, Auto Scaling group, daily scheduled action, launch and termination lifecycle hooks, instance profile attachment | Environment name, image ID, subnets, instance type, schedule expression, min, desired and max capacity, volume layout | Group and hooks, outputs for names and ARNs | FR-01, LC-03, AC-41 |
| A2 | Storage template: FSx for Windows file system, shares for packages and logs (and witness and backups if confirmed), DNS alias, security groups | Capacity, throughput, subnets, directory ID, alias | File system, share paths, alias | FR-05, FR-06, AC-08 |
| A3 | Database template: RDS for SQL Server instance, subnet group, parameter and option groups | Engine version, class, storage, Multi-AZ, subnets | Endpoint, secret for the admin credential | FR-03 |
| A4 | IAM template: instance profile, lifecycle handler role, deployment role for GitHub OIDC | Account and region, secret names, bucket names | Roles with least-privilege policies | SEC-04 |
| A5 | Secrets template: secret definitions only (health check account, domain join account, Octopus access) | Names and rotation settings | Empty secrets with correct names and access policies | SEC-04 |
| A6 | Load balancer template: target group, listener, health check settings for the report server | Certificate ARN, subnets | Load balancer and target group | OPS-02 |
| A7 | Monitoring template: log groups, alarms for hook failures, health check failures and cleanup failures | Notification target | Alarms | OPS-06, LC-10 |
| A8 | Optional: cluster node template \[only if D4 confirms nodes remain\] | Node count, sizes, volumes | Cluster hosts | FR-09 |

Every template: parameters documented, tags applied (environment, owner, purpose), outputs exported, passes cfn-lint, and deploys to an empty account twice with no changes the second time.

### 5.2 Image

| ID | Deliverable | Takes in | Produces | Supports |
| --- | --- | --- | --- | --- |
| B1 | Image pipeline definition (EC2 Image Builder or Packer) | Base Windows image, media manifest, role list | A versioned golden image tagged with the SQL version and build date | D3, NFR-01 |
| B2 | Media manifest: file names, versions, checksums, storage location | Installer sources | Verified media list used by image build and by boot | FR-02 |

### 5.3 Declarative host configuration

| ID | Deliverable | Takes in | Produces | Supports |
| --- | --- | --- | --- | --- |
| C1 | YAML schema and validator covering host role, features, accounts, volumes, certificates, SPNs, registry keys, DNS names, UNC paths and secrets references | Draft schema from this document | Schema file, validator, generated reference page | DEL-02 |
| C2 | Role: Windows base (features, time zone, registry settings, firewall, antivirus exclusions, volume formatting and mounts, patch settings) | Config | Configured host | AC-11 |
| C3 | Role: domain join (OU placement, join, gMSA install, group membership) | Domain, OU, join secret | Joined host | SEC-06, AC-11 |
| C4 | Role: SQL Server install (unattended setup, service accounts, memory, MAXDOP, TempDB layout) targeting SQL Server 2025 | Media, accounts, settings | Installed engine | FR-02, AC-01, AC-02 |
| C5 | Role: SSIS install, run wrapper and logging (dtexec invoked by a wrapper, packages read from the UNC share, logs written to the UNC share, exit codes returned) | Package path, log path, account | Working package execution | FR-04, FR-06, AC-07 |
| C6 | Role: report server install and configuration (Power BI Report Server for 2025): database on RDS, encryption key restore, URL reservations, data sources, scale-out join | Endpoint, key location, URLs, accounts | Working report server in the farm | FR-07, AC-04, AC-05 |
| C7 | Role: certificates (request or fetch, install, bind to services) | Names, issuer, store | Bound certificates | SEC-05, AC-10 |
| C8 | Role: SPNs and delegation (register SPNs, configure constrained delegation where required) | Account names, host and alias names | Correct SPNs | SEC-03, AC-09 |
| C9 | Role: Octopus registration (register on launch, with roles and environment from configuration) | Server URL, access secret, roles | Registered target | LC-01, AC-12 |
| C10 | Role: observability (log and metric agent configuration) | Log paths, counters | Logs and metrics flowing | OPS-06, AC-14 |
| C11 | Migration of the existing PowerShell install scripts: an inventory of every script and what it does, a mapping to roles, and parity tests proving the same end state | The existing scripts | Inventory, mapping table, parity report | DEL-02, AC-42 |

Every role: runs at image build and at boot (D3), reports changed or unchanged, fails with a clear message when a required value is missing.

### 5.4 Lifecycle automation

| ID | Deliverable | Takes in | Produces | Supports |
| --- | --- | --- | --- | --- |
| D1 | Launch hook handler: waits for the health check to pass, then completes the hook as continue, or abandons it and raises an alert | Hook event, health report | Healthy host or replaced host | FR-01, AC-41 |
| D2 | Termination hook handler running the cleanup steps in order (see 5.4.1) | Hook event, host identity | Clean removal or an alert | LC-02 to LC-10, AC-21 to AC-30 |
| D3 | Report server rotation procedure: add the new node, verify it, then retire an old node | Farm state | Rotated farm | FR-08, AC-20 |

#### 5.4.1 Termination cleanup steps

Each step is idempotent, has a timeout and a retry limit, logs what it did, and never blocks termination forever. A failed step raises an alert and the remaining steps still run.

| Order | Step | Verified by |
| --- | --- | --- |
| 1 | Stop accepting new work and wait for running packages to finish (up to the timeout) | AC-29 |
| 2 | Deregister from the load balancer and drain connections | AC-27 |
| 3 | Remove the node from the report server scale-out farm | AC-21 |
| 4 | Deregister from Octopus | AC-23 |
| 5 | Remove SPNs held by the host | AC-25 |
| 6 | Delete DNS records and aliases for the host | AC-26 |
| 7 | Delete or disable the Active Directory computer object | AC-24 |
| 8 | Remove per-host secrets and monitoring entries | AC-28 |
| 9 | Complete the hook | AC-22 |

### 5.5 Health and acceptance checks

| ID | Deliverable | Takes in | Produces | Supports |
| --- | --- | --- | --- | --- |
| E1 | Health check runner covering AC-01 to AC-14: services, version, SQL and report server client connections, authenticated report server check using the Secrets Manager account, one data source connection test, canary job result, smoke-test package, UNC read and write, SPNs, certificates, domain join, Octopus registration, idempotent re-run | Host config, secret names | A JSON report and an exit code | OPS-01 to OPS-04 |
| E2 | Canary package and canary SQL Agent job definitions | None | A package that runs in seconds and a job that records its own success | OPS-04, AC-06 |
| E3 | Termination verification checks covering AC-21 to AC-30 | Host identity | A JSON report | LC-03 to LC-10 |

The health report is the contract between the checks, the launch hook and the pipelines:

```json
{
  "host": "string",
  "environment": "string",
  "timestamp": "ISO 8601",
  "overall": "pass | fail",
  "checks": [
    { "id": "AC-04", "name": "report server client connection", "result": "pass | fail | skipped", "detail": "string", "durationMs": 0 }
  ]
}
```

### 5.6 Delivery pipelines (GitHub Actions)

| ID | Deliverable | Takes in | Produces | Supports |
| --- | --- | --- | --- | --- |
| F1 | Validation workflow: schema validation, template lint, script and role linting, unit tests | Pull request | Pass or fail | DEL-02 |
| F2 | Deployment workflow: assume the deployment role through OIDC, deploy the CloudFormation stacks, wait for the health report | Environment, image ID | Deployed environment | DEL-01, AC-40 |
| F3 | Mock workflow for the first end-to-end proof: deploy a template with an Auto Scaling group and one instance running the SQL engine, SSIS and the report server, targeting SQL Server 2025 | Test environment | A working instance and a report | DEL-01 |
| F4 | Environment matrix: the same definition built for environments A, B, C and D | Per-environment values | Four environments from one definition | FR-10, AC-44 |

### 5.7 Local test pipeline (AWS Emulator)

| ID | Deliverable | Takes in | Produces | Supports |
| --- | --- | --- | --- | --- |
| G1 | Fork of the AWS Emulator pinned to a commit, with the EC2 changes: create a Windows container on instance launch, map image IDs to container images, run user data inside the container, report state from the container, remove the container on termination, reconcile labelled containers on start | Emulator source | A patched emulator that builds on Windows | DEL-03 |
| G2 | Image mapping configuration (fake image ID to Windows container image) | Container image names | Mapping file | DEL-03 |
| G3 | Test harness: start the emulator, seed emulated S3 with media, create secrets, launch the instance, wait for the install, run the health checks, terminate, tear down | Config | An end-to-end run with a pass or fail result | AC-43 |
| G4 | Evaluation suite run to prove the patches did not break existing EC2 behaviour | Emulator evaluation suite | Test report | DEL-03 |

The emulator mocks clustering, FSx, domain join and Kerberos. Checks that depend on them are marked skipped in the emulator and run for real on AWS.

### 5.8 Documentation

| ID | Deliverable | Contents |
| --- | --- | --- |
| H1 | README | What this is, prerequisites, how to build, test and deploy |
| H2 | Decision records | One short record per open decision D1 to D7, with the chosen option and the reason |
| H3 | Runbook | Daily operation, failure handling, manual recovery for each lifecycle step |
| H4 | Config reference | Generated from the schema in C1 |
| H5 | Traceability matrix | Every requirement and acceptance criterion mapped to the deliverable and test that proves it |

## 6. Conventions and contracts

| Item | Rule |
| --- | --- |
| Naming | \[Pattern for stacks, hosts, secrets, parameters, log groups\] |
| Tags | Environment, owner, purpose, and a build identifier on every resource |
| Secrets | Referenced by name only. Never printed. Names follow \[pattern\] |
| Exit codes | 0 pass, 1 check failed, 2 configuration error, 3 unexpected error |
| Logging | One structured line per action with host, step, result and duration |
| Configuration | One YAML schema. Defaults in the repo, environment values supplied at deployment |
| Idempotency | Every role, script and hook handler reports changed or unchanged and is safe to rerun |
| Time limits | Every wait has a timeout from configuration. No unbounded waits |

## 7. Build order

1. C1 configuration schema and H2 decision records for D1 to D7.
2. G1 to G4 local pipeline, with a stub installer, so every later step can be tested without AWS.
3. C2 and C4 to C6 base, SQL, SSIS and report server roles, proven in the emulator.
4. E1 and E2 health checks and canary, run against the emulator host.
5. C11 migration of the existing PowerShell scripts with parity tests.
6. A1 to A7 infrastructure templates, and F1 validation workflow.
7. B1 and B2 image pipeline.
8. C3, C7 to C10 identity, certificates, SPNs, Octopus and monitoring roles, tested on real AWS.
9. D1 to D3 lifecycle automation and E3 termination checks.
10. F2 to F4 deployment workflows, then the mock workflow and the environment matrix.
11. H1, H3 to H5 documentation and the traceability matrix.

## 8. Definition of done (for every deliverable)

- [ ] Built from configuration with no hard-coded environment values
- [ ] Tests exist and each names the acceptance criterion it proves
- [ ] Passes twice in a row, the second run reporting no changes
- [ ] No secrets in code, logs or outputs
- [ ] Failure messages say what is missing and what to do
- [ ] Documented in the README or runbook and listed in the traceability matrix

## 9. Inputs the agent needs from people

| Input | From | Blocks |
| --- | --- | --- |
| Decisions D1 to D7 | Delivery owner | C-series roles, A1, A8, B1 |
| Where SQL Agent runs once all databases are on RDS | Delivery owner | C5, E2 |
| What the SQL cluster nodes still host | Delivery owner | A8, C4 |
| Backup target (FSx to be confirmed) | Delivery owner | A2, C4 |
| Domain, OU paths, join account, permissions for computer object and DNS cleanup | Active Directory owners | C3, C8, D2 |
| Octopus server URL, roles, environments and access secret | Octopus owners | C9, D2 |
| Certificate issuer and process | Certificate owners | C7 |
| SQL Server 2025 media location and licensing | Licensing owner | B2, C4 |
| Existing PowerShell scripts | Delivery owner | C11 |
| Package path, log path and FSx alias | Delivery owner | A2, C5 |
| Environment values for A, B, C and D | Delivery owner | F4 |

## 10. Change log

| Version | Date | Author | Change |
| --- | --- | --- | --- |
| 0.1 | 24 November 2026 | \[ \] | First draft |
