# Infrastructure Design: SQL Server, SSIS and SSRS Hosting on AWS

Draft, 24 November 2026. Known details are filled in; remaining \[bracketed\] values need a decision or a value. The diagrams show how the pieces connect.

## 1. Purpose and scope

- **Purpose:** Describe how SQL Server, SSIS and SSRS are hosted on AWS, and how the hosts are rebuilt automatically.
- **In scope:** Compute, storage, clustering, identity, certificates, DNS, SSIS and SSRS hosting, rebuild automation, local test pipeline.
- **Out of scope:** \[Application design, network CIDR planning, firewall rule detail\]
- **Owner:** \[name\]  **Reviewers:** \[names\]  **Version:** \[0.1\]

## 2. Environments and naming

The same design is repeated for each environment.

| Environment | AWS account | Region | Cluster name | Node 1 | Node 2 | RDS endpoint | FSx alias |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | \[ \] | \[ \] | CLUS-A | SQL-A1 | SQL-A2 | \[ \] | \[ \] |
| B | \[ \] | \[ \] | CLUS-B | SQL-B1 | SQL-B2 | \[ \] | \[ \] |
| C | \[ \] | \[ \] | CLUS-C | SQL-C1 | SQL-C2 | \[ \] | \[ \] |
| D | \[ \] | \[ \] | CLUS-D | SQL-D1 | SQL-D2 | \[ \] | \[ \] |

Naming standard: \[pattern for hosts, volumes, security groups, secrets, tags\]

## 3. Architecture overview

**Diagram 1: Overall architecture.** Shows users and schedulers, load balancer, SSRS hosts, SSIS hosts, SQL cluster, RDS, FSx, Active Directory, Secrets Manager, S3.

&#91;embedded content: overall architecture · 9 components\]

Users reach SSRS through the load balancer, the schedule starts the SSIS runs, both hosts use RDS, and FSx holds the shared packages, logs and cluster witness.

| Component | Purpose | Count per environment | Notes |
| --- | --- | --- | --- |
| SQL Server cluster nodes | \[Confirm: all databases move to RDS, so what do these nodes still host?\] | 2 | \[ \] |
| SSRS/SSIS host | Report server and SSIS package execution | \[ \] | Autoscaled, rebuilt on a daily schedule |
| RDS for SQL Server | Target for all SQL databases | \[ \] | \[Edition, Multi-AZ\] |
| FSx for Windows | UNC share for SSIS packages and logs; witness and backups possible | \[ \] | \[ \] |
| Application Load Balancer | \[SSRS front end\] | \[ \] | \[ \] |
| Active Directory | Backs all SQL instances: domain join, service accounts, Kerberos | \[ \] | \[Managed AD or self-managed\] |

## 4. Compute

| Role | Instance type | vCPU | Memory | OS and edition | AMI ID | EBS-optimized | Placement |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SQL cluster node | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[AZ, placement group\] |
| SSRS host | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] |
| SSIS host | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] |

## 5. Storage and volumes

**Diagram 2: Storage layout.** Shows each host's EBS volumes and mount points, plus the FSx share used by SSIS, the cluster witness and backups.

&#91;embedded content: storage layout · 3 groups\]

SQL nodes keep data, log, TempDB and backup on separate EBS volumes; the SSIS host reads packages and writes logs on FSx, which also holds backups and the witness.

| Host role | Volume purpose | Drive or mount | Type | Size | IOPS | Throughput | Allocation unit | Encryption key |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SQL node | OS | C: | \[ \] | \[ \] | \[ \] | \[ \] | 4 KB | \[ \] |
| SQL node | Data | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | 64 KB | \[ \] |
| SQL node | Log | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | 64 KB | \[ \] |
| SQL node | TempDB | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | 64 KB | \[ \] |
| SQL node | Backup | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | 64 KB | \[ \] |
| SSRS/SSIS host | OS | C: | \[ \] | \[ \] | \[ \] | \[ \] | 4 KB | \[ \] |
| SSRS/SSIS host | Working and temp | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] |

### FSx for Windows File Server

