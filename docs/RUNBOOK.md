# ClusterValidator Operator Runbook

Triage guide for `Invoke-ClusterValidator` results. Optimized for
on-call use: scan to your symptom, follow the action, escalate if the
fix is outside your authority.

---

## 1. Where the evidence lives

Every run produces four artifacts plus an optional Event Log entry,
all keyed by the same `CorrelationId` (a GUID printed at the top of
the run):

| Artifact | Path | Purpose |
|---|---|---|
| HTML | `<ReportPath>\ClusterValidation_<ts>.html` | Microsoft `Test-Cluster` report |
| JSON | `<ReportPath>\ClusterValidation_<ts>.json` | Per-phase records, machine-readable |
| Transcript | `<ReportPath>\ClusterValidation_<ts>_transcript.log` | Full PowerShell transcript |
| Cluster log | `<ReportPath>\<NodeName>_cluster.log` | Captured automatically on any Fail (Phase 12) |
| Event Log | Application / `ClusterValidator` source / Event ID 4001 | Compact JSON summary for SIEM |

**Always start with the JSON.** `Where-Object Status -eq 'Fail'` gives
you the exact phases that failed and their messages.

```powershell
Get-Content C:\Temp\ClusterValidation_*.json -Raw |
    ConvertFrom-Json |
    Where-Object Status -eq 'Fail'
```

---

## 2. Triage by phase

### Phase 1 — PreFlight Fail

| Message contains | Likely cause | Action |
|---|---|---|
| `Module 'FailoverClusters' missing` | RSAT Failover Clustering not installed on orchestrator | `Add-WindowsCapability -Online -Name 'Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0'` |
| `Module 'MPIO' missing` | MPIO feature not installed | `Install-WindowsFeature Multipath-IO` (Server) |
| `WSMan unreachable on <node>` | WinRM service stopped, firewall blocking 5985/5986, DNS, or auth failure | From orchestrator: `Test-WSMan -ComputerName <node> -ErrorAction Continue`. If error mentions auth, check `Get-WSManCredSSP`. |
| `PSSession failed for <node>` | Reachable but session-open failed: credential, double-hop, language-mode | If `-CredentialSecretName` was used, verify `Get-Secret -Name <name>` returns a `PSCredential` |
| `Fewer than two nodes reachable` | Multiple WSMan failures rolled into a single abort | Triage each `WSMan unreachable` message above |

### Phase 2 — MPIO Warn

| Message contains | Action |
|---|---|
| `No global MPIO load-balance policy is set` | `Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR` (or vendor recommendation). Validates non-destructively; rerun. |

### Phase 3 — Storage Fail

| Message contains | Likely cause | Action |
|---|---|---|
| `<node> sees N shared disks (expected M)` | LUN masking / zoning gap, or MPIO not claiming a path | Compare `Get-Disk` on the offending node vs a healthy peer; check SAN LUN masking; rescan with `Update-HostStorageCache`. |
| `Nodes report divergent LUN serial sets` | Some nodes see a LUN that others don't | Pull serials from each node's `Data` block in the JSON; cross-reference SAN zoning per-host. |

### Phase 4 — SCSI3 Fail

| Message contains | Likely cause | Action |
|---|---|---|
| `<resource> Failed; probable SCSI-3 reservation conflict` | Stuck PR, fenced node, or LUN that doesn't support SCSI-3 PR | Check `Get-ClusterResource <name> | Get-ClusterParameter` for fence state; coordinate with storage team to clear the reservation. **Never** issue `Clear-ClusterDiskReservation` without confirmed buy-in. |

### Phase 5 — Quorum Fail

