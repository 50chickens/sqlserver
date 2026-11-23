# Domain authentication for the containerised engine

## Purpose

This document states how the engine running inside a Windows container receives a domain identity, how a domain user reaches that engine over Kerberos, which file owns each setting, and what proves the identity in use is the one intended. It owns the one installer argument that carries the service account. It owns nothing about how the image is produced or how the engine features are installed. Rules token `DOMAIN-AUTH-RULES 1`.

## Source

| Tree or document | Holds |
| --- | --- |
| `ci\host\docker_compose\docker-compose.yml` | the service definitions, the credential spec each service carries, the network |
| `ci\host\deployment\invoke-farm-lifecycle.ps1` and `ci\host\configs\invoke-farm-lifecycle.json` | the compose invocation, the project name, the nodes the stage starts and the membership it proves |
| `src\sqlserver\installer\sql-server\install.ps1` and `src\sqlserver\installer\sql-server\settings.json` | the installer arguments, the service account, the instance name, the service name, the port |
| `src\sqlserver\installer\sql-server\configure.ps1` | mixed authentication, the TCP endpoint, the engine restart |
| `ci\host\configs\invoke-farm-lifecycle.json` | the commands the lifecycle runs inside each container, and the databases they name |
| `ci\ci.ps1` | the stage order |
| Microsoft, "Create gMSAs for Windows containers" | the gMSA retrieval right, the account a container presents |
| Microsoft CredentialSpec PowerShell module | the credential spec format, the store the engine reads it from, the switch that attaches it |
| Microsoft, "Service Principal Names" and `setspn` | the two SPN forms a client requests for a named instance and a port |

## Terms

| Term | Meaning |
| --- | --- |
| container host | the domain-joined Windows machine running the docker engine |
| group managed service account (gMSA) | the domain account whose password the key distribution service hands to the principals named in its retrieval list |
| credential spec | the host-side document naming a gMSA, passed to a container at start, which replaces the identity of its LocalSystem and NetworkService tokens |
| service principal name (SPN) | the name a Kerberos client asks the domain to issue a ticket for |
| alias | the DNS name a client uses to reach the service, and the host part of the SPN that name matches |

## Identity model

A Windows container does not join a domain, and a domain controller does not run inside one, so the container never carries a computer account.

Identity reaches the container from the host. The container host joins the domain. The retrieval list on the gMSA names the host's computer account. The host attaches a credential spec when it starts the container. From that point every LocalSystem and NetworkService token in the container authenticates as the gMSA.

Inbound authentication runs the other way. The client asks the domain for a ticket to the alias, the domain issues it for the account the SPN sits on, and the engine accepts it. The absence of a computer account changes one thing in this direction: the engine cannot register its own SPNs, so the identity stage registers them.

## Implementation

`ci\ci.ps1` owns the order. Two stages carry domain identity and both run before the stack is reported up.

| Order | Stage | Files | What it sets |
| --- | --- | --- | --- |
| 1 | identity registration | `ci\host\deployment\invoke-gmsa-register.ps1`, `ci\host\configs\invoke-gmsa-register.json` | proves the gMSA is readable on the host, writes the credential spec the compose services name, registers both SPN forms, creates the alias in DNS |
| 2 | image build and install | `ci\host\deployment\invoke-docker-build.ps1`, `src\sqlserver\installer\sql-server\install.ps1` | passes the engine service account to the installer |
| 3 | container execution | `ci\host\docker_compose\docker-compose.yml` | starts each service with its credential spec |
| 4 | container configuration | `ci\host\configs\invoke-farm-lifecycle.json` | creates the domain login, then proves the identity |

This specification introduces two host paths, `ci\host\configs\invoke-gmsa-register.json` and `ci\host\deployment\invoke-gmsa-register.ps1`, and one path in the container payload, `src\sqlserver\scripts\probe-domain-identity.ps1`. Every other path above exists in this repository today.

### Registration

