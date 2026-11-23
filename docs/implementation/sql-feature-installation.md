# SQL feature installation

## Purpose

This document states what an installer must satisfy to place the SQL Server engine features, Integration Services and the report server binaries, what the configuration stage must set once those binaries run, how a reader proves each one is present, and where the installer's own logs land. It owns nothing about how the image carrying them is produced or how the media reaches the host. Rules token `SQL-INSTALL-RULES 3`.

## Source

| Tree | Holds |
| --- | --- |
| `src\sqlserver\installer\sql-server\` | the engine installer and the settings file it reads |
| `src\sqlserver\installer\report-server\` | the report server installer, its settings file, and the configuration script that runs later |
| `src\sqlserver\scripts\ci-host-bind-mount.ps1` | the order the installers run in |
| `ci\host\configs\invoke-docker-host-exec.json` | the bind-mount list and the probe list read after the install |
| `ci\host\deployment\invoke-docker-host-exec.ps1` | the container that runs the installers and tails their logs |
| `ci\host\deployment\show-log-files.ps1` and `ci\host\configs\show-log-files.json` | the stage that prints the newest files of one or more log folders, and which folders it reads |
| `src\sqlserver\installer\sql-server\configure.ps1` | the engine configuration: mixed authentication, the sa login, TCP |
| `src\sqlserver\installer\report-server\configure.ps1` | the report server configuration: virtual directories, URL reservations, database, key, initialisation |
| `src\sqlserver\installer\report-server\start.ps1` | the node start: the installation identity the node joins the farm under, then the service |
| `src\sqlserver\installer\report-server\show-farm.ps1` | the membership a node reads from the shared database, and the set it must equal |
| `ci\host\configs\invoke-farm-lifecycle.json` | the primary node, the spare nodes, the farm size and the timeouts the lifecycle reads |
| `ci\host\deployment\invoke-farm-lifecycle.ps1` | the lifecycle: build the farm, join nodes, prove membership, retire the oldest node |

## Bind mounts

The provisioning container mounts this list before either installer runs. `invoke-docker-host-exec.ps1` composes the
host path of each mount, creates every host folder, and only then starts the container, so a missing folder is never
reported as a container failure.

| Mount | Host path | Container path | Read-only | Tailed |
| --- | --- | --- | --- | --- |
| logs | `ci\host\host_bind_mount\<serviceName>\<runStamp>\logs` | `C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log` | no | yes |
| media | `ci\host\host_bind_mount` | `C:\host_bind_mount` | yes | no |
| payload | `src\sqlserver` | `C:\sqlserver` | yes | no |

`<serviceName>` is the compose service the image is provisioned for, `dbe14` today, and `<runStamp>` is
`yyyyMMdd-HHmmss`, so a run that changes the feature set writes its own folder and an earlier run's log stays readable.
The media folder is mounted read-only because both installers only read it, and one folder serves every container that
needs the same media without a second copy.

The host path of each mount is not written in the settings file: the settings file names the folders and the container
paths, and `Add-RuntimeConfiguration` composes the absolute host path from the host root, the service name and the run
stamp. A settings file that carried a token would put path construction in JSON, where nothing resolves it and no
reader can say what the folder is.

The install log mount targets the engine's own setup log folder, so `Summary.txt`, `Detail.txt` and the per-action logs
arrive in the host folder as the install writes them. `Wait-TailedProcess` prints each new line once, prefixed with the
mount and file it came from, while `docker exec` is still running.

## Password

The run generates one password on the host and every node reads that same file, so no password is written in the
repository and the engine, the portal connection and the encryption key cannot drift apart.

`invoke-secret-create.ps1` is the first stage in `ci\ci.ps1`. It writes a 24 character password to
`ci\host\host_bind_mount\share\sql-password.txt` and leaves it alone on a later run, so a re-run keeps the password
every node already holds. `host_bind_mount\share` reaches the containers as `C:\share`, which is where
`passwordPath` in both settings files points.

The engine stage signs in with the container's own administrator account and sets the `sa` password from that file,
so the password in the image does not matter. The report server reads the same file for its database connection and
for its encryption key, on the primary and on the joiner alike.

Read the password after a run, without opening a container:

```powershell
Get-Content -Path 'C:\git\internal\devops\sqlserver\ci\host\host_bind_mount\share\sql-password.txt'
```

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
| 10 | Do not mount the container's temp folder for the install logs. Mount the engine's own setup log folder, because the installer writes its summary and detail logs there and the temp folder stays empty. |
| 11 | Do not share one log folder between two services or two runs. Name the host folder with the service name and the run stamp, so a reader can say which service and which run wrote a file. |
| 12 | Do not read the install log after the run ends. Tail it while the installer runs, because an install that hangs writes the reason into a file the run would otherwise never print. |
| 13 | Do not probe a path the log mount creates. Name a service or a path no mount target creates, because the mount creates `C:\Program Files\Microsoft SQL Server` before any installer runs. |
| 14 | Do not install the engine and leave it Windows-authenticated only. Enable mixed authentication and the sa login, because the report server connects as a SQL login and a Windows-only install refuses it with `Login failed for NT AUTHORITY\ANONYMOUS LOGON`. |
| 15 | Do not leave the TCP port to the installer's default. Set the port and `Enabled` in the engine's `SuperSocketNetLib\Tcp` registry key and restart the engine, because the registry takes effect only on a restart. |
| 16 | Do not reserve a URL that ends in the virtual directory. Reserve `http://+:80` and set the virtual directory separately, because a suffixed URL fails with `ReservedUrl: HRESULT -2147220965`. |
| 17 | Do not initialise the report server before its virtual directories, URL reservation and database connection are set. Set those, restart the service, then initialise, because initialising first fails with `rsServerConfigurationError`. |
| 18 | Do not copy the encryption key with `Copy-Item`. Write the bytes `BackupEncryptionKey` returns to the share, and pass those bytes with their length to `RestoreEncryptionKey`, because `KeyFile` is a byte array and not a path. |
| 19 | Do not accept a second report server as joined without proving it serves. Probe both virtual directories on every node and fail when one returns anything but 200, because a node that has not restarted since its URL reservation answers 404. |

