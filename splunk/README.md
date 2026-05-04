# ClusterValidator — Splunk integration

Ready-to-import artifacts for ingesting `Invoke-ClusterValidator`
output into Splunk and surfacing failures on a dashboard / via alerts.

These are skeletons: tested for syntactic correctness and structured
per Splunk's standard `default/local` conventions. **A Splunk admin
should review each `.conf` before deployment** — index names,
`sourcetype` overrides, and authentication choices are environment-
specific and intentionally left as placeholders.

---

## Two ingestion paths

The validator emits its data in two places. Pick whichever (or both)
fits your collection topology.

### Path A — Windows Event Log (compact summary, 1 event per run)

The validator writes a single Event ID **4001** to the Application
log under source **`ClusterValidator`** when invoked with
`-WriteEventLog`. The Message field holds a compact JSON payload:

```json
{
  "CorrelationId": "<guid>",
  "Nodes":         ["n1", "n2", "n3", "n4"],
  "Summary":       [{"Pass": 38}, {"Fail": 2}, {"Info": 4}],
  "Reports":       {"Html": "...", "Json": "...", "Transcript": "..."}
}
```

Pros: single event per run, easy to alert on, no file-tail concerns.
Cons: no per-phase / per-category detail — you have to follow the
`Reports.Json` path to drill in.

### Path B — JSON artifact files (full per-result detail)

The validator writes `ClusterValidation_<ts>.json` to `<ReportPath>`
on every run. Each file is a JSON array of N result records, each
with `CorrelationId`, `Phase`, `Status`, `Category`, `Message`,
and structured `Data`.

Pros: full detail, per-phase + per-category facetability.
Cons: file tailing setup; one event per file by default (use
`spath` + `mvexpand` to fan out at search time).

The dashboard and alerts in this folder use **Path A** (Event Log
summary) because that's the most common deployment shape. Path B is
provided as a sample input stanza for shops that want the rich data.

---

## Files

```text
splunk/
├── README.md                   you are here
├── inputs.conf.example         UF stanzas - both paths, copied to a UF
├── props.conf                  parsing for the JSON-array sourcetype
├── transforms.conf             field aliases + a SourceName→sourcetype rule
├── eventtypes.conf             clustervalidator_fail / _pass / _warn
├── tags.conf                   ties eventtypes to the cluster_health tag
├── savedsearches.conf          alert on any Fail in the last hour
└── dashboards/
    └── cluster_validator.xml   Simple XML dashboard
```

---

## Deployment outline

1. **Distribute the `.conf` files** to your Splunk indexer/search head
   tier. The conventional shape is to wrap them as a Splunk app
   (`$SPLUNK_HOME/etc/apps/ClusterValidator-TA/default/`). The files
   in this folder are the `default/` payload.
2. **Distribute `inputs.conf.example`** to the Universal Forwarder on
   each cluster orchestration host. Copy it to
   `$SPLUNK_HOME/etc/apps/ClusterValidator-Inputs/local/inputs.conf`,
   uncomment the path that matches your topology, and set the index
   name.
3. **Import the dashboard** via Settings → User Interface → Views
   → Import, or drop `dashboards/cluster_validator.xml` into the app's
   `default/data/ui/views/` folder.
4. **Enable the saved-search alert** via Settings → Searches, Reports,
   and Alerts and confirm the alert action targets your operator
   on-call channel (PagerDuty, ServiceNow, email).

---

## Index naming

Examples below assume a dedicated index named **`cluster_health`**.
Create it via Settings → Indexes → New Index, or your standard
infrastructure-as-code workflow. Adjust every `index=cluster_health`
reference if you use a different name.

---

## Search examples

**Last 24h failures, grouped by category:**
```spl
index=cluster_health sourcetype="WinEventLog:Application" SourceName="ClusterValidator"
| spath input=Message
| stats count by Summary
```

**Drill into a specific run by correlation GUID:**
```spl
index=cluster_health
| spath CorrelationId
| search CorrelationId="abc-123-..."
```

**Failure rate by cluster (using ComputerName as proxy):**
```spl
index=cluster_health eventtype=clustervalidator_fail
| stats count by ComputerName
| sort -count
```
