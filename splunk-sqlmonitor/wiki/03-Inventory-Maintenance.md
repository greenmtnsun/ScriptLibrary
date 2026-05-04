# 03 — Inventory Maintenance

The CSV at `sql_inventory.csv` (uploaded into Splunk as the `sql_inventory_lookup` lookup) is the authoritative list of SQL hosts this stack monitors. **A host that is not in the CSV will not appear in any dashboard or alert.** That's intentional.

## Schema

```
host,fqdn,env,role,ag_cluster,owner,tier
SQLPRD01,SQLPRD01.corp.local,prod,ag-primary,PRD-AG01,dba-team,1
```

| Field | Required | Allowed values | Used for |
|---|---|---|---|
| `host` | yes | lowercased short hostname (see "Host matching" below) | Join key against event field |
| `fqdn` | no | full DNS name | Display only |
| `env` | yes | `dev`, `test`, `stage`, `prod` | Filtering, alert routing, severity |
| `role` | yes | `standalone`, `ag-primary`, `ag-secondary`, `fci-active`, `fci-passive` | Display, AG panels |
| `ag_cluster` | conditional | AG/cluster name; blank for standalone | AG panels grouping |
| `owner` | yes | team/individual handle | Alert routing, ticket assignment |
| `tier` | yes | `1` (most critical) – `3` (least) | Used by tuning to differ thresholds (optional) |

## Host matching — the most important detail

Splunk events from a Windows Universal Forwarder normally carry both:
- `host` (the indexer's metadata field, often the short hostname)
- `ComputerName` (extracted from the Windows event payload, often FQDN)

The dashboards and alerts normalise via:
```spl
| eval host=lower(coalesce(ComputerName,host))
```

To verify what value lands in your tenant, run:
```spl
eventtype=sql_engine_events | stats count by host, ComputerName
```

Whichever value is consistent — **lowercased** — is what goes in the CSV's `host` column.

If your forwarders send FQDN as `host`, populate the CSV's `host` column with the FQDN (still lowercased). The lookup is configured `case_sensitive_match = false`, but lowercasing in the CSV avoids relying on that.

## Adding a server

1. Edit `sql_inventory.csv`. Append a new row.
2. Splunk Web: **Settings → Lookups → Lookup table files → Edit `sql_inventory.csv`** → paste the row → Save.
   - File-system alternative: replace `$SPLUNK_HOME/etc/apps/<APP>/lookups/sql_inventory.csv`.
3. No restart required. Lookups are re-read on every search.
4. Verify:
   ```
   | inputlookup sql_inventory_lookup | search host=newserver
   ```
5. Within the next forwarded event window, the new host should appear in the dashboards.

## Removing a server (decommission)

1. Delete the row from the CSV. Save.
2. The host disappears from dashboards. Past events still exist in the index but are no longer enriched with `env`, so they're filtered out by `where isnotnull(env)`.
3. Optionally check the **Silent Inventoried Server** alert isn't already firing on it before deletion.

## Bulk update / replace

```bash
# Pull current inventory
splunk search "| inputlookup sql_inventory_lookup | outputcsv sql_inventory.csv" -auth admin:...
# Edit
# Push
splunk search "| inputlookup mynew.csv | outputlookup sql_inventory_lookup" -auth admin:...
```

Or via REST: `POST /servicesNS/<user>/<app>/data/lookup-table-files/sql_inventory.csv` with the file body.

## Validation

After any change run:
```spl
| inputlookup sql_inventory_lookup
| eval problems=case(
    isnull(host) OR host=="","missing host",
    isnull(env) OR NOT env IN ("dev","test","stage","prod"),"bad env",
    role=="ag-primary" OR role=="ag-secondary" AND (isnull(ag_cluster) OR ag_cluster==""),"AG role without ag_cluster",
    isnull(owner) OR owner=="","missing owner",
    1=1,"ok")
| stats count by problems
```

Should return only `problems=ok`.
