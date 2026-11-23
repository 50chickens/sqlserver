# Solution Design: SQL Server, SSIS and SSRS Hosting on AWS

Draft 0.1, 24 November 2026. Companion to the Infrastructure Design document, which holds the diagrams and the detailed fill-in tables.

How to read this document: requirements marked **Stated** came from you; those marked **Proposed** are my suggestions for you to accept, change or drop. Anything in \[brackets\] still needs a decision or a value.

## 1. Purpose

This document defines what the solution must do (requirements), how it will be built (specifications), how delivery will be judged (acceptance criteria), how the move will happen (migration strategy), and which other documents are needed to deliver it successfully.

## 2. Background and current state

| Area | Current state |
| --- | --- |
| Servers | Three regular Windows EC2 servers, not autoscaled. Each has the SQL engine. |
| Application databases | On the first two servers. |
| SSIS and SSRS | On the third server, together with the SSIS-related and SSRS databases and SQL Agent. |
| SSIS execution | A SQL Agent job calls a PowerShell script, which calls dtexec. |
| Package storage | .dtsx files on a shared UNC path used by several clustered SQL instances. Logs are written to a UNC path. |
| Identity | Active Directory backs all SQL instances. |
| Environments | The setup is duplicated per environment. |
| Installation | A set of PowerShell scripts performs the installs. |

## 3. Goals and non-goals

**Goals**

- Move all SQL databases to Amazon RDS for SQL Server.
- Keep the SQL Agent and SSRS services on Windows EC2 hosts that are rebuilt automatically on a schedule.
- Replace the PowerShell install scripts with declarative, YAML-based tooling.
- Make host rebuild, registration and termination cleanup fully automatic.
- Prove the pipeline end to end locally before using real AWS.

**Non-goals** \[confirm\]

- Redesigning the SSIS packages or reports themselves.
- Network design (CIDR plan, firewall rules), except where a requirement depends on it.
- Autoscaling inside the AWS Emulator. The real AWS implementation handles scaling.

## 4. Requirements

### 4.1 Functional

| ID | Requirement | Source |
| --- | --- | --- |
| FR-01 | Hosts for the SQL Agent and SSRS services are rebuilt on a daily schedule using an Auto Scaling group. | Stated |
| FR-02 | Each new host installs and configures the SQL engine, SSIS and SSRS features automatically. The target is SQL Server 2025, where SSRS is now Power BI Report Server. | Stated |
| FR-03 | All SQL databases, including the SSIS and SSRS databases, are hosted on RDS for SQL Server. | Stated |
| FR-04 | SSIS packages still run through a job that calls PowerShell and then dtexec, on a Windows EC2 host. \[Confirm where the Agent runs, because RDS cannot run PowerShell or command-line job steps.\] | Stated, open item |
| FR-05 | The .dtsx files live on a shared UNC path that every clustered instance can reach, including after a failover. | Stated |
| FR-06 | SSIS log files are written to a UNC path. | Stated |
| FR-07 | SSRS runs as a scale-out farm, for example two nodes. | Stated |
| FR-08 | A report server node is rotated by building a new node first, then retiring an old one. | Stated |
| FR-09 | The design supports a SQL cluster, possibly availability groups, a file share witness and possibly AWS FSx. | Stated |
| FR-10 | The whole setup is repeatable per environment (A, B, C, D). | Stated |

### 4.2 Lifecycle

| ID | Requirement | Source |
| --- | --- | --- |
| LC-01 | Instances hosting the SQL engine, SSRS or SSIS register with the Octopus server on launch. | Stated |
| LC-02 | The same instances deregister from Octopus on termination. | Stated |
| LC-03 | A termination lifecycle hook runs on report server instances and removes the retiring node from the scale-out farm. | Stated |
| LC-04 | On termination, the Active Directory computer object is cleaned up. | Stated |
| LC-05 | On termination, SPNs held by the host are removed. | Stated |
| LC-06 | On termination, DNS records and aliases for the host are removed. | Stated |
| LC-07 | On termination, the host is deregistered from the load balancer after connections drain. | Stated |
| LC-08 | On termination, per-host secrets and monitoring entries are cleaned up. | Stated |
| LC-09 | Termination waits for running SSIS packages before proceeding. | Proposed |
| LC-10 | If cleanup fails or times out, an alert is raised and termination is not blocked forever. | Proposed |

### 4.3 Identity and security