## Instance

| Value or pitfall | Owner |
| --- | --- |
| engine feature set | `src\sqlserver\installer\sql-server\settings.json` |
| instance name and sysadmin account | `src\sqlserver\installer\sql-server\settings.json` |
| success codes | the settings file beside each installer |
| report server edition and licence acceptance | `src\sqlserver\installer\report-server\settings.json` |
| media folder each installer reads | the settings file beside each installer |
| order the installers run in | `src\sqlserver\scripts\ci-host-bind-mount.ps1` |
| bind-mount list and the tokens in each host path | `ci\host\configs\invoke-docker-host-exec.json` |
| engine service name and TCP port | `src\sqlserver\installer\sql-server\settings.json` |
| report server service name, login type and URL reservations | `src\sqlserver\installer\report-server\settings.json` |
| which node is the primary, which nodes are spare and how many hold the farm | `ci\host\configs\invoke-farm-lifecycle.json` |
| services and paths that prove the install | `ci\host\configs\invoke-docker-host-exec.json` |
| pitfall: full-text configuration aborts when the installer carries no instance name | `src\sqlserver\installer\sql-server\settings.json` |
| pitfall: the report server registers its service under its product name, not under the SQL reporting name | `ci\host\configs\invoke-docker-host-exec.json` |
| pitfall: the report server installer reports the reboot-required code when it has succeeded | `src\sqlserver\installer\report-server\settings.json` |
| the one password every node shares | `ci\host\configs\invoke-secret-create.json` |

## Lifecycle

`ci\host\deployment\invoke-farm-lifecycle.ps1` owns the whole farm. It removes the project, starts and configures the
engine node, starts and configures the primary node, then rises one spare node at a time and joins it, proving the
membership after every step. Each time the farm reaches its configured size it retires the oldest node: the container
is stopped first, so a stopping node cannot re-register itself, and its row is deleted after.

