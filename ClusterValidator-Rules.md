# Invoke-clusterValidator Development Rules

## Purpose

Non-negotiable engineering rules for the cluster validator and its
supporting tooling inside the `ScriptLibrary` repository.

Script under governance:

`Invoke-clusterValidator.ps1`

All contributors and automation must follow these rules before adding or
modifying code. Companion document: `ClusterValidator-Roadmap.md`.

---

## 1. Atomic Scripts Only

Every script in this project must be atomic.

An atomic script means:

- One script does one clear task.
- The script is complete and runnable by itself.
- The script does not depend on hidden context.
- The script accepts explicit parameters.
- The script performs state checks before making changes.
- The script reports exactly what it changed.
- The script can be tested independently with Pester.

`Invoke-clusterValidator.ps1` is the orchestrator. Helper logic that is
reusable, testable, or gateable belongs in `Tools\` or a future
`Private\` folder as its own atomic script.

---

## 2. Mandatory State Check Before Code

Before writing or modifying code, run the project state checker:

```powershell
& '.\Tools\Test-ClvProjectState.ps1' -ProjectRoot (Resolve-Path '.')
```

The state checker must:

- verify the expected project structure (see §6)
- confirm `Invoke-clusterValidator.ps1` is present, signed (when in a
  release branch), and parses with no syntax errors
- confirm every public-facing parameter on the orchestrator has a
  corresponding documented entry in `.NOTES`
- confirm no script in the tree contains `$PSScriptRoot` (see §3)
- confirm every `.ps1` under `Tools\` has a matching test under
  `Tests\Static\` or `Tests\Unit\`

If the state checker reports missing paths, address that gap
intentionally before proceeding with dependent work.

The state checker itself is a Phase 0 deliverable; it must be the first
script created when this rule set is adopted (see §5).

---

## 3. Do Not Use `$PSScriptRoot`

Do not use `$PSScriptRoot` anywhere in this project.

Use explicit parameters instead:

```powershell
param(
    [string]$ProjectRoot
)
```

All scripts, tools, and Pester tests must use explicit paths or explicit
`-ProjectRoot` parameters. The state checker enforces this with a
forbidden-token static test.

---

## 4. Pester Coverage Is Required

Every script and helper function must have matching Pester coverage.

Test categories required for this project:

- **Static** — script parses, parameters present, no `$PSScriptRoot`,
  required `.NOTES` sections present, Authenticode signature present
  on release branches.
- **Unit** — pure-logic functions (LUN serial diff, time-skew math,
  hotfix-parity diff, error classification mapping) tested with mocked
  inputs.
- **Integration** — `Invoke-Command`, `Get-ClusterResource`,
  `Test-WSMan`, `Get-MSDSMGlobalDefaultLoadBalancePolicy`, and
  `Test-Cluster` are mocked; phases run end-to-end against fixtures.
- **Acceptance** — full orchestrator runs against a recorded fixture
  set producing the canonical Pass and Fail JSON artifacts.

Tests must run independently and must validate both success paths and
handled-failure paths. A test that only covers the happy path is
incomplete.

---

## 5. Ordered Phase 0 Work

Do not jump into the validation logic enhancements first. Build the
Project Success Kit in this order:

1. `Tools\Test-ClvProjectState.ps1`
2. `Tests\Static\Test-ClvProjectState.Tests.ps1`
3. `Tools\New-ClvProjectScaffold.ps1`
4. `ClusterValidator-Rules.md` (this document)
5. `ClusterValidator-Roadmap.md` (already present)
6. `docs\OUTSTANDING_QUESTIONS.md`
7. `docs\RISK_REGISTER.md`
8. `docs\PESTER_TEST_STRATEGY.md`
9. `Tools\Invoke-ClvPester.ps1`
10. Static tests for: required files, forbidden `$PSScriptRoot`, required
    `.NOTES` sections, required parameters on the orchestrator, presence
    of every error category from §10 in the orchestrator's classifier.

Roadmap Phases 1-5 in `ClusterValidator-Roadmap.md` are blocked on
Phase 0 completion.

---

## 6. Explicit Project Structure

The project must maintain this structure relative to the repository
root:

```text
ScriptLibrary/
├── Invoke-clusterValidator.ps1     # the orchestrator
├── ClusterValidator-Rules.md
├── ClusterValidator-Roadmap.md
├── Tools/                          # atomic helper scripts
├── Tests/
│   ├── Static/
│   ├── Unit/
│   ├── Integration/
│   └── Acceptance/
├── docs/
├── Config/                         # per-cluster JSON config files
├── Examples/
└── Runbooks/
```

Folders that do not yet exist must be created by
`Tools\New-ClvProjectScaffold.ps1`, not by ad-hoc commits.

---

## 7. Orchestrator Phase Contract

`Invoke-clusterValidator.ps1` must execute the following phases in
order. Each phase appends structured records to the result accumulator
and emits a phase-complete log line.

1. PreFlight (modules + node reachability)
2. MPIO (global DSM claim)
3. Storage (per-node disk count + cross-node serial consistency)
4. SCSI3 (cluster reservation state)
5. Quorum (witness + quorum type) *— roadmap Phase 2*
6. Heartbeat (cluster network thresholds) *— roadmap Phase 2*
7. Time (W32Time skew) *— roadmap Phase 2*
8. Reboot (pending-reboot detection) *— roadmap Phase 2*
9. Hotfix (KB parity across nodes) *— roadmap Phase 2*
10. ServiceAccount (FCI service account hygiene) *— roadmap Phase 2*
11. TestCluster (Microsoft `Test-Cluster` invocation)
12. Persist (write JSON + HTML + transcript; emit Event Log)

Removing or reordering a phase requires a roadmap amendment and a
matching Static test update.

---

## 8. External-Cmdlet Wrapper Rule

The following high-blast-radius cmdlets must be invoked **only** from a
single private wrapper each, so they can be mocked in one place for
Pester and so their parameters can be hardened uniformly:

- `Test-Cluster`           → `Invoke-ClvTestCluster`
- `Invoke-Command`         → `Invoke-ClvRemote`
- `New-PSSession`          → `New-ClvNodeSession`
- `Get-ClusterLog`         → `Invoke-ClvForensicCapture`
- `Get-ClusterResource`    → `Get-ClvClusterResource`

No other function may call these cmdlets directly. The state checker
enforces this with a forbidden-call static test in
`Tests\Static\Test-ClvWrapperDiscipline.Tests.ps1`.

---

## 9. Read-Only Discipline

The cluster validator is a diagnostic tool. It is forbidden from
issuing any cmdlet that modifies cluster state, including but not
limited to:

- `Move-ClusterGroup`, `Move-ClusterSharedVolume`
- `Stop-ClusterResource`, `Start-ClusterResource`
- `Set-ClusterParameter`, `Set-ClusterQuorum`
- `Clear-ClusterDiskReservation`
- Any `sg_persist`, `clusdiag`, or raw SCSI PR command
- Any service control verb against cluster-relevant services

A static test enumerates these forbidden tokens and fails the build if
any appear. Forensic capture (`Get-ClusterLog`) is read-only and
explicitly allowed via its wrapper (§8).

---

## 10. Error Classification Rule

The orchestrator must classify every result with one of the following
explicit categories. Free-text statuses and ad-hoc severity strings are
not permitted.

- `ConnectionError`            (WSMan / PSSession / DCOM failures)
- `ModuleMissingError`         (FailoverClusters / MPIO / PowerCLI absent)
- `PermissionDenied`           (insufficient rights on a node or share)
- `StorageInventoryError`      (disk count diverges from `ExpectedDiskCount`)
- `StorageTopologyError`       (LUN serial sets diverge across nodes)
- `MpioConfigurationError`     (no global claim or wrong policy)
- `ReservationConflict`        (SCSI-3 / cluster reservation state bad)
- `QuorumStateError`           (witness offline, wrong quorum type)
- `ClusterHeartbeatError`      (non-default thresholds, lost heartbeats)
- `TimeSkewError`              (cross-node W32Time skew exceeds tolerance)
- `HotfixParityError`          (KB level diverges across nodes)
- `PendingRebootDetected`      (any node reports reboot pending)
- `ServiceAccountError`        (LocalSystem or mismatched FCI service account)
- `TestClusterFailure`         (Microsoft `Test-Cluster` reported a failure)
- `ConfigurationError`         (bad parameter, missing config file key)
- `HandledSkip`                (gating logic intentionally bypassed a phase)
- `Unknown`                    (must be transient; any occurrence is a bug)

Do not classify a missing module, an unreachable node, or an ACL
problem as a storage or cluster fault. Misclassification masks the
real signal in SIEM and is treated as a bug.

---

## 11. Artifact-First Auditability

Every run must produce a durable, structured artifact triad in
`<ReportPath>`:

- `ClusterValidation_<ts>.json`        — structured per-phase records
- `ClusterValidation_<ts>.html`        — Microsoft `Test-Cluster` report
- `ClusterValidation_<ts>_transcript.log` — full PowerShell transcript

Operational and audit reporting must be based on these durable
artifacts plus the Windows Event Log payload. Transient `Write-Host`
output is for interactive operators only and must never be the
authoritative record.

A correlation GUID (roadmap Phase 1) ties all three artifacts and
every Event Log record from a single run.

---

## 12. Change Discipline

Before any new feature work:

1. run the state checker (§2)
2. confirm the needed scaffold exists (§6)
3. add or update the atomic script or function (§1)
4. add or update the matching Pester coverage (§4)
5. rerun the state checker and the relevant test category
6. update `ClusterValidator-Roadmap.md` if a phase scope changes

This project favors small, verifiable steps over large unbounded
changes. A commit that touches the orchestrator without a matching
test commit (or in the same commit) will be rejected by the static
suite.
