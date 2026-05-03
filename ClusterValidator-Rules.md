# Invoke-clusterValidator Development Rules

Engineering quality rules for `Invoke-clusterValidator.ps1`. Every rule
below is a quality gate, not project-management overhead. Companion
document: `ClusterValidator-Roadmap.md`.

---

## 1. Atomic Scripts

Helper logic is split into atomic scripts:

- One script does one clear task.
- Runnable on its own with explicit parameters.
- No hidden context, no implicit working directory.
- State-checks before any side effect.
- Reports exactly what it changed.
- Independently testable with Pester.

`Invoke-clusterValidator.ps1` is the orchestrator. Anything reusable,
mockable, or independently testable becomes its own script.

---

## 2. No `$PSScriptRoot` (script-context only)

`$PSScriptRoot` resolves differently under dot-sourcing, jobs, remoting,
and SQL Agent CmdExec. Forbidden in script files (`.ps1`). Use explicit
parameters instead:

```powershell
param([string]$ProjectRoot)
```

**Carve-out:** module loader files (`.psm1`) MAY use `$PSScriptRoot` —
it is the canonical idiom for resolving sibling `Public/` and
`Private/` folders during `Import-Module`, and the dot-sourcing /
remoting / CmdExec hazards above do not apply to module load (modules
are loaded via `Import-Module`, not script execution).

The static test enforces this with an AST scan that excludes `.psm1`
files.

---

## 3. Pester Coverage

Every script must have matching coverage in two categories at minimum:

- **Static** — script parses, required parameters present, no
  `$PSScriptRoot`, every error category from §6 referenced in the
  classifier, Authenticode signature present on release branches.
- **Unit** — pure logic (LUN serial diff, time-skew math, hotfix-parity
  diff, classification mapping) tested with mocked inputs, covering both
  the success path and the handled-failure path.

Integration and acceptance categories are added when the wrapped
external cmdlets (§5) gain non-trivial behavior worth recording as
fixtures.

A test that only exercises the happy path is incomplete.

---

## 4. Orchestrator Phase Contract

`Invoke-clusterValidator.ps1` executes phases in this order. Each phase
appends structured records to the result accumulator and emits a
phase-complete log line.

1. PreFlight — modules + node reachability + reusable PSSessions
2. MPIO — global DSM claim
3. Storage — per-node disk count + cross-node serial consistency
4. SCSI3 — cluster reservation state
5. Quorum — witness + quorum type
6. Heartbeat — cluster network thresholds
7. Time — cross-node W32Time skew
8. Reboot — pending-reboot detection on every node
9. Hotfix — KB parity across nodes
10. ServiceAccount — Cluster + SQL service account hygiene
11. VMware — DRS anti-affinity (optional; gated on PowerCLI + `-VCenterServer`)
12. TestCluster — Microsoft `Test-Cluster`
13. Forensic — `Get-ClusterLog` capture, triggered only on Fail
14. Persist — JSON + HTML + transcript + Event Log

Reordering or removing a phase requires a roadmap amendment and a
matching static test update.

---

## 5. External-Cmdlet Wrappers

High-blast-radius cmdlets are called from one place each, so they can
be mocked uniformly in tests and hardened uniformly in production:

- `Test-Cluster`        → `Invoke-ClvTestCluster`
- `Invoke-Command`      → `Invoke-ClvRemote`
- `Get-ClusterResource` → `Get-ClvClusterResource`

Direct calls outside the wrapper are rejected by a forbidden-call
static test.

---

## 6. Read-Only Discipline

The cluster validator is a diagnostic tool. It must not call any
cluster-mutating cmdlet, including:

- `Move-ClusterGroup`, `Move-ClusterSharedVolume`
- `Start-ClusterResource`, `Stop-ClusterResource`
- `Set-ClusterParameter`, `Set-ClusterQuorum`
- `Clear-ClusterDiskReservation`
- Raw SCSI PR commands (`sg_persist`, `clusdiag`, etc.)
- Service control verbs against cluster-relevant services

A static test fails the build on any of those tokens. `Get-ClusterLog`
is read-only and is the one allowed forensic-capture path, behind its
wrapper.

---

## 7. Error Classification

Every result record uses exactly one of these categories. Free-text
statuses and ad-hoc severity strings are rejected.

