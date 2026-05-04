# 06 — Tuning Guide

How to silence false positives without going blind.

## Knobs available in `savedsearches.conf`

| Knob | What it does | Where |
|---|---|---|
| `disabled = 0/1` | Activate / deactivate the alert | every stanza |
| `cron_schedule` | How often the alert runs | every stanza |
| `dispatch.earliest_time` | Lookback window | every stanza |
| `quantity` | Threshold (number of result rows) | every stanza |
| `alert.suppress = 1` | Throttling on/off | every stanza |
| `alert.suppress.period` | How long to mute after firing | every stanza |
| `alert.suppress.fields` | Group key for suppression (e.g. `host,db`) | every stanza |
| `where count >= N` (in SPL) | Threshold inside the search | brute-force, login burst |

## Common tuning patterns

### "This non-prod host is noisy and I don't care"

Best option — **demote it in inventory**. Edit the host's `tier` to `3` in `sql_inventory.csv` and gate the noisy alert with a tier filter. Example for the Job Step Failure alert:

```spl
... | lookup sql_inventory_lookup host OUTPUT env tier
    | where isnotnull(env) AND (env="prod" OR tier="1")
    | rex field=Message ...
```

This way it stays in the dashboards (you'll see it) but won't page.

### "App X causes legitimate failed logins during deploys — stop alerting on it"

Add an exception in the search:
```spl
... | where login_user!="app_deploy_svc"
```
Or maintain a `sql_login_exceptions.csv` lookup with `login_user, reason, expires` and:
```spl
... | lookup sql_login_exceptions login_user OUTPUT reason
    | where isnull(reason)
```
The lookup gives you an audit trail and an expiration date.

### "The runaway-job alert is too sensitive"

The custom telemetry script writes 2001 when `ModifiedZScore > MadAnomalyThreshold` (default 3.5). The alert filters again at `>= 5`. To loosen:

- Raise the alert threshold to `>= 7` in `savedsearches.conf`
- Or raise the script's `MadAnomalyThreshold` parameter at deployment time (so 2001 events themselves are rarer)

To tighten only on prod tier-1: add `| where env="prod" AND tier="1"`.

### "Silent server alert fires for our test box during off-hours"

Two options:
1. Exclude tier-3 hosts from the alert: `| where NOT (env="dev" AND tier="3")`.
2. Add a per-host `expected_silent_window` column to inventory and skip during that window.

### "I want backup failures to page in prod, ticket elsewhere"

Clone the stanza:
```
[SQL - P1 - Backup Failure (prod)]
search = ... | where env="prod"
action.webhook = 1
action.webhook.param.url = <pagerduty>

[SQL - P2 - Backup Failure (non-prod)]
search = ... | where env!="prod"
action.email = 1
```

## Threshold cheat sheet

| Alert | Default | Considerations |
|---|---|---|
| Service Crash | any (>0) | Don't loosen — by definition this is bad. |
| Corruption | any (>0) | Don't loosen. 825 alone (failing disk warning) might warrant a separate, lower-tier alert if drives flap during patching. |
| Log/Data File Full | any (>0) | Don't loosen. |
| AG Suspended | any (>0) prod-only | If you need pre-prod AG monitoring, drop the `env="prod"` filter and lower tier. |
| Backup Failure | any (>0) | Consider gating non-critical DBs (system DBs without app data, throwaway dev DBs) via a `backup_exceptions` lookup. |
| Runaway Job (Z≥5) | Z≥5 | If too noisy: raise to 7. If too quiet: drop to 4. Run last 7 days first to see the distribution: `... | stats count by floor(ModifiedZScore)`. |
| Job Step Failure | any (>0) | Often the loudest alert. Strong candidate for a per-job exception lookup. |
| Failed Login Burst | ≥25 in 5m | Lower for high-security envs; raise if you have integration tests that intentionally probe. |
| Silent Server | 0 events in 30m | Increase the lookback (e.g. 2h) for dev/test hosts. |

## Observability hygiene

Every couple weeks, spend 15 min on:

```spl
index=_audit action=alert_fired
| stats count by ss_name
| sort - count
```

If one alert dominates, it's likely calibration drift — investigate, tune, retest. Keeping signal-to-noise high is the difference between an alert system people trust and one they reflexively dismiss.
