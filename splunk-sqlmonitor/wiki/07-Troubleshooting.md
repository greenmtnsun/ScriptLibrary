# 07 — Troubleshooting

Symptoms, causes, fixes — in order of how often I've seen them.

## "All panels are empty"

1. **Lookup not loaded.** Run `| inputlookup sql_inventory_lookup`. If "Could not find lookup table file": go back to `DEPLOY.md` Step 2.
2. **Eventtypes don't match anything.** Run each one bare:
   ```
   eventtype=sql_engine_events | head 1
   ```
   Empty? You probably have a non-default index. Edit `eventtypes.conf` and prepend `index=<name>`. See `DEPLOY.md` Step 3.
3. **Time range too narrow.** Switch picker to "Last 24h".
4. **You don't have permission to the index.** Check role grants: `| rest /services/authorization/roles | search title=<your_role> | table title srchIndexesAllowed`.

## "Servers In Scope = 18 but Servers Reporting = 0"

The lookup is loading, but the join `host=<inventory>.host` ↔ event field finds nothing.

Diagnose:
```spl
eventtype=sql_engine_events | stats count by host, ComputerName | head 10
```

Cases:
- Events have `host=sqlprd01.corp.local` but inventory has `host=SQLPRD01` — mixed FQDN/short. Lowercase + decide one form. Lookup is `case_sensitive_match=false` so case is fine, but `sqlprd01` ≠ `sqlprd01.corp.local`.
- Events come in with empty `ComputerName` — depends on UF version. The dashboards use `coalesce(ComputerName,host)` so `host` should still hit.
- Events from a server are missing entirely — UF down on those hosts. See "Silent Server" in `05-Alert-Runbook.md`.

## "Silent Servers KPI is wrong / counts hosts that ARE reporting"

This panel uses a `join` between inventory and a count-by-host subsearch. Subsearches are capped at 50,000 rows / 60s by default. If your fleet is much larger, replace with:

```spl
| inputlookup sql_inventory_lookup | search $env_tok$ | fields host
| eval reporting=0
| append [
    search eventtype=sql_engine_events OR eventtype=sql_agent_events OR eventtype=sql_service_events OR eventtype=sql_custom_telemetry
    | eval host=lower(coalesce(ComputerName,host))
    | stats count by host
    | eval reporting=1
    | fields host reporting
  ]
| stats max(reporting) as reporting by host
| where reporting=0
| stats count
```

## "Login user / client IP columns are blank in Security dashboard"

Those fields are extracted via `rex` against `Message`. Microsoft has changed the wording across SQL versions:
- 2014–2017: `Login failed for user 'X'.  Reason: ...  [CLIENT: 1.2.3.4]`
- 2019+: similar but sometimes extra trailing content.

If empty for many events, dump a few raw samples:
```spl
eventtype=sql_engine_events EventCode=18456 | head 3 | table _raw
```

Adjust the regex in the dashboard's base search to match what you see. The current regex covers the standard formats.

## "Studio dashboard shows 'No data' but the same SPL works in the search bar"

- Confirm the time-range token wiring in **Inputs**. The Studio JSON binds the timepicker to `tr.earliest` / `tr.latest`. If you renamed the input token, every datasource needs the new name.
- Confirm `ds.chain` parents exist. If you renamed `ds_base`, every `ds.chain` extending it must update.
- Open the Studio editor, click each panel → "Search" tab → click **Open in Search**. That runs the actual final search and you'll see any error.

## "Alert fires but no email"

- `sendmail` not configured at the Splunk level. **Settings → Server settings → Email settings**.
- `action.email = 1` not set. Default in our file is `0` so you can opt in per alert.
- Check `_audit` index:
  ```
  index=_audit action=alert_fired ss_name="SQL - *"
  ```
- Check `splunkd.log` for sendemail errors.

## "Alert fires constantly"

- Tune (see `06-Tuning-Guide.md`).
- Check the throttle (`alert.suppress.fields`). If suppression key is `host` but the alert genuinely fires on many hosts, you'll still get many alerts (one per host) — that's working as intended; consider routing by env instead.

## "The wiki tells me to run `splunk restart` — can I avoid it?"

Most config changes can be reloaded via the REST API instead:

| Object | Reload endpoint |
|---|---|
| Lookups (CSV) | None needed — re-read each search |
| `transforms.conf` | `POST /services/admin/transforms/reload` |
| `eventtypes.conf` | `POST /services/admin/eventtypes/_reload` |
| `savedsearches.conf` | `POST /services/admin/savedsearch/_reload` |
| Dashboard XML/JSON | `POST /servicesNS/admin/<APP>/data/ui/views/_reload` |

Restart is only required when adding a new app (creates new app structure).