- `ConnectionError` — WSMan / PSSession / DCOM
- `ModuleMissingError` — FailoverClusters / MPIO / PowerCLI absent
- `PermissionDenied` — rights on a node or share
- `StorageInventoryError` — disk count diverges from `ExpectedDiskCount`
- `StorageTopologyError` — LUN serial sets diverge across nodes
- `MpioConfigurationError` — no global claim or wrong policy
- `ReservationConflict` — SCSI-3 / cluster reservation state bad
- `QuorumStateError` — witness offline or wrong quorum type
- `ClusterHeartbeatError` — non-default thresholds or lost heartbeats
- `TimeSkewError` — cross-node W32Time skew exceeds tolerance
- `HotfixParityError` — KB level diverges across nodes
- `PendingRebootDetected` — any node reports reboot pending
- `ServiceAccountError` — `LocalSystem` or mismatched FCI account
- `AffinityViolation` — VMware DRS anti-affinity violation (FCI VMs colocated on one ESXi host, or no enabled DRS rule)
- `TestClusterFailure` — Microsoft `Test-Cluster` reported a failure
- `ConfigurationError` — bad parameter or missing config key
- `HandledSkip` — gating logic intentionally bypassed a phase
- `Unknown` — must be transient; any occurrence is a bug

A missing module, unreachable node, or ACL issue must never be filed as
a storage or cluster fault. Misclassification masks SIEM signal and is
treated as a bug.

---

## 8. Artifact-First Auditability

Every run produces a durable triad in `<ReportPath>`:

- `ClusterValidation_<ts>.json` — structured per-phase records
- `ClusterValidation_<ts>.html` — `Test-Cluster` report
- `ClusterValidation_<ts>_transcript.log` — full transcript

Audit and operational reporting are based on these artifacts plus the
Windows Event Log payload. `Write-Host` output is for interactive
operators only and is never the authoritative record. A correlation
GUID (roadmap Phase 1) links all three artifacts and every Event Log
record from a single run.

---

## 9. Change Discipline

A change to the orchestrator ships in the same commit (or commit pair)
as the matching test change. The progression is:

1. Add or update the atomic script.
2. Add or update its test.
3. Run the affected test category locally.
4. Update `ClusterValidator-Roadmap.md` if a phase's scope changes.

Small, verifiable steps over large unbounded changes.

---

## 10. Module Evolution Trigger — **FIRED**

Triggered at the end of roadmap Phase 4: 13 phases (passed 12), 790
lines (within 10 of 800), and helpers genuinely reusable by sibling
scripts. The validator is now packaged as the **ClusterValidator**
module (`ClusterValidator.psd1` + `ClusterValidator.psm1` + `Public/`
+ `Private/`). The root `Invoke-clusterValidator.ps1` survives as a
back-compat wrapper that forwards `$args` to `Invoke-ClusterValidator`.

The remaining trigger signals (signed-package distribution, CLM
allowlisting at module identity) are roadmap Phase 5 deliverables.

§§11–13 below capture the rules that activate now that the module
shape exists.

---

## 11. Public Function Contract

The module exports exactly:

- **`Invoke-ClusterValidator`** — the orchestrator (1.0.0+)
- **`Test-ClusterValidatorConfig`** — static lint of a config file
  against the orchestrator's parameter schema (1.3.0+)

The manifest's `FunctionsToExport` lists each name explicitly — never
`*`. `CmdletsToExport`, `VariablesToExport`, and `AliasesToExport` are
explicit empty arrays so nothing leaks accidentally.

Private helpers live under `Private/` and use the **`Clv`** namespace
prefix (`Add-ClvResult`, `Invoke-ClvRemote`, `Get-ClvTimeSkew`,
`Get-ClvHostColocation`, etc.) so they are recognizable if they leak
into a host's session via misuse of `-Scope Global`. Public functions
do **not** carry the `Clv` prefix — they use the full
`ClusterValidator` brand.

Adding a new public function or alias requires a CHANGELOG entry and
a `FunctionsToExport` update in the same commit. The Static loader
test enforces that the manifest list and the actual exported set
match.

---

## 12. Manifest Discipline

- `ModuleVersion` follows **semver**. Bump major on breaking parameter
  changes, minor on new phases or new public surface, patch on
  bugfixes and doc edits.
- `RequiredModules` enumerates every external module the public
  function calls. We do not rely on implicit availability.
- `FunctionsToExport`, `CmdletsToExport`, `VariablesToExport`,
  `AliasesToExport` are explicit lists — never `*`, never omitted.
- `GUID` is generated once at module birth and never changes.
- `PowerShellVersion` matches the lowest host we will ever run on.

The static test parses the manifest and verifies all of the above.

---

## 13. Loader Test

A static test imports the module fresh (`Import-Module -Force`) in a
clean runspace and asserts:

- the manifest parses without errors
- `Invoke-ClusterValidator` is exported
- nothing else is exported (no private helper leaks via `Set-Alias`,
  no accidental `-Scope Global` writes during dot-source)
- loading the module is idempotent (a second `Import-Module -Force`
  does not double-register handlers or duplicate exports)
