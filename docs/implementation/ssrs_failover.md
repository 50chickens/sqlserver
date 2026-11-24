# SSRS failover components

## Purpose

This document lists the components of the rolling replacement. Each entry names one component and the part it provides. Rules token `SSRS-FAILOVER-RULES 1`.

## Source

| Tree | Holds |
| --- | --- |
| `docs\aws-solution.png` | the deployed topology the components are drawn from |
| `docs\spec.md` | the report server, integration services and database scope |

## Components

1. **Elastic Load Balancing — Application Load Balancer.** The HTTPS entry point. Terminates TLS, spreads requests over the report server nodes, and applies the sticky-session setting a Power BI Report Server scale-out requires.
2. **Amazon EC2 Auto Scaling.** Replaces nodes so each tier stays at its desired count across both Availability Zones, through instance refresh.
3. **Amazon Machine Image.** The image every replacement launches from, so replacing a node becomes a launch rather than a configuration exercise; one image also gives every report server node the same machine key and view state.
4. **Power BI Report Server scale-out deployment.** The shared catalog and the membership that makes report server nodes interchangeable. A node joins before it takes traffic, and is deregistered before it leaves.
5. **SQL Server Failover Cluster Instance in Windows Server Failover Clustering.** One instance across two nodes that moves the catalog, the logins and the certificates as a single role, and publishes one cluster network name to whichever node runs that role, so a node can be replaced without the instance being replaced.
6. **SQL Server Agent.** Runs subscription and schedule jobs inside that role, so scheduled reporting moves with the role and does not remain on a retired node.
7. **Amazon FSx for Windows File Server.** A continuously available SMB 3.0 share for the catalog data and log files, replicated synchronously across both Availability Zones, and the File Share Witness that maintains cluster quorum while one node is rebuilt.
