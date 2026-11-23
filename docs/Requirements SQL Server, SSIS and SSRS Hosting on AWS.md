# Requirements: SQL Server, SSIS and SSRS Hosting on AWS

Draft 0.1, 24 November 2026. Each requirement has its own acceptance criteria, so a requirement is done only when every one of its criteria passes. IDs match the Solution Design.

How to read it: **Stated** means you gave the requirement; **Proposed** means I suggest it for you to accept or drop. Priority is Must, Should or Could. Values in \[brackets\] still need a decision.

## 1. Purpose and scope

This document states what the solution must do and how each requirement will be proven. It covers hosting SQL Server, SSIS and SSRS on AWS with automatic rebuild of the hosts, the move of all databases to RDS, identity and lifecycle cleanup, operations, and delivery tooling.

Out of scope: network design (VPC, subnets, firewall rules), changes to SSIS packages or reports, and building the Active Directory itself.

## 2. Context and constraints

| Item | Detail |
| --- | --- |
| Current estate | Three regular Windows EC2 servers, each with the SQL engine. Application databases on the first two. The third holds the SSIS and SSRS databases and runs SSIS, SSRS and SQL Agent. |
| SSIS execution today | A SQL Agent job calls a PowerShell script, which calls dtexec. |
| Package storage | .dtsx files and logs on a shared UNC path used by several clustered SQL instances. |
| Target | All databases on RDS for SQL Server. SQL Agent and SSRS services stay on Windows EC2 hosts that are rebuilt automatically. |
| Version | SQL Server 2025. SSRS in 2025 is Power BI Report Server. |
| Identity | Active Directory backs all SQL instances. |
| Environments | The whole setup is duplicated per environment (A, B, C, D). |
| Constraint | RDS cannot run PowerShell or command-line SQL Agent job steps, so the current job chain cannot move to RDS unchanged. |

## 3. Stakeholders

| Role | Responsibility | Name |
| --- | --- | --- |
| Delivery owner | Accepts requirements and signs off | \[ \] |
| Database administrators | SQL, RDS, backups, SSIS | \[ \] |
| Platform engineers | AWS, images, pipelines | \[ \] |
| Active Directory owners | Domain join, accounts, SPNs, DNS | \[ \] |
| Octopus owners | Registration and deployment targets | \[ \] |
| Security | Certificates, secrets, access | \[ \] |
| Operations | Runbooks, monitoring, on-call | \[ \] |

## 4. Definitions

| Term | Meaning |
| --- | --- |
| Host | A Windows EC2 instance running SQL Agent, SSIS or SSRS features |
| Healthy | The host passes every applicable check in the per-host acceptance list in section 7 |
| Lifecycle hook | An Auto Scaling step that pauses a launch or termination so code can run first |
| gMSA | Group managed service account, a domain account whose password Active Directory manages |
| SPN | Service principal name, the Kerberos identity a service registers in Active Directory |
| UNC share | A network file path such as a file server share, here provided by FSx |
| Scale-out farm | Several report server nodes sharing one report server database |

## 5. Assumptions and dependencies

| # | Item | Type |
| --- | --- | --- |
| A1 | Active Directory is reachable from AWS and allows automation to create and delete computer objects and DNS records | Assumption |
| A2 | A VPC, subnets and firewall rules already exist | Assumption |
| A3 | The backup target is FSx | Assumption, to confirm |
| A4 | SQL Server 2025 media and licences are available | Assumption |
| DP1 | The Octopus server is reachable and offers an API for registration | Dependency |
| DP2 | Certificate issuer and process are available | Dependency |

## 6. Requirements and acceptance criteria

### 6.1 Hosting and data

| ID | Requirement | Priority | Source | Acceptance criteria |
| --- | --- | --- | --- | --- |
| FR-01 | Hosts for the SQL Agent and SSRS services are rebuilt on a daily schedule using an Auto Scaling group. | Must | Stated | Given the daily schedule, when the window starts, then new hosts launch with no manual action and are healthy within \[NFR-01\]. Old hosts are retired only after the new ones are healthy. |
| FR-02 | Each new host installs and configures the SQL engine, SSIS and SSRS features automatically, targeting SQL Server 2025. | Must | Stated | No manual step is needed. The version query returns the expected 2025 build. Engine, Agent, SSIS and report server services are running with the correct startup type. A second run changes nothing. |
| FR-03 | All SQL databases, including the SSIS and SSRS databases, are hosted on RDS for SQL Server. | Must | Stated | No user database remains on an EC2-hosted instance. Row counts and checksums match the source. Every connection string uses the RDS endpoint or its alias. |
| FR-04 | SSIS packages run through a job that calls PowerShell and then dtexec, on a Windows EC2 host. | Must | Stated | The smoke-test package exits with code 0. The job history shows success. The package reads and writes RDS databases. \[Where the Agent runs is an open question, Q1.\] |
| FR-05 | The .dtsx files live on a shared UNC path that every clustered instance can reach, including after a failover. | Must | Stated | The path is readable from every node. After a forced failover, the same path is readable again within \[N seconds\]. |
| FR-06 | SSIS log files are written to a UNC path. | Must | Stated | After a run, a log file with entries for that run exists on the share. The write works as the execution account after a failover. |
| FR-07 | SSRS runs as a scale-out farm, for example two nodes. | Must | Stated | The farm lists the expected node count. A request through the load balancer renders a report from either node. Stopping one node leaves the service available. |
| FR-08 | A report server node is rotated by building a new node first, then retiring an old one. | Must | Stated | The farm never drops below \[N\] healthy nodes during rotation. The new node passes its health checks before the old one is retired. The old node is absent from the farm afterwards. |
| FR-09 | The design supports a SQL cluster, possibly availability groups, a file share witness and possibly FSx. | Must | Stated | \[If confirmed, Q2.\] Cluster validation passes. The witness is reachable. A failover completes within \[NFR-02\]. The listener or cluster name resolves to the active node. |
| FR-10 | The setup is repeatable per environment. | Must | Stated | Environments A, B, C and D are built from one definition, differing only in configuration values. |