| ID | Requirement | Source |
| --- | --- | --- |
| SEC-01 | Domain accounts are used for all services instead of local service accounts or SQL logins. | Stated |
| SEC-02 | Each service (engine, Agent, SSRS, SSIS execution) has its own account. \[gMSA where possible.\] | Proposed |
| SEC-03 | Kerberos works end to end: SPNs registered for SQL, SSRS and the file share, with constrained delegation where SSRS passes identity on. | Stated |
| SEC-04 | The health check service account credentials are stored in Secrets Manager. | Stated |
| SEC-05 | TLS certificates are installed, trusted and renewed for SQL, SSRS and the load balancer. | Stated |
| SEC-06 | Domain join, OU placement and group policy are defined for every host role. | Stated |

### 4.4 Operations

| ID | Requirement | Source |
| --- | --- | --- |
| OPS-01 | Health checks confirm service availability on every host. | Stated |
| OPS-02 | The SSRS health check works without anonymous access: it authenticates with the Secrets Manager service account and tests one connection. A 401 on the report server URL is treated as proof the service is alive. | Stated |
| OPS-03 | Client connections are verified at both the SQL server and the report server. | Stated |
| OPS-04 | A SQL Agent canary job runs and its execution is verified. | Stated |
| OPS-05 | SQL backups go to FSx. \[To be confirmed.\] | Stated, to confirm |
| OPS-06 | Logs and metrics from every host reach central monitoring. | Proposed |

### 4.5 Delivery

| ID | Requirement | Source |
| --- | --- | --- |
| DEL-01 | A mock GitHub Actions workflow deploys a CloudFormation template that creates an Auto Scaling group and an EC2 instance running the SQL engine, SSIS and SSRS features, targeting SQL Server 2025. | Stated |
| DEL-02 | The PowerShell install scripts are converted to declarative YAML-based tooling. \[Tooling to be chosen: Ansible was recommended, WinGet Configuration was considered.\] | Stated, open item |
| DEL-03 | A local pipeline uses the AWS Emulator, with a patched EC2 service that starts a Windows Server Core container, and runs the SSIS and SSRS install inside it. | Stated |

### 4.6 Non-functional

| ID | Requirement | Target |
| --- | --- | --- |
| NFR-01 | Time from scale-out to a healthy, registered host | \[ \] |
| NFR-02 | Failover time (RTO) and data loss (RPO) | \[ \] |
| NFR-03 | Installs and cleanup are idempotent: re-running changes nothing | Proposed |
| NFR-04 | Cost ceiling per environment per month | \[ \] |

## 5. Solution overview

The solution has six parts. Detailed diagrams are in the Infrastructure Design document.

1. **Data tier:** RDS for SQL Server hosts all databases.
2. **Compute tier:** Windows EC2 hosts in an Auto Scaling group run the SQL Agent, SSIS and SSRS features, rebuilt daily from a golden image plus a thin bootstrap.
3. **Shared files:** FSx for Windows provides the UNC share for packages and logs, and possibly the cluster witness and backups.
4. **Identity:** Active Directory provides domain join, service accounts, Kerberos and DNS.
5. **Lifecycle automation:** Launch and termination hooks register and deregister each host in Octopus, the SSRS farm, the load balancer, AD and DNS.
6. **Delivery pipeline:** GitHub Actions deploys CloudFormation. Declarative configuration replaces the PowerShell scripts. The AWS Emulator proves the pipeline locally.

### Key decisions

| # | Decision | Options | Status |
| --- | --- | --- | --- |
| D1 | Configuration tooling | Ansible, WinGet Configuration, SSM documents, custom runner | \[Open\] |
| D2 | How packages are triggered once the databases are on RDS | Task Scheduler, SSM Run Command, EventBridge, SQL Agent on EC2 | \[Open\] |
| D3 | Image strategy | Golden image with thin bootstrap, or install at every launch | \[Open\] |
| D4 | SQL cluster design | Failover cluster instance, availability group | \[Open\] |
| D5 | Backup target | FSx, S3 | \[To confirm: FSx\] |
| D6 | Service account type | gMSA, standard accounts | \[Open\] |
| D7 | Scheduling mechanism | Auto Scaling scheduled actions, EventBridge Scheduler | \[Open\] |

## 6. Specifications

Each area below needs concrete values before build. The detailed tables are in the Infrastructure Design document.

| Area | Specification needed | Where detailed |
| --- | --- | --- |
| Compute | Instance types, sizes, AMI, placement | Infrastructure Design, section 4 |
| Storage | EBS layout, FSx size and shares, mounts | Infrastructure Design, section 5 |
| Cluster | Nodes, quorum, listener, witness | Infrastructure Design, section 6 |
| RDS | Version, class, storage, Multi-AZ, option groups | Infrastructure Design, section 7 |
| SSIS | Execution account, packages path, log path, drivers | Infrastructure Design, section 8 |
| SSRS | Farm size, key handling, URLs, data sources | Infrastructure Design, section 9 |
| Identity | Accounts, SPNs, delegation, domain join | Infrastructure Design, section 10 |
| Certificates and DNS | Certificates, records, aliases | Infrastructure Design, sections 11 and 12 |
| Windows | Features, registry keys, patching | Infrastructure Design, section 13 |
| Rebuild automation | Image pipeline, schedule, hooks | Infrastructure Design, section 14 |
| Test pipeline | Emulator fork, image mapping | Infrastructure Design, section 15 |
| Registration | Octopus roles, environments, tentacle setup | \[To write\] |

