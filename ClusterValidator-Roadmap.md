# Invoke-clusterValidator — Enterprise Readiness Roadmap

Phased plan to take `Invoke-clusterValidator.ps1` from a working SAN/FCI
validation script to a fleet-deployable, auditable, signed enterprise tool.
Each phase is independently shippable and gated on the prior phase's
acceptance criteria.

---

## Status snapshot

| Phase | State | Notes |
|-------|-------|-------|
| 0 Baseline | ✅ done | |
| 1 Audit & Observability | ✅ done | correlation GUID, transcript, WSMan, reusable PSSessions |
| 2 Validation Depth | ✅ done | 6 new phases + Forensic capture |
| 3 Security Hardening | ✅ done | CLM preflight, SecretManagement, ACL hardening |
| 4 Scale & Operability | ✅ done (partial) | ConfigPath, parallel Storage, pure helpers, Pester unit suite. Deferred: optional PowerCLI VMware check |
| 5 Release & Fleet Rollout | ✅ done (partial) | v1.0.0 tag, CHANGELOG, RUNBOOK, SQL Agent job installer, GitHub Actions Pester workflow. Deferred (require external infra): signed-package distribution, SIEM dashboard, deployment vehicle (DSC/SCCM/Ansible) |

Module promotion (Rules §10) **fired** at the end of Phase 4. Code now
ships as the **ClusterValidator** module under `.\ClusterValidator\`.
The original `Invoke-clusterValidator.ps1` survives at the repo root
as a back-compat wrapper that forwards `$args` to
`Invoke-ClusterValidator`. From this point on, the public surface is
the function, not the script.

---

## Phase 0 — Baseline (complete)

**State on commit `c62f675`:**
- Parameterized inputs, pre-flight checks, MPIO, storage inventory,
  cross-node LUN serial consistency, non-destructive SCSI-3 interrogation,
  `Test-Cluster` invocation, JSON + HTML output, optional Event Log,
  non-zero exit on Fail.

**Known gaps:** no correlation ID, ICMP-based reachability, sequential
remote calls, no transcript, no quorum / time / hotfix checks, no signing,
no tests.

---

## Phase 1 — Audit & Observability

**Goal:** every run produces a complete, correlatable audit trail that a
SOC / SRE can ingest without parsing free-form host output.

**Deliverables**
- `#Requires -Version 5.1 -RunAsAdministrator -Modules FailoverClusters,MPIO`
- `[CmdletBinding()]` on the script for `-Verbose` / `-Debug` plumbing
- Correlation GUID generated at start, stamped on every result record and
  every Event Log payload
- `Start-Transcript` to `<ReportPath>\ClusterValidation_<ts>_transcript.log`,
  guaranteed `Stop-Transcript` in `finally`
- Replace `Test-Connection` with `Test-WSMan -ComputerName $node -ErrorAction Stop`
  (ICMP is often blocked and does not predict remoting success)
- One `New-PSSession` per reachable node with explicit
  `-OperationTimeout`/`-OpenTimeout`; reused across phases; torn down in
  `finally`

**Acceptance criteria**
- A single Splunk / Sentinel query on the correlation GUID returns the full
  per-run timeline across all four nodes.
- Killing a single node mid-run does not stall the script beyond the
  configured operation timeout.
- Transcript file exists for every run, even on uncaught exception.

**Effort:** ~1 day. No new module dependencies.

---

## Phase 2 — Validation Depth

**Goal:** catch the cluster failure modes that bite SQL FCI teams in
production but the current script does not test.

**Deliverables**
- Quorum & witness: `Get-ClusterQuorum`, fail if witness state is not
  `Online` or quorum type does not match an `-ExpectedQuorumType` parameter
- Cluster network heartbeat thresholds: read `SameSubnetThreshold`,
  `CrossSubnetThreshold`, `RouteHistoryLength`; warn on non-default values
- W32Time skew: pull system time from each node in a single round-trip,
  fail if max-min skew > configurable tolerance (default 2s)
- Pending reboot detection: CBS RebootPending, WindowsUpdate RebootRequired,
  PendingFileRenameOperations, ClusterServiceState
- Hotfix parity: `Get-HotFix` per node, diff against node 0; warn on any
  node missing a KB another node has
- Service account hygiene: SQL Server / SQL Agent / Cluster service account
  per node, flag `LocalSystem` or mismatched accounts across the FCI
- Forensic capture on Fail: `Get-ClusterLog -Destination $ReportPath -TimeSpan 60`
  triggered automatically when any phase records a `Fail`

**Acceptance criteria**
- Synthetic test harness (Phase 4 Pester) covers each new check with at
  least one Pass and one Fail mock.
- Roadmap doc updated with the canonical failure signatures each check
  catches.

**Effort:** ~2-3 days. No new module dependencies.

---

## Phase 3 — Security Hardening

**Goal:** safe to deploy under a constrained service identity, with
non-repudiation suitable for SOX / regulated workloads.

**Deliverables**
- `-Credential [PSCredential]` parameter, sourced from
  `Microsoft.PowerShell.SecretManagement` (`Get-Secret -Name ClusterValidator`);
  passed to `New-PSSession` / `Invoke-Command`