### 6.2 Lifecycle

| ID | Requirement | Priority | Source | Acceptance criteria |
| --- | --- | --- | --- | --- |
| LC-01 | Hosts running the SQL engine, SSRS or SSIS register with the Octopus server on launch. | Must | Stated | The target appears in Octopus with the expected roles and environment within \[N minutes\] of launch. |
| LC-02 | The same hosts deregister from Octopus on termination. | Must | Stated | The target is gone from Octopus before the instance is destroyed. |
| LC-03 | A termination lifecycle hook on report server hosts removes the node from the scale-out farm. | Must | Stated | The hook runs before the instance is destroyed. The node is absent from the farm's scale-out keys list afterwards. |
| LC-04 | The Active Directory computer object is cleaned up on termination. | Must | Stated | A directory lookup for the host returns nothing. |
| LC-05 | SPNs held by the host are removed on termination. | Must | Stated | An SPN query for the host returns nothing. |
| LC-06 | DNS records and aliases for the host are removed on termination. | Must | Stated | Forward records, reverse records and aliases for the host no longer resolve. |
| LC-07 | The host is deregistered from the load balancer after connections drain. | Must | Stated | The target is removed. No in-flight request is dropped within the drain time of \[N seconds\]. |
| LC-08 | Per-host secrets and monitoring entries are cleaned up on termination. | Must | Stated | No per-host secret, alarm, dashboard entry or agent registration remains. |
| LC-09 | Termination waits for running SSIS packages. | Should | Proposed | A package running when termination starts finishes before shutdown, or the timeout of \[N minutes\] expires and an alert is raised. |
| LC-10 | If cleanup fails or times out, an alert is raised and termination is not blocked forever. | Should | Proposed | With a cleanup step forced to fail, an alert is raised and termination completes within \[N minutes\]. |

### 6.3 Identity and security

| ID | Requirement | Priority | Source | Acceptance criteria |
| --- | --- | --- | --- | --- |
| SEC-01 | Domain accounts are used for all services instead of local service accounts or SQL logins. | Must | Stated | No service runs as a local account. No SQL authentication login is in use except documented exceptions. Windows-authenticated connections succeed. |
| SEC-02 | Each service has its own account, using gMSAs where possible. | Should | Proposed | Each of engine, Agent, report server and SSIS execution shows a distinct account. |
| SEC-03 | Kerberos works end to end, with SPNs for SQL, the report server and the file share, and constrained delegation where the report server passes identity on. | Must | Stated | Connections to SQL, the report server and the share use Kerberos, not NTLM. The delegation test (report server to SQL and to the share) passes. |
| SEC-04 | Health check service account credentials are stored in Secrets Manager. | Must | Stated | No credential appears in code, logs or configuration. The check reads the secret at run time. Only the host profile can read it. |
| SEC-05 | TLS certificates are installed, trusted and renewed for SQL, the report server and the load balancer. | Must | Stated | Each certificate is valid, trusted, bound to its service and has at least \[N days\] to expiry. TLS is enforced on SQL connections. |
| SEC-06 | Domain join, OU placement and group policy are defined for every host role. | Must | Stated | Each host is in its expected OU and the expected group policies are applied. |

### 6.4 Operations

| ID | Requirement | Priority | Source | Acceptance criteria |
| --- | --- | --- | --- | --- |
| OPS-01 | Health checks confirm service availability on every host. | Must | Stated | The health report shows overall pass for the host. |
| OPS-02 | The report server health check works without anonymous access: it authenticates with the Secrets Manager account and tests one connection. | Must | Stated | The authenticated request returns 200 and one data source connection test passes. An unauthenticated request returns 401, which counts as the service being alive. |
| OPS-03 | Client connections are verified at both the SQL server and the report server. | Must | Stated | A test connection succeeds at each. |
| OPS-04 | A SQL Agent canary job runs and its execution is verified. | Must | Stated | The job ran within the current build window and its history shows success. A failed or missing run raises an alert. |
| OPS-05 | SQL backups go to FSx \[to be confirmed\]. | Should | Stated, to confirm | A scheduled backup completes to the target. A restore to a scratch database succeeds. Retention is \[N days\]. |
| OPS-06 | Logs and metrics from every host reach central monitoring. | Should | Proposed | Logs and metrics for the host are queryable within \[N minutes\] of launch. |