| Item | Value |
| --- | --- |
| File system ID and deployment type (single or multi-AZ) | \[ \] |
| Capacity and throughput | \[ \] |
| DNS alias | \[ \] |
| Shares | Packages and logs; backups (to be confirmed) and witness (possible) |
| Backup and retention | \[ \] |

## 6. SQL Server cluster

**Diagram 3: Cluster and availability design.** Shows two nodes, the cluster name object, the listener, replication or shared storage, and the file share witness.

&#91;embedded content: cluster design · 2 nodes, 1 witness\]

Clients connect to the listener or cluster name, which points at whichever node is active; both nodes also vote with the file share witness.

| Item | Value |
| --- | --- |
| Design | Cluster, possibly with availability groups \[confirm design\] |
| Nodes and AZs | \[ \] |
| Quorum model and witness | File share witness, possibly on FSx \[confirm\] |
| Cluster IPs (per subnet) | \[ \] |
| Listener name and port | \[ \] |
| Synchronous or asynchronous commit | \[ \] |
| Failover mode and tested RTO/RPO | \[ \] |
| SQL edition and version | SQL Server 2025 target; edition \[ \] |
| Instance name, static port, collation | \[ \] |
| Max memory, MAXDOP, trace flags | \[ \] |
| TempDB layout | \[ \] |

## 7. RDS for SQL Server (target state)

| Item | Value |
| --- | --- |
| Engine and version | \[ \] |
| Instance class and storage | \[ \] |
| Multi-AZ | \[ \] |
| Databases hosted | All SQL databases: application databases, SSISDB, ReportServer, ReportServerTempDB |
| Parameter and option groups | \[ \] |
| Migration method and cutover plan | \[ \] |
| Limits that affect the design | \[SQL Agent cannot run PowerShell or command-line steps\] |

## 8. SSIS hosting

**Diagram 4: SSIS execution flow.** Shows the trigger, the host, the PowerShell wrapper, dtexec, the package source on the UNC share, the target databases and the log destination.

&#91;embedded content: SSIS execution flow · 5 steps\]

The trigger calls a PowerShell wrapper, which starts dtexec; dtexec loads the package from the UNC share, writes to the target databases and writes its log back to the share.

| Item | Value |
| --- | --- |
| Trigger mechanism | Today: a SQL Agent job calls a PowerShell script, which calls dtexec. After the move: \[open, decision D2 in the Solution Design\] |
| Execution account | \[ \] |
| Package location (UNC) | Shared UNC path used by several clustered SQL instances \[path\] |
| Log location (UNC) | UNC path \[path\] |
| Package deployment model | File system: .dtsx files on the shared UNC path \[confirm whether the SSISDB catalog is also used\] |
| 32-bit and 64-bit drivers, ODBC DSNs, OLE DB providers | \[ \] |
| Custom components and GAC items | \[ \] |
| Environment variables and parameters | \[ \] |
| Behavior during failover | \[Packages and logs remain reachable at the same UNC path\] |
| Log retention and cleanup | \[ \] |

## 9. SSRS hosting

**Diagram 5: SSRS request flow.** Shows the user, load balancer, SSRS host, ReportServer database, data sources and the encryption key store.

&#91;embedded content: SSRS request flow · 7 components\]

Users reach the SSRS host through the load balancer; the host reads its ReportServer database, needs the encryption key restored, and queries the report data sources.

| Item | Value |
| --- | --- |
| SSRS mode and version | \[Native mode\]; in SQL Server 2025 this is Power BI Report Server |
| ReportServer and TempDB database location | RDS for SQL Server |
| Service account | \[ \] |
| URL reservations and portal URL | \[ \] |
| Load balancer and health check | \[Load balancer\]; the health check is authenticated, see section 10 |
| Encryption key backup location and restore step | \[ \] |
| Shared data source credentials | \[ \] |
| SMTP and subscriptions | \[ \] |
| Configuration files to manage | \[rsreportserver.config, others\] |

## 10. Identity and Kerberos