| Step | Container | Script | What it sets |
| --- | --- | --- | --- |
| 1 | `dbe14` | `installer\sql-server\configure.ps1` | mixed authentication, the sa login, TCP 1433 in the registry, then restarts the engine and proves a SQL login over that port |
| 2 | primary | `installer\report-server\configure.ps1 -Mode primary` | virtual directories, URL reservations, the database connection, the database scripts, restarts, initialises, backs up the key to the share |
| 3 | each spare | `installer\report-server\configure.ps1 -Mode joiner` | the same directories and reservation, the same database, restarts, restores the key the primary wrote |
| 4 | every member | `installer\report-server\show-farm.ps1 -Expected <members>` | reads the farm from the shared database and fails unless that set equals the expected one and the node itself is initialised in it |

Membership is `ReportServer.dbo.Keys`: one row per node holding that node's `MachineName`, its `InstallationID` and its
own copy of the key, plus the single row whose `MachineName` is null, which carries the symmetric key and is never
deleted. A node takes its `InstallationID` from its own name into `RSReportServer.config` before its service starts, so
two nodes built from one image are two members rather than one row rewritten twice. The lifecycle stage throws on the
first non-zero exit and on the first membership that does not match, so a node that failed to configure or to join is
never reported as part of the farm.

## Health

Each service declares a probe in `ci\host\docker_compose\docker-compose.yml`, and every report server starts after
`dbe14` has started, so a report server runs while the engine is still opening its port.

| Service | Probe |
| --- | --- |
| `dbe14` | the `MSSQLSERVER` service is running |
| a report server | `C:\node-ready.txt` exists, which `installer\report-server\start.ps1` writes once its service runs under the node's own installation |

A probe that tested the port instead could never pass before the lifecycle has configured the node: the engine opens
1433 only once `installer\sql-server\configure.ps1` has enabled TCP, and a report server opens 80 only once its URL
reservations exist. Readiness before configuration is therefore the service, and the readiness file is the report
server's own statement that its installation identity is in place. A healthy node is one that is ready to be
configured, not one that has been configured; `installer\report-server\configure.ps1` proves the port and the login
afterwards, which is the evidence that configuration reached the node.

Each probe's interval, timeout, retry count and start period sit beside the probe it belongs to in the compose file.

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

The same stage prints the engine's own setup log while the install is still running:

```
[2026-11-23 19:41:15] logs/Summary.txt: Bootstrap started
[2026-11-23 19:41:16] logs/Summary.txt: Installing engine
[2026-11-23 19:41:17] logs/Summary.txt: Install finished
```

To read the newest install log after a run, without the container, run the log stage. It reads the folder list in
`ci\host\configs\show-log-files.json`, takes the newest run folder under each root, and prints the last lines of the
newest files:

```powershell
& ci\host\deployment\show-log-files.ps1
```

## Failure

| Error String | Root Cause | Remediation Target |
| --- | --- | --- |
| `Exit message: Value cannot be null. Parameter name: instanceName`, exit code `-2147467261` | the engine installer ran with no instance name, so full-text configuration aborted before any feature installed | `src\sqlserver\installer\sql-server\settings.json` |
| `SQLServerReportingServices is absent` | the probe names a service the report server does not register | `ci\host\configs\invoke-docker-host-exec.json` |
| `Report server installer failed with exit code 3010` | the success-code list did not carry the reboot-required code | `src\sqlserver\installer\report-server\settings.json` |
| `Login failed for NT AUTHORITY\ANONYMOUS LOGON` | the report server connects as a SQL login while the engine is Windows-authenticated only | `src\sqlserver\installer\sql-server\configure.ps1`, rule 14 |
| `ReservedUrl: HRESULT -2147220965` | the reserved URL ends in the virtual directory | `src\sqlserver\installer\report-server\settings.json`, rule 16 |
| `rsServerConfigurationError` on initialise | the report server was initialised before its directories, reservation and database were set | the order in `src\sqlserver\installer\report-server\configure.ps1`, rule 17 |
| `http://localhost/Reports returned 404` | the node has not restarted since its URL reservation, or its virtual directory is unset | the restart before the probe in `src\sqlserver\installer\report-server\configure.ps1`, rule 19 |
| The tail prints nothing while the install runs | the log mount targets a folder the installer does not write to | the `logs` entry in `ci\host\configs\invoke-docker-host-exec.json`, rule 10 |
| `MSSQLSERVER is absent` after an install that reported success | the probe names a path the log mount created, so it passed on an empty container | the `probes` list in `ci\host\configs\invoke-docker-host-exec.json`, rule 13 |