| Message contains | Action |
|---|---|
| `Quorum type is X; expected Y` | Either the config's `-ExpectedQuorumType` is wrong for this cluster, or the cluster's quorum was changed. Confirm intended design before "fixing." |
| `Quorum witness '<name>' state=<not Online>` | Witness disk/share/cloud is offline. For disk witness: `Get-ClusterResource '<name>' | Start-ClusterResource` (after confirming it's safe). For file share: verify SMB share reachability from every node. |

### Phase 6 — Heartbeat Warn

| Message contains | Action |
|---|---|
| `Heartbeat thresholds below default` | Operator deliberately tuned aggressive thresholds → annotate config; otherwise restore defaults: `(Get-Cluster).SameSubnetThreshold = 10; (Get-Cluster).CrossSubnetThreshold = 20`. |

### Phase 7 — Time Fail

| Message contains | Action |
|---|---|
| `Cross-node time skew is Ns; tolerance is Xs` | Inspect `Data.Min` and `Data.Max` in JSON to identify the outlier node. On that node: `w32tm /resync /force`; check `w32tm /query /status`; verify the PDC emulator chain. |

### Phase 8 — Reboot Fail

| Message contains | Action |
|---|---|
| `<node> has pending reboot (CBS, WindowsUpdate, ...)` | Schedule a maintenance window; drain roles via `Move-ClusterGroup` (operator action, not validator) before rebooting. |

### Phase 9 — Hotfix Warn

| Message contains | Action |
|---|---|
| `Hotfix drift detected across nodes` | Inspect `Data` for per-node `Missing` lists. Run Windows Update on the lagging node(s); rerun validator. KB drift between SQL FCI nodes is a top driver of failover failures. |

### Phase 10 — ServiceAccount Warn

| Message contains | Action |
|---|---|
| `BuiltInAccount` (e.g. `LocalSystem`) | SQL or Cluster service running as a built-in account. Re-credential with a domain account or gMSA via SQL Configuration Manager. |
| `AccountMismatch` for `<service>` | Same service running as different accounts on different nodes. Pick the canonical account and reconfigure the outliers. |

### Phase 11 — TestCluster Fail

Open the **HTML report** at `Reports.Html`. Microsoft's report has the
detail for every sub-test. The `Data.Included` block in the JSON
record shows which categories ran.

### Phase 12 — Forensic

This phase is informational only. `Status = Info` means either:
- "No failures detected; forensic capture skipped" (clean run), or
- "Cluster log captured to <path> (last N minutes)" (failure detected
  upstream — go look at the per-node `*_cluster.log` files for
  Service Control Manager and FailoverClustering events near the
  failure timestamp).

---

## 3. Re-running with diagnostics

### Verbose output
```powershell
Import-Module .\ClusterValidator\ClusterValidator.psd1 -Force
$r = Invoke-ClusterValidator -Nodes 'n1','n2','n3','n4' `
                             -ConfigPath '.\Config\prod.json' `
                             -Verbose
```

### Drilling into a single phase
The validator does not support running an individual phase. To
isolate, set `-IncludeTests` to a minimal Microsoft set and let the
custom phases run normally; the JSON shows each phase independently.

### Bypass forensic capture
On a known-failing system you may not want a 60-minute cluster log
sweep on every run: `-ForensicCaptureMinutes 5`.

---

## 4. Common pitfalls

**Running inside SQLPS.exe.** SQLPS is the legacy SQL Agent
PowerShell host. It silently breaks `dbatools`, the FailoverClusters
module, and complex AST work. Always schedule the validator as a
**CmdExec** job step, never as PowerShell. Use
`Tools\Install-ClusterValidatorJob.ps1` to create the job correctly.

**Running without elevation.** The function has a runtime admin check
that throws `ConfigurationError`. The wrapper script has
`#Requires -RunAsAdministrator`. Both will fail clearly if invoked
without elevation.

**Constrained Language Mode.** WDAC/AppLocker enforcement that puts
the host in CLM will make the validator throw at preflight with the
exact remedy. Allowlist the signed module by publisher; do not
disable CLM.

**Stale `-ConfigPath`.** A config file lingering after a node rename
or ExpectedDiskCount change will silently mask drift. The validator
emits a PreFlight `Info` record listing exactly which keys came from
the file — eyeball it on every run.

**`-HardenReportAcl` on a shared dir.** Hardening removes inherited
ACEs and replaces them with `SYSTEM + Administrators`. If operators
need read access to the JSON, use a dedicated `<ReportPath>` that
they can be granted explicitly, not a directory shared with other
tooling.

---

## 5. Escalation

| Severity | Trigger | Route |
|---|---|---|
| Critical | Phase 4 SCSI3 Fail | Storage on-call (PR conflict can wedge a node) |
| Critical | Phase 5 Quorum Fail with witness offline | Cluster on-call |
| High | Phase 11 TestCluster Fail | Cluster on-call after reading the HTML |
| Medium | Phase 9 Hotfix Warn | Patch management team |
| Medium | Phase 10 ServiceAccount Warn (mismatch) | DBA + AD team |
| Low | Phase 6 Heartbeat Warn | Cluster team during business hours |

---

## 6. Re-running after a fix

```powershell
.\Invoke-clusterValidator.ps1 -Nodes 'n1','n2','n3','n4' `
                              -ConfigPath '.\Config\prod.json' `
                              -WriteEventLog
```

Exit code: `0` clean run; `1` any Fail. SQL Agent CmdExec maps non-zero
to job failure automatically.