**Diagram 6: Authentication and delegation.** Shows the user, SSRS, SQL Server and the file share, with the Kerberos tickets and delegation hops.

&#91;embedded content: Kerberos hops · 4 services\]

A user signs in to SSRS, and SSRS passes that identity on to SQL Server and the file share, so each service needs its own SPN and SSRS needs constrained delegation to both.

### Service accounts

| Service | Host role | Account (gMSA or standard) | Rights required | Password or secret store |
| --- | --- | --- | --- | --- |
| SQL Server engine | SQL node | \[ \] | \[Perform volume maintenance, Lock pages in memory\] | \[ \] |
| SQL Server Agent | SQL node | \[ \] | \[Log on as a service\] | \[ \] |
| SSRS | SSRS host | \[ \] | \[ \] | \[ \] |
| SSIS / dtexec execution | SSIS host | \[ \] | \[Read packages, write logs\] | \[ \] |
| Cluster | SQL node | \[ \] | \[ \] | \[ \] |

### SPNs

| SPN | Registered on | Used for | Created by |
| --- | --- | --- | --- |
| MSSQLSvc/\[host\]:\[port\] | \[SQL service account\] | SQL connections | \[ \] |
| MSSQLSvc/\[listener\]:\[port\] | \[ \] | Listener connections | \[ \] |
| HTTP/\[ssrs-name\] | \[SSRS account\] | SSRS portal | \[ \] |
| cifs/\[fsx-alias\] and HOST/\[fsx-alias\] | \[FSx computer account\] | UNC share access | \[FSx alias script\] |

### Delegation

| From | To | Type | Reason |
| --- | --- | --- | --- |
| \[SSRS\] | \[SQL, file share\] | \[Constrained\] | \[Pass user identity\] |

### Active Directory and domain join

| Item | Value |
| --- | --- |
| Domain and forest names | \[ \] |
| Directory type | \[Managed Microsoft AD, self-managed, AD Connector\] |
| Domain join method | \[SSM domain join document, script at boot\] |
| Join account and where its credentials are stored | \[ \] |
| OU path per role (SQL node, SSRS host, SSIS host) | \[ \] |
| Computer naming and prefix rules | \[ \] |
| Group Policy objects applied | \[ \] |
| Local administrator groups and access model | \[ \] |
| Time sync and DNS servers used by hosts | \[ \] |
| Join timing in the boot sequence and failure handling | \[ \] |

### Domain accounts instead of local accounts and SQL logins

| Purpose | Account | Type | Groups | Notes |
| --- | --- | --- | --- | --- |
| SQL Server engine service | \[ \] | \[gMSA or standard\] | \[ \] | \[ \] |
| SQL Server Agent service | \[ \] | \[ \] | \[ \] | \[ \] |
| SSRS or Report Server service | \[ \] | \[ \] | \[ \] | \[ \] |
| SSIS execution and Agent proxy | \[ \] | \[ \] | \[ \] | \[ \] |
| Report data source (unattended execution) | \[ \] | \[ \] | \[ \] | \[ \] |
| Health check test account | \[ \] | \[Standard\] | \[ \] | \[Credentials in Secrets Manager\] |
| Cluster name object and virtual computer objects | \[ \] | \[ \] | \[ \] | \[Pre-staged or created at build\] |
| Administrator groups (DBAs, operators) | \[ \] | \[Group\] | \[ \] | \[Windows authentication only, no SQL logins\] |
| gMSA retrieval group (hosts allowed to use each gMSA) | \[ \] | \[Group\] | \[ \] | \[ \] |

### Report server scale-out farm

| Item | Value |
| --- | --- |
| Farm size and node roles | Scale-out farm, for example two nodes |
| Shared ReportServer database and key handling | ReportServer database on RDS \[key handling\] |
| Join step when a new node starts | \[ \] |
| Order of operations when rotating a node (add new, verify, remove old) | Add the new node, verify it, then retire an old node |
| Removal of the old node from the farm's scale-out keys list | Removed by the termination lifecycle hook |

### Authenticated health check