## 7. Acceptance criteria

### 7.1 Per host (after every build)

| ID | Criterion | How it is tested | Requirement |
| --- | --- | --- | --- |
| AC-01 | Engine, Agent, SSRS and SSIS services are running with the correct startup type | Service query in the build script | OPS-01 |
| AC-02 | The SQL version matches the expected build | Version query | FR-02 |
| AC-03 | A client connection succeeds at the SQL server, with TLS enforced | Test connection | OPS-03, SEC-05 |
| AC-04 | A client connection succeeds at the report server | Authenticated request with the Secrets Manager account | OPS-02, OPS-03 |
| AC-05 | One report data source connection test passes | Report server connection test | OPS-02 |
| AC-06 | A SQL Agent canary job runs and its history shows success | Job history check | OPS-04 |
| AC-07 | A smoke-test package runs with dtexec and writes its log to the UNC share | Package run, then log file check | FR-04, FR-06 |
| AC-08 | Packages are readable from the UNC share, before and after a failover | Read test, failover test | FR-05 |
| AC-09 | Service accounts, SPNs and Kerberos delegation are correct | SPN query, Kerberos connection test | SEC-01, SEC-03 |
| AC-10 | Certificates are valid and bound to the services | Certificate and binding check | SEC-05 |
| AC-11 | The host is domain joined in the correct OU | Directory query | SEC-06 |
| AC-12 | The host is registered in Octopus | Octopus target list | LC-01 |
| AC-13 | Re-running the build changes nothing | Second run reports no changes | NFR-03 |
| AC-14 | Logs and metrics reach central monitoring | Monitoring query | OPS-06 |

### 7.2 Rotation and termination

| ID | Criterion | How it is tested | Requirement |
| --- | --- | --- | --- |
| AC-20 | A new report server node joins the farm and passes AC-04 before an old node is retired | Rotation test | FR-08 |
| AC-21 | The retiring node is absent from the farm's scale-out keys list | Farm membership check | LC-03 |
| AC-22 | The termination hook ran before the instance was destroyed | Lifecycle hook history | LC-03 |
| AC-23 | The node is deregistered from Octopus | Octopus target list | LC-02 |
| AC-24 | The computer object is gone from AD | Directory query | LC-04 |
| AC-25 | No SPNs remain for the host | SPN query | LC-05 |
| AC-26 | No DNS records or aliases remain for the host | DNS query | LC-06 |
| AC-27 | The load balancer target is removed after draining | Load balancer target list | LC-07 |
| AC-28 | No per-host secrets or monitoring entries remain | Secrets and monitoring queries | LC-08 |
| AC-29 | A package running at termination time completes before shutdown | Test with a long-running package | LC-09 |
| AC-30 | A failed cleanup step raises an alert and does not block termination indefinitely | Fault-injection test | LC-10 |

### 7.3 Pipeline and delivery

| ID | Criterion | How it is tested | Requirement |
| --- | --- | --- | --- |
| AC-40 | The GitHub Actions workflow deploys the CloudFormation template and produces a working instance | Workflow run | DEL-01 |
| AC-41 | The daily schedule scales out and replaces hosts without manual steps | Observed scheduled run | FR-01 |
| AC-42 | The declarative configuration reproduces what the PowerShell scripts did | Side-by-side comparison | DEL-02 |
| AC-43 | The local emulator pipeline creates a Windows container and the SSIS and SSRS install completes inside it | Local end-to-end run | DEL-03 |
| AC-44 | Each environment (A to D) can be built from the same definition | Build in a second environment | FR-10 |

### 7.4 Migration

| ID | Criterion | How it is tested | Requirement |
| --- | --- | --- | --- |
| AC-50 | Every database is on RDS with row counts and checksums matching the source | Data comparison | FR-03 |
| AC-51 | Every SSIS package runs successfully against RDS | Full package run | FR-03, FR-04 |
| AC-52 | Every report renders correctly against the migrated data | Report comparison | FR-03 |
| AC-53 | Backups run to the agreed target and a restore is proven | Restore test | OPS-05 |
| AC-54 | Rollback has been rehearsed and meets the agreed time | Rollback rehearsal | \[Cutover plan\] |

