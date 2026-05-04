# ScriptLibrary

Personal collection of production PowerShell scripts and modules for SQL
Server / Windows Server administration.

## Contents

### Modules

- **`ClusterValidator/`** — Multi-phase health validator for Windows
  Server failover clusters hosting SQL Server FCI workloads on
  traditional SAN/VMware topologies. 14 validation phases (storage,
  MPIO, SCSI-3 reservation, quorum, heartbeat, time skew, hotfix
  parity, service-account hygiene, VMware DRS anti-affinity, plus the
  official Microsoft `Test-Cluster` suite). Two exported functions:
  `Invoke-ClusterValidator` and `Test-ClusterValidatorConfig`. See
  [`ClusterValidator-Roadmap.md`](ClusterValidator-Roadmap.md),
  [`ClusterValidator-Rules.md`](ClusterValidator-Rules.md), and
  [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

### Scripts

- **`Invoke-clusterValidator.ps1`** — Back-compat wrapper that imports
  the `ClusterValidator` module and forwards `$args` to
  `Invoke-ClusterValidator`. Lets legacy SQL Agent CmdExec steps that
  reference the original script name keep working unchanged.

- **`Invoke-TelemetryANDAnomoly.ps1`** — SQL Server Agent job
  telemetry and runaway-detection script. Identifies actively running
  jobs, detects blocking-chain "stuck" conditions via DMVs, and uses
  the Median Absolute Deviation + Modified Z-score (Iglewicz/Hoaglin)
  to detect "runaway" jobs whose current duration anomalously exceeds
  the historical baseline. Writes structured payloads to the Windows
  Event Log under source `SQLAgentTelemetry`. See companion essay
  [`AgentReadMe.md`](AgentReadMe.md).

- **`Export-Wiki.ps1`** — Defines `Export-HardenedWiki`, a PlatyPS-based
  wiki generator that AST-scans a script for function definitions and
  emits per-function Markdown documentation with SHA256 traceability.
  *(Currently uses the `??` null-coalescing operator which is PS 7+
  only; needs a PS 5.1 fix before reuse.)*

### Documentation

- **`AgentReadMe.md`** — Long-form architectural essay on SQL Agent
  telemetry: native SQL Agent limitations, the integer-formatted
  duration problem, runaway vs stuck job differentiation, and the
  statistical case for MAD over standard Z-score on right-skewed
  job-duration distributions.

- **`docs/AgentWatchdog/Wiki.html`** — Static HTML export of the
  AgentWatchdog wiki.

- **`docs/AgentWatchdog/ProjectWiki.md`** — Plain-text project wiki
  for AgentWatchdog.

- **`docs/RUNBOOK.md`** — Operator triage guide for `Invoke-ClusterValidator`
  failures.

### Tooling and integration

- **`Tools/Invoke-ClvPester.ps1`** — Pester 5.x runner for the
  `Tests/{Static,Unit,Integration}` suites.

- **`Tools/Install-ClusterValidatorJob.ps1`** — Idempotent SQL Agent
  CmdExec job installer for scheduling `Invoke-ClusterValidator`.
  Supports `-DryRun` to preview T-SQL.

- **`Config/example.json`** — Per-cluster config template consumed
  via `Invoke-ClusterValidator -ConfigPath`.

- **`splunk/`** — Splunk integration package: Universal Forwarder
  inputs, parsing config (props/transforms), eventtypes, tags, three
  saved-search alerts, and a Simple XML dashboard. Cluster-validator
  output is keyed on a `CorrelationId` GUID for SIEM filtering. See
  [`splunk/README.md`](splunk/README.md).

### Tests

- **`Tests/Static/`** — AST/structural assertions: parse, parameter
  shape, phase order, wrapper presence, forbidden-cmdlet sweep,
  manifest discipline, no `$PSScriptRoot` outside `.psm1`.
- **`Tests/Unit/`** — pure-logic helpers via `InModuleScope`.
- **`Tests/Integration/`** — end-to-end orchestrator runs with every
  external cmdlet mocked; per-phase Pass/Fail simulations.

### CI

- **`.github/workflows/pester.yml`** — Static + Unit suites on every
  push to `main` or `claude/*`. `windows-latest` runner, best-effort
  install of the Failover-Clustering Windows feature.

## Conventions

This repo follows the engineering rules in
[`ClusterValidator-Rules.md`](ClusterValidator-Rules.md), originally
written for the cluster validator but applicable across the library:
atomic scripts, no `$PSScriptRoot` outside module loaders, Pester
coverage with both happy-path and handled-failure cases, structured
result categories from a closed vocabulary, artifact-first
auditability over transient `Write-Host` output, and small verifiable
commits over large speculative ones.

## See also

- [`CHANGELOG.md`](CHANGELOG.md) — versioned release notes for the
  ClusterValidator module (v1.0.0 onward).