| Item | Value |
| --- | --- |
| Test account and Secrets Manager secret name | Service account with credentials in Secrets Manager \[secret name\] |
| URL and method checked | \[Report server URL\] |
| Expected result | Authenticated 200 and one data source connection test passes |
| Fallback signal | A 401 on the report server URL means the service is alive |
| Where results are reported | \[ \] |

### Instance termination cleanup

| Cleanup item | Method | Owner | Verified by |
| --- | --- | --- | --- |
| Termination lifecycle hook runs before the instance is destroyed | \[ \] | \[ \] | \[ \] |
| Remove node from report server scale-out farm | \[ \] | \[ \] | \[ \] |
| Deregister from load balancer and drain connections | \[ \] | \[ \] | \[ \] |
| Delete or disable the Active Directory computer object | \[ \] | \[ \] | \[ \] |
| Remove SPNs held by the computer object | \[ \] | \[ \] | \[ \] |
| Delete the host DNS records (forward and reverse) | \[ \] | \[ \] | \[ \] |
| Remove any DNS aliases pointing at the host | \[ \] | \[ \] | \[ \] |
| Remove the host from gMSA retrieval groups if added individually | \[ \] | \[ \] | \[ \] |
| Remove per-host secrets and parameters | \[ \] | \[ \] | \[ \] |
| Remove monitoring agents, alarms and dashboards for the host | \[ \] | \[ \] | \[ \] |
| Clean up stale cluster node registration (if clustered) | \[ \] | \[ \] | \[ \] |
| Wait for running packages before termination | \[ \] | \[ \] | \[ \] |
| Failure handling if cleanup fails or times out | \[ \] | \[ \] | \[ \] |
| Deregister the host from the Octopus server | \[ \] | \[ \] | \[ \] |

## 11. Certificates and TLS

| Certificate | Subject and SANs | Issuer | Installed on | Expiry | Renewal method | Used by |
| --- | --- | --- | --- | --- | --- | --- |
| SQL Server TLS | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[Force encryption\] |
| SSRS HTTPS | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] |
| Load balancer | \[ \] | \[ACM\] | \[ \] | \[ \] | \[ \] | \[ \] |
| Availability group endpoint | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] | \[ \] |
| Root and intermediate CA | \[ \] | \[ \] | \[All hosts\] | \[ \] | \[ \] | \[Trust chain\] |

## 12. DNS and aliases

| Name | Type | Points to | Zone | Purpose | Kerberos SPN needed |
| --- | --- | --- | --- | --- | --- |
| \[cluster name\] | A | \[ \] | \[ \] | WSFC | \[ \] |
| \[listener name\] | A | \[ \] | \[ \] | AG listener | \[ \] |
| \[fsx alias\] | CNAME | \[FSx DNS name\] | \[ \] | UNC share | \[ \] |
| \[ssrs name\] | CNAME or alias | \[Load balancer\] | \[ \] | SSRS portal | \[ \] |
| \[rds alias\] | CNAME | \[RDS endpoint\] | \[ \] | Database | \[ \] |

## 13. Windows configuration

| Area | Setting | Value | Applied by |
| --- | --- | --- | --- |
| Time | Time zone and NTP source | \[ \] | \[ \] |
| Features | Roles and features installed | \[Failover Clustering, .NET\] | \[ \] |
| Registry | TLS protocol and cipher settings | \[ \] | \[ \] |
| Registry | SSRS, SSIS and other keys | \[ \] | \[ \] |
| Security | Host firewall rules | \[ \] | \[ \] |
| Security | Antivirus exclusions | \[Data, log, backup paths\] | \[ \] |
| Performance | Power plan, page file | \[ \] | \[ \] |
| Patching | Method and window | \[SSM Patch Manager\] | \[ \] |
| Access | Admin groups, remote access | \[ \] | \[ \] |

## 14. Host rebuild and scaling

**Diagram 7: Rebuild and scale-out flow.** Shows the image pipeline, launch template, scheduled action, new instance boot, bootstrap steps, registration, health checks and scale-in lifecycle hook.

&#91;embedded content: rebuild and scale flow · 9 steps\]