`invoke-gmsa-register.ps1` runs on the container host and reads `invoke-gmsa-register.json`; it takes no command-line argument. It proves the host reads the gMSA password with `Test-ADServiceAccount`, generates the credential spec with the CredentialSpec module, registers `MSSQLSvc/<alias>` and `MSSQLSvc/<alias>:<port>` on the gMSA with `setspn -S`, and creates the alias in the domain DNS zone pointing at the address the container host answers on. The alias and the credential spec name come from its own settings file; the gMSA name and the port come from `src\sqlserver\installer\sql-server\settings.json`, so the stage and the engine cannot disagree about them.

The credential spec lands in the store the module owns, which is the folder the engine reads a relative spec name from. A client connecting with an explicit port asks for the port-qualified form, and a client connecting without one asks for the bare form, so one form alone leaves half the clients on an NTLM attempt.

The gMSA is created and its retrieval list set in the directory, by an operator or by the identity stage, before this repository's stages run. A domain with no key distribution service root key cannot issue a gMSA password, and the registration stage fails at the first read of the account.

### Service account

`install.ps1` passes the service account from `settings.json` to the engine installer. Left out, the installer places the engine on the virtual account `NT Service\MSSQLSERVER`. A virtual account token is not LocalSystem or NetworkService, so the credential spec never reaches the engine, and every outbound domain call from the engine runs as the container's own anonymous identity.

### Container execution

Each service in `docker-compose.yml` names its credential spec. The compose project network is `nat`, so the container answers through the host's address, and the alias in DNS points at that address. A client reaching the engine by a name whose SPN sits on another account gets no ticket, so the connection fails before the login is read.

### Login and probe

`src\sqlserver\installer\sql-server\configure.ps1` creates the domain login with `CREATE LOGIN ... FROM WINDOWS` and adds it to the sysadmin role, after the restart that enables TCP.

`src\sqlserver\scripts\probe-domain-identity.ps1` runs after `installer\report-server\configure.ps1` in the node command the lifecycle runs. It asks the domain who the engine's token is, under the account the engine service runs as, and fails unless that answer names the gMSA in the engine settings file.

## Rules

| # | Rule |
| --- | --- |
| 1 | Do not join a container to the domain; attach the gMSA identity with a credential spec at container start, never with `Add-Computer` or a domain password in the image. |
| 2 | Do not author a credential spec by hand; generate it with the CredentialSpec module from the account name in `src\sqlserver\installer\sql-server\settings.json`, never from a literal in a deployment script. |
| 3 | Do not start a service without the credential spec naming the gMSA its SPNs sit on; name the spec in `docker-compose.yml`, never at a `docker run` command line. |
| 4 | Do not leave the engine service account to the installer default; pass the account from `settings.json`, never a virtual account. |
| 5 | Do not register one SPN form only; register `MSSQLSvc/<alias>` and `MSSQLSvc/<alias>:<port>` on the gMSA, never on the host computer account. |
| 6 | Do not connect a client by address, by loopback or by a name without an SPN; connect by the alias, never another name. |
| 7 | Do not read the gMSA name, the port or the login from a command line; read them from `src\sqlserver\installer\sql-server\settings.json`, never a literal. |
| 8 | Do not read the alias or the credential spec name from a command line; read them from `ci\host\configs\invoke-gmsa-register.json`, never a literal. |
| 9 | Do not accept a container as identity-bearing on its running state; prove the gMSA identity from inside the container and the Kerberos scheme from a client session, never on the container status. |
| 10 | Do not probe identity from a `docker exec` session; run the probe under the account the engine service runs as, never the container administrator token. |
| 11 | Do not write a domain credential into the image, the compose file or the repository; attach identity with the credential spec, never a password. |
| 12 | Do not create the domain login during the image build; create it after the identity probe answers, never before. |
| 13 | Do not test group policy, a domain local group membership or a standard user as the service account inside a container; test them on a virtual machine, never in a container. |
| 14 | Do not read a session as Kerberos-authenticated on a successful connection; read the scheme the session reports, never the connection result. |

## Instance