## 8. Migration strategy (summary)

The full strategy belongs in its own document. The outline below sets the shape.

| Phase | Main activities | Exit criteria |
| --- | --- | --- |
| 0. Discovery | Inventory databases, jobs, packages, reports, accounts, SPNs, certificates, linked servers and dependencies. Check each against RDS limits. | Inventory signed off, gaps listed |
| 1. Foundation | Build AD integration, FSx, RDS, image pipeline, secrets and base IAM. | Foundation passes AC-09 to AC-11 |
| 2. Automation | Convert PowerShell to declarative configuration. Prove it in the emulator, then deploy with GitHub Actions and CloudFormation. | AC-40 to AC-44 pass in a test environment |
| 3. Data migration | Move databases to RDS using the agreed method. \[Backup and restore, DMS or other.\] Decide how SSISDB and ReportServer move. | AC-50 passes in rehearsal |
| 4. Parallel run | Run old and new side by side. Compare package and report results. | AC-51 and AC-52 pass |
| 5. Cutover | Freeze, final sync, switch connections and DNS, run acceptance tests. | All acceptance criteria pass |
| 6. Decommission | Retire old servers, clean up AD, DNS and backups. | Old estate removed, cleanup verified |

Rollback is defined for each phase, with a point of no return named before cutover.

## 9. Risks, assumptions and dependencies

| # | Item | Type | Mitigation or note |
| --- | --- | --- | --- |
| R1 | RDS cannot run PowerShell or command-line SQL Agent steps, so the current job chain cannot move as is | Risk | Decide D2 early |
| R2 | SSISDB and ReportServer migration to RDS may not be a straight copy | Risk | Test in discovery |
| R3 | SQL Server 2025 tooling support is newer, and community Ansible coverage for SSRS and SSIS is thinner than for the engine | Risk | Prove early with the emulator and a test environment |
| R4 | Windows container behavior may differ from a real EC2 host (no cluster, domain or Kerberos) | Risk | Treat those areas as mocked in the emulator and test them on real AWS |
| R5 | Kerberos or SPN mistakes cause silent fallback to NTLM or failed delegation | Risk | AC-09 on every build |
| R6 | Termination cleanup partly fails, leaving stale AD, DNS or farm entries | Risk | LC-10, AC-30 |
| A1 | The AWS Emulator can be patched for a Windows host and supports the EC2 calls needed | Assumption | Verify in the repository |
| A2 | The backup target is FSx | Assumption | Confirm with D5 |
| A3 | The existing AD is reachable from AWS and allows computer object creation and deletion by automation | Assumption | Confirm with the AD owners |
| DP1 | Octopus server availability and API access for registration | Dependency | \[Owner\] |
| DP2 | AD, DNS and certificate authority teams | Dependency | \[Owners\] |

## 10. Companion documents

These documents together make delivery successful. The first group is needed before build starts.

| Document | Purpose | Needed by | Owner |
| --- | --- | --- | --- |
| Infrastructure Design | Diagrams and detailed specification tables | Before build | \[ \] |
| Migration Strategy and Plan | Phases, method, sequencing, dependencies, rollback | Before build | \[ \] |
| Architecture Decision Records | One short record per open decision (D1 to D7) | Before build | \[ \] |
| Configuration Specification | Schema and values for the YAML-based tooling | Before build | \[ \] |
| Identity and Access Design | AD, gMSA, SPNs, delegation, IAM roles, secrets | Before build | \[ \] |
| Test Strategy and Plan | How each acceptance criterion is run, environments, data | Before build | \[ \] |
| Deployment Design | GitHub Actions, CloudFormation, Octopus registration flow | Before build | \[ \] |
| Cutover and Rollback Plan | Step-by-step cutover, go and no-go checks, rollback | Before cutover | \[ \] |
| Backup, Restore and DR Plan | Backup targets, retention, restore tests, RPO and RTO | Before cutover | \[ \] |
| Monitoring and Alerting Design | Health checks, canary job, alarms, dashboards | Before cutover | \[ \] |
| Operations Runbook | Daily operation, failure handling, manual recovery steps | Before cutover | \[ \] |
| Capacity, Cost and Licensing Review | Instance sizing, SQL licensing, monthly cost | Before build | \[ \] |
| Risk and Issue Log | Live risks, issues and decisions | Throughout | \[ \] |
| Decommission Plan | Retiring old servers and cleaning up AD, DNS and backups | After cutover | \[ \] |
| Handover and Training Notes | What operators need to know to run it | After cutover | \[ \] |

## 11. Change log

| Version | Date | Author | Change |
| --- | --- | --- | --- |
| 0.1 | 24 November 2026 | \[ \] | First draft built from the requirements discussed so far |