### 6.5 Delivery

| ID | Requirement | Priority | Source | Acceptance criteria |
| --- | --- | --- | --- | --- |
| DEL-01 | A mock GitHub Actions workflow deploys a CloudFormation template with an Auto Scaling group and an EC2 instance running the SQL engine, SSIS and SSRS features, targeting SQL Server 2025. | Must | Stated | The workflow succeeds. The stack creates the group and one instance. The health report passes. The stack deletes cleanly. |
| DEL-02 | The existing PowerShell install scripts are converted to declarative YAML-based tooling. | Must | Stated | Every existing script is inventoried and mapped. The end state matches what the scripts produced. No install logic remains in PowerShell except the run wrapper and helpers \[confirm\]. |
| DEL-03 | A local pipeline uses the AWS Emulator, with a patched EC2 service that starts a Windows Server Core container, and runs the SSIS and SSRS install inside it. | Must | Stated | A launch call against the emulator creates a Windows container. The install completes inside it. Every check that does not need a cluster, domain or Kerberos passes. A terminate call removes the container. |

### 6.6 Non-functional

| ID | Requirement | Priority | Source | Acceptance criteria |
| --- | --- | --- | --- | --- |
| NFR-01 | Time from scale-out to a healthy, registered host is within \[N minutes\]. | Should | Proposed | Measured over \[N\] runs, the 95th percentile is within the target. |
| NFR-02 | Failover completes within RTO \[N\] with data loss within RPO \[N\]. | Should | Proposed | A failover test meets both values. |
| NFR-03 | Installs and cleanup are idempotent. | Must | Proposed | A second run reports no changes. |
| NFR-04 | Monthly cost per environment stays within \[amount\]. | Could | Proposed | The monthly cost report is within the ceiling. |

## 7. Per-host acceptance list

Every host must pass this list after each build. Each item links back to the requirements above.

- [ ] Engine, Agent, report server and SSIS services are running with the correct startup type (FR-02, OPS-01)
- [ ] SQL version matches the expected 2025 build (FR-02)
- [ ] A client connection to the SQL server succeeds with TLS (OPS-03, SEC-05)
- [ ] An authenticated report server request returns 200 and one data source test passes (OPS-02)
- [ ] The SQL Agent canary job ran and succeeded (OPS-04)
- [ ] The smoke-test package runs and its log lands on the UNC share (FR-04, FR-06)
- [ ] Packages are readable from the share, before and after failover (FR-05)
- [ ] Service accounts, SPNs and delegation are correct (SEC-01, SEC-03)
- [ ] Certificates are valid and bound (SEC-05)
- [ ] The host is domain joined in the correct OU (SEC-06)
- [ ] The host is registered in Octopus (LC-01)
- [ ] Logs and metrics reach monitoring (OPS-06)
- [ ] A second run changes nothing (NFR-03)

## 8. Acceptance process

1. Each criterion is tested by an automated check wherever possible, and the result is recorded as evidence.
2. A requirement passes only when all of its criteria pass.
3. Every Must requirement must pass in every environment before go-live.
4. A Should or Could requirement may be waived only with a recorded decision from the delivery owner.
5. Checks that depend on a cluster, domain or Kerberos are skipped in the emulator and must pass on real AWS.

| Role | Name | Date | Decision |
| --- | --- | --- | --- |
| Delivery owner | \[ \] | \[ \] | \[ \] |
| Database administrators | \[ \] | \[ \] | \[ \] |
| Security | \[ \] | \[ \] | \[ \] |
| Operations | \[ \] | \[ \] | \[ \] |

## 9. Open questions

| # | Question | Affects |
| --- | --- | --- |
| Q1 | Where does SQL Agent run once all databases are on RDS, given RDS cannot run PowerShell or command-line steps? | FR-04, OPS-04 |
| Q2 | What do the SQL cluster nodes still host if all databases move to RDS? | FR-09 |
| Q3 | Is FSx the backup target? | OPS-05 |
| Q4 | What are the schedule time, window and the time-to-healthy target? | FR-01, NFR-01 |
| Q5 | What are the RTO and RPO? | FR-09, NFR-02 |
| Q6 | How many report server nodes make up the farm? | FR-07, FR-08 |
| Q7 | Is the SSISDB catalog used, or only file-system packages? | FR-04, FR-06 |

## 10. Related documents

Solution Design (requirements, specifications, migration summary), Infrastructure Design (diagrams and detail tables), and Specification (what an agent must build).

## 11. Change log

| Version | Date | Author | Change |
| --- | --- | --- | --- |
| 0.1 | 24 November 2026 | \[ \] | First draft |
