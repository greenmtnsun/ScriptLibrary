# Changelog

All notable changes to the **ClusterValidator** module are documented
here. Format follows [Keep a Changelog](https://keepachangelog.com/).
Versioning follows [SemVer](https://semver.org/).

## [1.0.0] — 2026-05-03

First stable release. The validator started as a 37-line script and
graduated through four roadmap phases before promotion to a module
shape.

### Added

**Roadmap Phase 1 — Audit & Observability**
- `[CmdletBinding()]` on the public function so `-Verbose`, `-Debug`,
  and the standard common parameters work
- Correlation GUID generated once per run, stamped on every result
  record and Event Log payload
- `Start-Transcript` / `Stop-Transcript` guarded by `try`/`finally`
- `Test-WSMan` for reachability (replaces `Test-Connection` — ICMP is
  often blocked and does not predict remoting outcome)
- Reusable `PSSession` per node with explicit `OperationTimeout` and
  `OpenTimeout`

**Roadmap Phase 2 — Validation Depth**
- Phase 5 Quorum: witness state and quorum type, configurable via
  `-ExpectedQuorumType`
- Phase 6 Heartbeat: cluster network thresholds; warns when below
  Server 2016+ defaults
- Phase 7 Time: cross-node W32Time skew via parallel UTC samples,
  tolerance via `-TimeSkewToleranceSeconds`
- Phase 8 Reboot: pending-reboot detection (CBS, WindowsUpdate,
  PendingFileRenameOperations) on every node
- Phase 9 Hotfix: KB parity diff across nodes
- Phase 10 ServiceAccount: cluster + SQL service account hygiene
  (built-in account flag, cross-node uniformity)
- Phase 12 Forensic: `Get-ClusterLog` capture triggered automatically
  on any Fail, with `-ForensicCaptureMinutes` window

**Roadmap Phase 3 — Security Hardening**
- Constrained Language Mode preflight (hard fail with precise
  diagnostic, runs before `Start-Transcript`)
- `-Credential` and `-CredentialSecretName` (resolved via
  `Microsoft.PowerShell.SecretManagement`) for non-ambient remoting
- `-HardenReportAcl` normalizes the report directory DACL to SYSTEM +
  Administrators, runs before transcript so the file inherits the lock
- `.NOTES` documents the production hardening expectations: AllSigned,
  gMSA, SecretManagement, FullLanguage

**Roadmap Phase 4 — Scale & Operability**
- `-ConfigPath` JSON loader with CLI override; `Nodes`, `Credential`,
  and `ConfigPath` itself are protected from override
- Three pure-logic helpers (`Get-ClvTimeSkew`, `Get-ClvHotFixDrift`,
  `Get-ClvServiceAccountIssues`) extracted from inline phase bodies
- Phase 3 Storage parallelized via the multi-session wrapper
- Pester unit suite with `InModuleScope`-based helper coverage
- `Config\example.json` template

**Module Shape (Rules §10 trigger fired)**
- `ClusterValidator.psd1` manifest with explicit `FunctionsToExport`,
  `RequiredModules`, GUID, and PSData metadata
- `ClusterValidator.psm1` loader (the only file with the `$PSScriptRoot`
  carve-out per Rules §2)
- `Public/Invoke-ClusterValidator.ps1` — single exported function
- `Private/` — seven atomic helper files (one per Rule §1)
- `Invoke-clusterValidator.ps1` at repo root remains as a back-compat
  wrapper that forwards `$args`

**Phase 5 — Release & Fleet Rollout (this release)**
- This `CHANGELOG.md`
- `docs/RUNBOOK.md` — operator triage guide for every failure phase
- `Tools/Install-ClusterValidatorJob.ps1` — SQL Agent CmdExec job
  installer with `-DryRun`
- `.github/workflows/pester.yml` — Static + Unit suites on every push
  to `main` and `claude/*`

### Known gaps

- Result records still carry only `Pass | Warn | Fail | Info` status.
  Rules §7 specifies a richer set of error categories
  (`StorageInventoryError`, `ReservationConflict`, etc.) but those are
  not yet surfaced as a structured field. Tracked for 1.1.0.
- Code signing requires the internal PKI cert; the published build is
  unsigned for now. AllSigned hosts must trust the publisher chain
  before adopting.
- VMware anti-affinity / DRS check (roadmap Phase 4 optional) is not
  implemented.
- GitHub Actions workflow assumes `windows-latest` runners can install
  the `Failover-Clustering` Windows feature; in restricted environments
  the unit suite may need to skip module-import tests.

### Notes

- The §10 module-promotion trigger fired at the end of Phase 4 (13
  phases, 790 lines, helpers reusable). From this point on, the
  public surface is the function, not the script.