The image pipeline builds the AMI, the scheduled action makes the scaling group launch from it, each new host bootstraps itself, and scale-in waits on the lifecycle hook so running packages finish first.

| Item | Value |
| --- | --- |
| Image build method | \[EC2 Image Builder or Packer\] |
| Baked in the image | \[SSIS, SSRS binaries, drivers, scripts\] |
| Configured at boot | \[Secrets, domain join, SSRS key restore, DB connection\] |
| Schedule | Daily \[time\] |
| Min, desired and max capacity | \[ \] |
| Health check and grace period | \[ \] |
| Scale-in protection and lifecycle hook | Termination lifecycle hook (stated); waits for running packages \[proposed\] |
| Failure handling | \[Retry limits, alerting\] |
| Infrastructure as code tool and repository | CloudFormation, deployed from GitHub Actions; configuration as declarative YAML \[tool open: Ansible recommended\] |
| Registration with Octopus | Registers with the Octopus server on launch and deregisters on termination \[roles and environments\] |

## 15. Local test pipeline (AWS Emulator)

**Diagram 8: Emulator test flow.** Shows the test script, the emulator endpoint, the patched EC2 service, the Windows container acting as the instance, and the installer media in emulated S3.

&#91;embedded content: emulator test flow · 5 components\]

The script calls RunInstances on the emulator, whose patched EC2 service starts a Windows container through Docker; the container pulls installer media from emulated S3 and runs the real SSIS and SSRS setup.

| Item | Value |
| --- | --- |
| Emulator fork and pinned version | \[ \] |
| Windows host and Docker mode | \[ \] |
| AMI to image mapping | \[ \] |
| Mocked at API level | \[Clustering, FSx, domain join, Kerberos\] |
| Real in the container | SSIS and SSRS installation and services |
| Pass criteria | \[Services running, dtexec smoke test, SSRS responds\] |

## 16. Security, backup and operations

| Area | Decision |
| --- | --- |
| IAM roles and instance profiles | \[ \] |
| Secrets storage | Secrets Manager, including the health check account credentials \[paths\] |
| Encryption at rest and in transit | \[KMS keys, TDE, forced TLS\] |
| Database backups and retention | FSx \[to be confirmed\] |
| Volume snapshots and AWS Backup plan | \[ \] |
| Disaster recovery region, RPO and RTO | \[ \] |
| Monitoring and alerts | Health checks and a SQL Agent canary job \[plus CloudWatch agent, counters, alarms\] |
| Log destinations | \[SQL error log, event log, install logs, SSIS logs\] |
| Tagging standard | \[ \] |
| Licensing model | \[License included or BYOL, edition, core counts\] |

## 17. Risks, assumptions and open items

| # | Item | Type | Owner | Status |
| --- | --- | --- | --- | --- |
| R1 | RDS cannot run PowerShell or command-line SQL Agent steps, so the current job chain cannot move as is | Risk | \[ \] | Open |
| R2 | SSISDB and ReportServer may not move to RDS as a straight copy | Risk | \[ \] | Open |
| R3 | SQL Server 2025 tooling coverage for SSRS and SSIS is thinner than for the engine | Risk | \[ \] | Open |
| R4 | Windows containers cannot show cluster, domain or Kerberos behavior | Risk | \[ \] | Open |
| R5 | Missing SPNs cause silent fallback to NTLM or failed delegation | Risk | \[ \] | Open |
| R6 | Termination cleanup partly fails and leaves stale AD, DNS or farm entries | Risk | \[ \] | Open |
| Q1 | Where does SQL Agent run once all databases are on RDS? | Open question | \[ \] | Open |
| Q2 | What do the SQL cluster nodes still host if all databases move to RDS? | Open question | \[ \] | Open |
| Q3 | Is FSx the backup target? | Open question | \[ \] | Open |

## 18. Change log

| Version | Date | Author | Change |
| --- | --- | --- | --- |
| 0.1 | 17 November 2026 | \[ \] | Initial template |
| 0.2 | 24 November 2026 | \[ \] | Filled in known details, added risks and open questions |
