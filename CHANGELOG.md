# Changelog

All notable changes to the **ClusterValidator** module are documented
here. Format follows [Keep a Changelog](https://keepachangelog.com/).
Versioning follows [SemVer](https://semver.org/).

## [1.4.0] — 2026-05-03

### Added

- **Pester integration suite** under `Tests/Integration/`. Drives
  `Invoke-ClusterValidator` end-to-end against mocks; no live
  cluster, vCenter, MPIO stack, or admin token required. Closes the
  Phase 4 roadmap acceptance-criteria gap.
- Per-phase Pass and Fail coverage for Storage (count mismatch +
  serial divergence), Quorum (witness offline + type mismatch),
  Heartbeat (below-default thresholds), Time (skew exceeds tolerance),
  Reboot (pending), Hotfix (drift), ServiceAccount (built-in account),
  VMware (skipped without `-VCenterServer`), TestCluster (failure),
  and Forensic (skipped on clean run, fired on any Fail).
- Happy-path test asserting every one of the 14 phases produces at
  least one record and that a single correlation GUID stamps the
  whole run.
- PreFlight abort test asserting WSMan unreachability on every node
  throws with the expected diagnostic.
- New private helper `Test-ClvElevation.ps1` extracted from the
  inline admin check so tests can mock `Mock Test-ClvElevation
  { $true }` without needing an elevated runner.
- Mock discrimination via `-ParameterFilter` matching against
  `$ScriptBlock.ToString()` content — each per-phase
  `Invoke-ClvRemote` call is intercepted by the unique cmdlet name
  in its scriptblock (`Get-Disk`, `Get-ClusterQuorum`, `Get-HotFix`,
  etc.).

### Changed

- `Invoke-ClvRemote -Session` and `-Sessions` parameter types relaxed
  from `[PSSession]` / `[PSSession[]]` to `[object]` /
  `[object[]]` (with `[ValidateNotNull()]` /
  `[ValidateNotNullOrEmpty()]`). Production type discipline is
  preserved by the inner `Invoke-Command -Session` call, which
  still requires a real `PSSession`. Necessary because mocked
  sessions cannot inherit from `PSSession` (no public constructor).
- `Get-ClvClusterResource -Session` parameter type relaxed for the
  same reason.
- `Remove-PSSession` cleanup in the orchestrator's `finally` block
  now wrapped in `try/catch`. `-ErrorAction SilentlyContinue` does
  not catch `ParameterBindingException`; this hardens the cleanup
  path against both real-world remoting flakes and test stubs.
- `Tools/Invoke-ClvPester.ps1` already supported `-Category
  Integration`; no script change required, the new test files
  light up automatically.

### Tests

- `Tests/Integration/Invoke-ClusterValidator.Integration.Tests.ps1`
  — 17 cases across 11 contexts.

## [1.3.0] — 2026-05-03

### Added

- **`Test-ClusterValidatorConfig`** — new public function. Statically
  validates a `Config\*.json` against the `Invoke-ClusterValidator`
  parameter schema:
  - **UnknownParameter** — typoed or stale keys
  - **ProtectedKey** — `Nodes`, `Credential`, `ConfigPath` written
    into the config (never config-overridable)
  - **TypeMismatch** — JSON value not assignable to the declared
    parameter type
  - **InvalidValue** — value outside `[ValidateSet]`
  - **OutOfRange** — value outside `[ValidateRange]`
  - **JsonParseError** — file isn't valid JSON
- Underscore-prefixed keys (`_comment`, etc.) are treated as JSON
  documentation and ignored.
- Returns a `pscustomobject` with `ConfigPath`, `Valid` (bool), and
  a structured `Issues` array. Designed for CI: lint every config
  on PR, fail the build if any `Valid` is `$false`.

### Changed

- **Public surface expanded from one function to two.** Manifest
  `FunctionsToExport` now lists `Invoke-ClusterValidator` and
  `Test-ClusterValidatorConfig`. The `Clv` namespace prefix remains
  reserved for **private** helpers; public functions use the full
  `ClusterValidator` brand.
- Rules §11 (Public Function Contract) updated to describe both
  exports and the public/private prefix discipline.

### Tests

- Static suite: §11 contract test now asserts `FunctionsToExport`
  matches the actual `Public/*.ps1` set, plus a sanity check that
  no public file accidentally adopts the `Clv` private prefix.
- Unit suite: nine cases for `Test-ClusterValidatorConfig` covering
  clean/typo/protected-key/out-of-range/bad-set/comment/empty/
  broken-json paths plus a smoke test that lints the bundled
  `Config\example.json` clean.
- Loader test updated to expect both exports.

### Notes

- Recommended CI pattern:

  ```powershell
  $bad = Get-ChildItem .\Config\*.json | ForEach-Object {
      Test-ClusterValidatorConfig -ConfigPath $_.FullName
  } | Where-Object { -not $_.Valid }
  if ($bad) { exit 1 }
  ```

  Catches config drift at PR time rather than at the next 03:00 AM
  scheduled run.

## [1.2.0] — 2026-05-03

### Added

- **Phase 11 VMware** — DRS anti-affinity check. Three-way gate:
  skipped if `-VCenterServer` not supplied, skipped if PowerCLI
  (`VMware.VimAutomation.Core`) is not installed, otherwise runs.
- Two new parameters: `-VCenterServer` (vCenter FQDN/IP) and
  `-VCenterCredentialSecretName` (resolved via SecretManagement).
  When the secret name is omitted, ambient SSO is used.
- `Connect-VIServer` / `Disconnect-VIServer` lifecycle wrapped in
  try/finally so a vCenter connection is always closed cleanly.
- VM-to-host topology check: emits `Pass` when every FCI VM lives on
  a distinct ESXi host; emits `Fail` with `AffinityViolation` when
  two or more share a host (single-host failure would take down the
  cluster).
- DRS rule presence check: `Get-DrsRule -Type VMAntiAffinity` on the
  parent vCenter cluster. `Pass` when an enabled rule covers ≥2 of
  our VMs; `Warn` with `AffinityViolation` when no covering rule
  exists (vMotion may colocate VMs later even if they're separate
  right now).
- New private helper `Get-ClvHostColocation.ps1` — pure logic that
  takes an array of VM objects and returns an `IsHealthy`/`Colocated`
  report. Unit-tested with synthetic VMs (no PowerCLI required).
- New §7 category: `AffinityViolation`. Domain-failure category for
  VMware/Hyper-V/Azure availability-set violations.

### Changed

- Phase contract grows to 14 phases. Renumbering: TestCluster
  11 → 12, Forensic 12 → 13, Persist 13 → 14. New Phase 11 VMware
  slots between ServiceAccount (10) and TestCluster (12).
- Rules §4 phase contract updated to list 14 phases.
- Rules §7 category vocabulary updated to include `AffinityViolation`.

### Tests

- Static suite: 14-phase marker order check; new context for Phase 11
  asserting `-VCenterServer` parameter, PowerCLI gate via
  `Get-Module -ListAvailable`, `Connect-VIServer` + matching
  `Disconnect-VIServer` in a finally block, `Get-DrsRule` invocation,
  `Get-ClvHostColocation` usage, and presence of the private file.
- Static suite: `AffinityViolation` added to the domain-category
  source-presence check.
- Unit suite: `Get-ClvHostColocation` covered with healthy,
  single-collision, multi-collision, and degenerate-input cases. No
  PowerCLI required.

### Notes

- PowerCLI is a runtime soft-dependency: not in `RequiredModules`
  (would break installs on hosts that never need vSphere checks).
  The orchestrator probes for it lazily and emits an `Info` record
  when missing.
- The match between PowerShell node names and vCenter VM names is
  best-effort (exact short-name first, then `<short>*` like-pattern).
  When a node can't be located, the phase emits `Warn` with
  `ConfigurationError` listing exactly which nodes are missing.

## [1.1.0] — 2026-05-03

### Added

- **Rules §7 enforcement.** `Add-ClvResult` gained an optional
  `-Category` parameter validated against the §7 vocabulary
  (`ConnectionError`, `ModuleMissingError`, `StorageInventoryError`,
  `StorageTopologyError`, `MpioConfigurationError`,
  `ReservationConflict`, `QuorumStateError`, `ClusterHeartbeatError`,
  `TimeSkewError`, `HotfixParityError`, `PendingRebootDetected`,
  `ServiceAccountError`, `TestClusterFailure`, `ConfigurationError`,
  `PermissionDenied`, `HandledSkip`, `Unknown`).
- **Runtime guard.** Every `Fail` or `Warn` record must specify a
  category; the function throws at the call site if it's omitted.
  `Pass` and `Info` records may still omit it.
- **Result schema.** Records now carry a `Category` column alongside
  `Status` so SIEM searches can filter by the category vocabulary
  without parsing free-text `Message` fields.
- **Console output.** Format changed from `[Status]` to
  `[Status/Category]` when a category is present.
- All 18 `Fail`/`Warn` call sites in `Invoke-ClusterValidator` tagged
  with the appropriate category. Catch-all interrogation failures
  inside per-phase `try` blocks are classified as `ConnectionError`
  (per Rules §7: never misclassify a connection failure as a domain
  fault).

### Changed

- Console line format: `[Status/Category] Phase :: Message` when a
  category is present, `[Status] Phase :: Message` otherwise.

### Tests

- Static suite: AST scan asserts every `Add-ClvResult` call with
  `Status='Fail'` or `'Warn'` carries a `-Category`. Catches new call
  sites that forget the category.
- Static suite: source must reference every domain category at least
  once (smoke check that the vocabulary is actually used).
- Unit suite: `Add-ClvResult` accepts categoryless `Pass`/`Info`,
  rejects categoryless `Fail`/`Warn`, rejects unknown categories,
  records the column when supplied.

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

- Code signing requires the internal PKI cert; the published build is
  unsigned for now. AllSigned hosts must trust the publisher chain
  before adopting.
- GitHub Actions workflow assumes `windows-latest` runners can install
  the `Failover-Clustering` Windows feature; in restricted environments
  the unit suite may need to skip module-import tests.

> Note: the 1.0.0 result-category gap is closed in 1.1.0; the 1.0.0
> VMware/DRS gap is closed in 1.2.0.

### Notes

- The §10 module-promotion trigger fired at the end of Phase 4 (13
  phases, 790 lines, helpers reusable). From this point on, the
  public surface is the function, not the script.
