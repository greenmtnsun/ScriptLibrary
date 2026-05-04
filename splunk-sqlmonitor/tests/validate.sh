#!/usr/bin/env bash
# ============================================================================
# Pre-deployment validation for the SQL Server fleet Splunk artifacts.
#
# What this checks (locally, no Splunk connection required):
#   1. SimpleXML files parse as well-formed XML
#   2. Studio JSON files parse as valid JSON
#   3. CSV is RFC 4180-ish parseable, has required columns, no empty hosts/envs
#   4. transforms.conf, eventtypes.conf, savedsearches.conf have:
#        - balanced [stanza] headers
#        - key = value lines (no orphan keys)
#        - referenced lookup file exists
#   5. Every dashboard reference to an eventtype is defined
#   6. Every dashboard reference to a lookup field is in the CSV
#   7. Every alert references the lookup correctly
#
# Exit code 0 = ready to ship. Non-zero = at least one finding (printed).
# ============================================================================
set -u
PASS=0
FAIL=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
note()   { printf '  - %s\n' "$*"; }

check() {
  # check "label" "command"
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    green "PASS  $label"; PASS=$((PASS+1))
  else
    red   "FAIL  $label"; FAIL=$((FAIL+1))
    "$@" 2>&1 | sed 's/^/        /'
  fi
}

echo "=== 1. XML well-formedness (SimpleXML dashboards) ==="
for f in "$ROOT"/sql_*_dashboard.xml; do
  [ -f "$f" ] || continue
  check "XML parses: $(basename "$f")" python3 -c "import xml.etree.ElementTree as ET; ET.parse('$f')"
done

echo
echo "=== 2. JSON validity (Dashboard Studio) ==="
for f in "$ROOT"/sql_*_dashboard_studio.json; do
  [ -f "$f" ] || continue
  check "JSON parses: $(basename "$f")" python3 -c "import json; json.load(open('$f'))"
done

echo
echo "=== 3. Inventory CSV ==="
CSV="$ROOT/sql_inventory.csv"
check "CSV exists" test -f "$CSV"
if [ -f "$CSV" ]; then
  python3 - "$CSV" <<'PY'
import csv, sys
required = {"host","env","role","ag_cluster","owner","tier"}
allowed_envs = {"dev","test","stage","prod"}
allowed_roles = {"standalone","ag-primary","ag-secondary","fci-active","fci-passive"}
errors = []
with open(sys.argv[1], newline="") as f:
    r = csv.DictReader(f)
    cols = set(r.fieldnames or [])
    if not required.issubset(cols):
        errors.append(f"missing columns: {required - cols}")
    rows = list(r)
    for i, row in enumerate(rows, start=2):
        if not row["host"].strip():            errors.append(f"row {i}: empty host")
        if row["env"] not in allowed_envs:     errors.append(f"row {i} ({row['host']}): bad env '{row['env']}'")
        if row["role"] not in allowed_roles:   errors.append(f"row {i} ({row['host']}): bad role '{row['role']}'")
        if row["role"].startswith("ag-") and not row["ag_cluster"].strip():
            errors.append(f"row {i} ({row['host']}): AG role with empty ag_cluster")
        if not row["owner"].strip():           errors.append(f"row {i} ({row['host']}): empty owner")
hosts = [row["host"].strip().lower() for row in rows]
if len(hosts) != len(set(hosts)):
    errors.append("duplicate hosts in CSV")
print(f"rows={len(rows)} envs={sorted(set(r['env'] for r in rows))}")
if errors:
    for e in errors: print("ERROR:", e)
    sys.exit(1)
PY
  if [ $? -eq 0 ]; then green "PASS  CSV schema + content"; PASS=$((PASS+1)); else red "FAIL  CSV schema + content"; FAIL=$((FAIL+1)); fi
fi

echo
echo "=== 4. .conf files structure ==="
for f in "$ROOT"/transforms.conf "$ROOT"/eventtypes.conf "$ROOT"/savedsearches.conf; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
errs = []
stanza = None
with open(path) as fh:
    for n, raw in enumerate(fh, start=1):
        line = raw.rstrip("\n")
        s = line.strip()
        if not s or s.startswith("#"): continue
        if s.startswith("[") and s.endswith("]"):
            stanza = s; continue
        # accept continuation lines (start with whitespace) and key=value lines
        if raw.startswith((" ", "\t")) and stanza:
            continue
        if "=" not in s:
            errs.append(f"{path}:{n}: not a key=value line under {stanza}: {s!r}")
if errs:
    for e in errs: print("ERROR:", e)
    sys.exit(1)
print(f"{path}: OK")
PY
  if [ $? -eq 0 ]; then green "PASS  conf structure: $(basename "$f")"; PASS=$((PASS+1)); else red "FAIL  conf structure: $(basename "$f")"; FAIL=$((FAIL+1)); fi
done

echo
echo "=== 5. Cross-reference: dashboards use defined eventtypes ==="
DEFINED_ETS=$(grep -oE '^\[[a-z_]+\]' "$ROOT/eventtypes.conf" | tr -d '[]' | sort -u)
USED_ETS=$(grep -hoE 'eventtype=sql_[a-z_]+' "$ROOT"/*.xml "$ROOT"/*.json 2>/dev/null \
           | sed 's/eventtype=//' | sort -u)
MISSING=$(comm -23 <(echo "$USED_ETS") <(echo "$DEFINED_ETS"))
if [ -z "$MISSING" ]; then
  green "PASS  all referenced eventtypes are defined"
  note "defined: $(echo $DEFINED_ETS | tr '\n' ' ')"
  PASS=$((PASS+1))
else
  red   "FAIL  undefined eventtypes referenced: $MISSING"
  FAIL=$((FAIL+1))
fi

echo
echo "=== 6. Lookup file referenced in transforms.conf exists ==="
LK_FILE=$(grep -E '^filename' "$ROOT/transforms.conf" | head -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
if [ -n "$LK_FILE" ] && [ -f "$ROOT/$LK_FILE" ]; then
  green "PASS  lookup file exists: $LK_FILE"
  PASS=$((PASS+1))
else
  red "FAIL  lookup file missing: $LK_FILE"
  FAIL=$((FAIL+1))
fi

echo
echo "=== 7. Cross-reference: alerts reference lookup output fields ==="
LK_COLS=$(head -1 "$ROOT/sql_inventory.csv" | tr ',' '\n' | sort -u)
USED_LK_FIELDS=$(grep -hoE 'lookup sql_inventory_lookup host OUTPUT [^|]*' "$ROOT/savedsearches.conf" "$ROOT"/*.xml "$ROOT"/*.json 2>/dev/null \
                 | sed -E 's/.*OUTPUT//' | tr -s ' ' '\n' | grep -E '^[a-z_]+$' | sort -u)
MISSING=$(comm -23 <(echo "$USED_LK_FIELDS") <(echo "$LK_COLS"))
if [ -z "$MISSING" ]; then
  green "PASS  all OUTPUT fields exist as CSV columns"
  PASS=$((PASS+1))
else
  red   "FAIL  alerts/dashboards request CSV columns that don't exist: $MISSING"
  note  "available: $(echo $LK_COLS | tr '\n' ' ')"
  FAIL=$((FAIL+1))
fi

echo
echo "============================================================================"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  green "READY: $PASS/$TOTAL checks passed."
  exit 0
else
  red "NOT READY: $FAIL of $TOTAL checks failed."
  exit 1
fi
