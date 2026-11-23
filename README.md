# Delivery repository

Work in this repository is delivered through Cursus. A requirement document becomes one branch
per acceptance criterion, each branch is proved by the check script, and only a passing commit is
merged and promoted.

The Cursus runtime lives in `cursus/`, which is git-ignored, so nothing here commits the binary.

The solution lives under `src/`. `ci\ci.ps1` builds and tests the one solution file it finds
there, and fails before it builds anything when that folder holds none, so a delivery that puts
the solution at the repository root fails the check.

Run it from its own folder:

```powershell
cd cursus
.\cursus.exe
```

Then edit `cursus\requirement.json` and run `cursus\drive-delivery.ps1`. It submits that one
document into `cursus\data\requirements`, waits until that document has produced a task and every
one of its tasks has reached a final state, then prints each task's final state. A document that
produces no task by the timeout is reported by its id rather than as a finished run.
`cursus\watch-release.ps1` reports a promotion when it lands.

`plan/` holds requirement documents a delivery proposes for the next milestone. A document there
is planned only after it has merged, so a plan is reviewed and checked before it becomes work.

The installation contract for the SQL features, and what proves each one is present, is
[`docs\implementation\sql-feature-installation.md`](docs/implementation/sql-feature-installation.md).

The domain identity contract for the containerised engine, and what proves each identity is the one
intended, is [`docs\kerberos\domain-authentication.md`](docs/kerberos/domain-authentication.md).
