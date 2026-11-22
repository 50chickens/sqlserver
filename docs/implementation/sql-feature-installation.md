# SQL feature installation

## Purpose

This document states what an installer must satisfy to place the SQL Server engine features, Integration Services and the report server binaries, and how a reader proves each one is present. It owns nothing about how the image carrying them is produced, where it runs, or how the report server is pointed at a database. Rules token `SQL-INSTALL-RULES 1`.

## Source

| Tree | Holds |
| --- | --- |
| `src\sqlserver\installer\sql-server\` | the engine installer and the settings file it reads |
| `src\sqlserver\installer\report-server\` | the report server installer, its settings file, and the configuration script that runs later |
| `src\sqlserver\scripts\ci-host-bind-mount.ps1` | the order the installers run in |
| `ci\host\configs\invoke-docker-host-exec.json` | the probe list read after the install |

## Rules

| # | Rule |
| --- | --- |
| 1 | Do not invoke the engine installer without an instance name; read the instance name from `sql-server\settings.json`, never from a command line. |
| 2 | Do not pass a feature list as a script literal; read the feature set from `sql-server\settings.json`, never a default. |
| 3 | Do not accept one exit code as success; read the success-code list from the settings file beside the installer, never zero alone. |
| 4 | Do not install the report server without an edition and the licence acceptance; read both from `report-server\settings.json`, never a default. |
| 5 | Do not point the report server at a database while installing; run its configuration script against a launched instance, never the image build. |
| 6 | Do not mount the installation media as a virtual drive; extract the ISO to a folder and install from that folder, never from a drive letter. |
| 7 | Do not copy the media into the image; mount the folder that holds it, never a copy. |
| 8 | Do not report the installation on an exit code alone; probe the service and the product path the installer registers, never the code. |
| 9 | Do not write a media path into an installer script; read the folder from `settings.json` beside the script, never a parameter. |

## Instance

| Value or pitfall | Owner |
| --- | --- |
| engine feature set | `src\sqlserver\installer\sql-server\settings.json` |
| instance name and sysadmin account | `src\sqlserver\installer\sql-server\settings.json` |
| success codes | the settings file beside each installer |
| report server edition and licence acceptance | `src\sqlserver\installer\report-server\settings.json` |
| media folder each installer reads | the settings file beside each installer |
| order the installers run in | `src\sqlserver\scripts\ci-host-bind-mount.ps1` |
| services and paths that prove the install | `ci\host\configs\invoke-docker-host-exec.json` |
| pitfall: full-text configuration aborts when the installer carries no instance name | `src\sqlserver\installer\sql-server\settings.json` |
| pitfall: the report server registers its service under its product name, not under the SQL reporting name | `ci\host\configs\invoke-docker-host-exec.json` |
| pitfall: the report server installer reports the reboot-required code when it has succeeded | `src\sqlserver\installer\report-server\settings.json` |

## Run

Run the installers in the order the step list names, then probe. The command and its output from a completed run:

```
& C:\sqlserver\installer\sql-server\install.ps1
& C:\sqlserver\installer\report-server\install.ps1

Found 2 enabled script(s) of 2
=== C:\sqlserver\installer\sql-server\install.ps1 ===
Installing SQL Server 2025 from C:\host_bind_mount\sqlsetup\setup.exe
Installer exited with 0
=== C:\sqlserver\installer\report-server\install.ps1 ===
Installing the report server bundle from C:\host_bind_mount\PowerBIReportServer.exe
Installer exited with 3010
=== CI complete ===
MSSQLSERVER is present
MsDtsServer170 is present
PowerBIReportServer is present
C:\Program Files\Microsoft Power BI Report Server\PBIRS\ReportServer\bin\ReportingServicesService.exe is present
C:\Program Files\Microsoft SQL Server\170\DTS\Binn\MsDtsSrvr.exe is present
```

## Failure

| Error String | Root Cause | Remediation Target |
| --- | --- | --- |
| `Exit message: Value cannot be null. Parameter name: instanceName`, exit code `-2147467261` | the engine installer ran with no instance name, so full-text configuration aborted before any feature installed | `src\sqlserver\installer\sql-server\settings.json` |
| `SQLServerReportingServices is absent` | the probe names a service the report server does not register | `ci\host\configs\invoke-docker-host-exec.json` |
| `Report server installer failed with exit code 3010` | the success-code list did not carry the reboot-required code | `src\sqlserver\installer\report-server\settings.json` |