- Constrained Language Mode preflight: if
  `$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'`, exit
  cleanly with a precise diagnostic instead of partial-run
- Code signing: sign the script with the internal PKI cert; document the
  AllSigned execution policy expectation in `.NOTES`
- Report directory ACL hardening: on first write, set the `<ReportPath>`
  DACL to `Administrators + SYSTEM` only (the JSON contains LUN serials,
  node topology, and account names)
- Remove any `Write-Host` color writes from non-interactive paths; route
  human-readable output through `Write-Verbose` / `Write-Information`

**Acceptance criteria**
- Script executes under a gMSA mapped to a non-`sysadmin` SQL login with
  only `SQLAgentReaderRole` + `VIEW SERVER STATE`.
- Tampering with a single byte invalidates the Authenticode signature and
  PowerShell refuses to load the script under `AllSigned`.
- Report files inherit the hardened ACL and a non-admin local user cannot
  enumerate them.

**Effort:** ~2 days plus PKI ticket lead time.

---

## Phase 4 — Scale & Operability

**Goal:** runs against multiple FCIs from one orchestrator, in CI, in
under half the wall-clock time of the current sequential implementation.

**Deliverables**
- Parallelize per-node phases:
  - PS 7+: `ForEach-Object -Parallel -ThrottleLimit $Nodes.Count`
  - PS 5.1 fallback: `Invoke-Command -AsJob` + `Wait-Job`/`Receive-Job`
  - Detect host version once, branch internally; preserve identical
    structured output
- JSON-driven config: `-ConfigPath cluster-prod-01.json` containing
  `Nodes`, `ExpectedDiskCount`, thresholds, expected hotfix baseline,
  expected service accounts; CLI parameters override config keys
- Pester v5 test suite under `tests/Invoke-clusterValidator.Tests.ps1`:
  - Mock `Invoke-Command`, `Get-ClusterResource`, `Get-ClusterQuorum`,
    `Get-MSDSMGlobalDefaultLoadBalancePolicy`, `Test-Cluster`
  - One Pass and one Fail path per phase
  - Run in GitHub Actions on every push to a `claude/*` or `main` branch
- Optional VMware anti-affinity / DRS rule check, gated on PowerCLI being
  present (no hard dependency)

**Acceptance criteria**
- 4-node validation completes in under 60s wall-clock on a healthy cluster
  (down from ~3-4 min sequential).
- CI red-green gate: a deliberately broken commit fails Pester within 30s.
- Same script binary validates two distinct FCIs by swapping `-ConfigPath`
  with no edits.

**Effort:** ~3-4 days. New dev-time dependency on Pester 5; optional
runtime dependency on PowerCLI.

---

## Phase 5 — Release & Fleet Rollout

**Goal:** signed artifact lands on every database server in the fleet via
the standard configuration channel, schedules itself, and feeds the
existing operational dashboard.

**Deliverables**
- Versioned release: `git tag v1.0.0`, semver thereafter; `CHANGELOG.md`
  updated per release
- Signed `.ps1` published to the internal package feed (Artifactory /
  ProGet / Azure Artifacts)
- Deployment vehicle (pick one, document the choice):
  - PowerShell DSC `Script` resource pulling from the package feed
  - SCCM / Intune package
  - Ansible play
- SQL Agent CmdExec job template (`tools/Install-ClusterValidatorJob.ps1`)
  that creates the schedule, sets the gMSA proxy, and points at the
  installed script path
- SIEM dashboard: Splunk / Sentinel saved search keyed on
  `ClusterValidator` event source, broken down by correlation GUID and
  cluster name; alert rule on any `Fail` payload
- Operator runbook (`docs/RUNBOOK.md`) covering: how to read the JSON,
  what each Fail signature means, escalation paths, how to re-run with
  `-Verbose -Debug` for triage

**Acceptance criteria**
- New cluster onboarding is one PR (config file) + one DSC apply.
- A red dashboard tile maps to a documented runbook step within two
  clicks.
- Rollback to a prior signed version is a single package-feed pin change.

**Effort:** ~1 week, mostly cross-team coordination (PKI, packaging,
SIEM, on-call).

---

## Cross-cutting non-goals

Explicitly **out of scope** for this roadmap, to avoid scope creep:
- Active remediation (the script never restarts services, fails resources
  over, or rewrites cluster config — diagnosis only).
- Raw SCSI PR command issuance (`sg_persist`, `clusdiag`) — we rely on
  the cluster API's reservation bookkeeping by design.
- Replacing `Test-Cluster` — it remains the source of truth for the
  Microsoft-supported validation matrix; this script wraps and augments
  it, never supplants it.

---

## Sequencing summary

| Phase | Wall time | Dependencies | Ship-blocker if skipped? |
|-------|-----------|--------------|--------------------------|
| 1 Audit & Observability | ~1d | none | yes — required for SIEM |
| 2 Validation Depth      | ~2-3d | Phase 1 transcript | no, but recommended before fleet rollout |
| 3 Security Hardening    | ~2d + PKI | Phase 1 | yes — required for prod gMSA |
| 4 Scale & Operability   | ~3-4d | Phase 1 sessions | no, but required for >4 clusters |
| 5 Release & Fleet       | ~1w | Phase 3 signing, Phase 4 tests | yes for fleet rollout |