| Value or pitfall | Owner |
| --- | --- |
| gMSA account name, domain login, port | `src\sqlserver\installer\sql-server\settings.json` |
| engine instance name, service name, service account | `src\sqlserver\installer\sql-server\settings.json` |
| the alias a client connects by, and the credential spec name | `ci\host\configs\invoke-gmsa-register.json` |
| credential spec attached to each service, network name | `ci\host\docker_compose\docker-compose.yml` |
| stage order | `ci\ci.ps1` |
| pitfall: a `docker exec` session runs as the container administrator and reports that account, so it proves nothing about the gMSA | `src\sqlserver\scripts\probe-domain-identity.ps1`, rule 10 |
| pitfall: a client that connects with an explicit port requests the port-qualified SPN, so the bare form alone leaves it on NTLM | `ci\host\deployment\invoke-gmsa-register.ps1`, rule 5 |
| pitfall: the container answers on the host address, so an alias pointing anywhere else leaves the client reaching a different engine | the DNS entry the registration stage creates, rule 6 |
| pitfall: an SPN registered on the host computer account issues a ticket for a principal the engine does not run as | `setspn` output, rule 5 |
| pitfall: a domain with no key distribution service root key cannot issue a gMSA password | the directory, read by `Test-ADServiceAccount` |

## Verification

Each check reads one fact and compares it with the value the owning file states. A check that reads nothing fails the stage rather than the review.

| # | Check | Command | Passes when |
| --- | --- | --- | --- |
| 1 | the host reads the gMSA password | `Test-ADServiceAccount -Identity <gMSA>` on the container host | the answer is `True` |
| 2 | the credential spec names the gMSA | read the generated spec in the store the CredentialSpec module writes to | the account field names the gMSA in `settings.json` |
| 3 | the container carries the spec | `docker inspect --format '{{json .HostConfig.SecurityOpt}}' <container>` | the answer names the spec the compose service declares |
| 4 | the engine service runs on an identity the spec reaches | `sc.exe qc MSSQLSERVER` inside the container | the answer names `NT AUTHORITY\NetworkService` or `NT AUTHORITY\LocalSystem` |
| 5 | both SPN forms sit on the gMSA | `setspn -L <gMSA>` | the answer carries the bare and the port-qualified form for the alias |
| 6 | the alias resolves for a client | `Resolve-DnsName <alias>` on a domain-joined client | the answer is the address the container host answers on |
| 7 | the engine's outbound token is the gMSA | the probe task answers `nltest /whowas` inside the container | the answer names the gMSA in `settings.json` |
| 8 | the inbound session is Kerberos | `sqlcmd -S <alias>,<port> -E -Q "SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID"` | the answer is `KERBEROS` |
| 9 | the SPN is the reason the session is Kerberos | the same query over the address and over the alias | the address yields NTLM or an SSPI failure while the alias yields `KERBEROS` |
| 10 | the stack answers as one unit | `ci\host\deployment\invoke-farm-lifecycle.ps1` | every node reports healthy from the healthcheck in `ci\host\docker_compose\docker-compose.yml` before the stage configures it |

## Failure

| Error String | Root Cause | Remediation Target |
| --- | --- | --- |
| `Cannot generate SSPI context` | the client connected by a name with no SPN, so no ticket was requested | the alias and the SPN registration, rules 5 and 6 |
| `The target principal name is incorrect` | the SPN sits on an account the engine does not run as | the account `setspn -S` names, rule 5 |
| `A duplicate SPN found, aborting operation` | the alias already has an SPN on the host computer account | remove the duplicate entry, then rerun `invoke-gmsa-register.ps1` |
| `Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'` | the engine's outbound calls carry no domain identity | the service account in `settings.json` and the credential spec in `docker-compose.yml`, rules 3 and 4 |
| `NT AUTHORITY\NETWORK SERVICE` in the probe answer | the container started without its credential spec | the compose service definition, rule 3 |
| `NT AUTHORITY\SYSTEM` in the probe answer | the probe ran under a token the spec does not replace | the task principal in `probe-domain-identity.ps1`, rule 10 |
| `Logon failure: unknown user name or bad password` from the probe | the gMSA password is not readable on this host, or the retrieval list omits its computer account | the gMSA retrieval list in the directory |
| `NTLM` returned at the alias | the login exists but the session is not Kerberos | the SPN registration and the client connection name, rules 5 and 6 |
| `The trust relationship between this workstation and the primary domain failed` | the container host lost its own domain channel | the container host, before any stage runs |
