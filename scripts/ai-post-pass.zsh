#!/bin/zsh
set -euo pipefail

# TeX/Homebrew PATH — this script runs outside the /usr/bin/script session and may be
# invoked in a non-interactive context. Export unconditionally so git, python3,
# and other tools resolve correctly regardless of how the script is called.
export PATH="/Library/TeX/texbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PASS_ID="${1:?Usage: ai-post-pass.zsh <PASS_ID>}"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPORT_ROOT="$PROJECT_ROOT/build-report-logs"

REPORT="$REPORT_ROOT/reports/${PASS_ID}-report.md"
METADATA="$REPORT_ROOT/metadata-reports/${PASS_ID}-metadata.json"
CLEAN_LOG="$REPORT_ROOT/logs/clean-logs/${PASS_ID}.clean.log"
META_FILE="$REPORT_ROOT/logs/meta-logs/${PASS_ID}.meta.txt"
RAW_LOG="$REPORT_ROOT/logs/raw-logs/${PASS_ID}.log"
LAUNCHER="$REPORT_ROOT/launchers/${PASS_ID}-launcher.zsh"

PYTHON3=""
for _p in /opt/homebrew/bin/python3 /usr/bin/python3 /usr/local/bin/python3 python3; do
  "$_p" --version >/dev/null 2>&1 && PYTHON3="$_p" && break || true
done
if [[ -z "$PYTHON3" ]]; then
  print -u2 "ERROR: python3 not found at any known path — duration/token patching will be skipped"
fi

print "=== Post-pass validation: $PASS_ID ==="
print ""

[[ -f "$REPORT" ]]    && print "✓ Report exists"    || print "✗ Report MISSING: $REPORT"
[[ -f "$METADATA" ]]  && print "✓ Metadata exists"  || print "✗ Metadata MISSING: $METADATA"
[[ -f "$CLEAN_LOG" ]] && print "✓ Clean log exists" || print "✗ Clean log MISSING: $CLEAN_LOG"
[[ -f "$META_FILE" ]] && print "✓ Meta file exists" || print "✗ Meta file MISSING: $META_FILE"
[[ -s "$RAW_LOG" ]]   && print "✓ Raw log exists"   || print "✗ Raw log MISSING or empty: $RAW_LOG"
[[ -f "$LAUNCHER" ]]  && print "✓ Launcher exists"  || print "✗ Launcher MISSING: $LAUNCHER"
print ""

if [[ -f "$METADATA" && -n "$PYTHON3" ]]; then
  "$PYTHON3" -m json.tool "$METADATA" > /dev/null 2>&1 \
    && print "✓ Metadata JSON valid" \
    || print "✗ Metadata JSON INVALID — fix before continuing"
fi
print ""

if [[ -f "$REPORT" ]]; then
  print "Report sections:"
  for section in \
    "## Workflow State" \
    "## Model Used" \
    "## Files Read" \
    "## Files Modified" \
    "## Verification Performed" \
    "## Issues Encountered" \
    "## Recommended Next Prompt"; do
    grep -q "^${section}" "$REPORT" \
      && print "  ✓ $section" \
      || print "  ✗ MISSING: $section"
  done
  grep -q "Workflow Guide Version" "$REPORT" \
    && print "  ✓ Workflow Guide Version present" \
    || print "  ✗ Workflow Guide Version MISSING from report header"
fi
print ""

if [[ -f "$METADATA" && -n "$PYTHON3" ]]; then
  print "Metadata honesty:"
  "$PYTHON3" - <<PYEOF
import json
with open('$METADATA', 'r') as f:
    data = json.load(f)

valid_statuses = {"BUILD_SUCCEEDED","BUILD_FAILED","DOCUMENTATION_ONLY","WORKFLOW_ONLY","PARTIAL","BLOCKED"}
status = data.get('status','')
if status in valid_statuses:
    print(f'  ✓ status enum valid: {status}')
else:
    print(f'  ✗ status enum INVALID: "{status}" — must be one of {sorted(valid_statuses)}')

wgv = data.get('workflow_guide_version','')
if wgv:
    print(f'  ✓ workflow_guide_version present: {wgv}')
else:
    print('  ✗ workflow_guide_version MISSING')

score = data.get('agent_md_maintenance_score')
if score is None:
    print('  ✗ agent_md_maintenance_score MISSING — required field in v6.2')
elif isinstance(score, int) and 1 <= score <= 5:
    print(f'  ✓ agent_md_maintenance_score valid: {score}')
    if score == 5:
        print('  ⚠ maintenance score is 5 — maintenance pass required before next implementation pass')
    elif score == 4:
        print('  ⚠ maintenance score is 4 — maintenance pass strongly recommended')
else:
    print(f'  ✗ agent_md_maintenance_score INVALID: "{score}" — must be integer 1–5')

for f in ('agent_md_authorized','prompt_saved','launcher_saved'):
    v = data.get(f)
    if v is not None:
        print(f'  ✓ {f} present: {v}')
    else:
        print(f'  ✗ {f} MISSING')

auth = data.get('agent_md_authority','')
valid_auth = {"created_by_p01_bootstrap","accepted_by_p01_adoption_bootstrap",
              "accepted_by_remediation_pass","not_present","unknown"}
if auth in valid_auth:
    print(f'  ✓ agent_md_authority valid: {auth}')
else:
    print(f'  ✗ agent_md_authority INVALID or MISSING: "{auth}"')

br = data.get('build_result')
no_build = {'DOCUMENTATION_ONLY','WORKFLOW_ONLY'}
if status in no_build and br is not None:
    print(f'  ✗ build_result should be null for status {status}')
elif status in {'BUILD_SUCCEEDED','BUILD_FAILED'} and br is None:
    print(f'  ✗ build_result should not be null for status {status}')
else:
    print(f'  ✓ build_result consistent with status')
PYEOF
fi
print ""

print "=== Duration ==="
if [[ -f "$META_FILE" ]]; then
  LAUNCH=$(grep '^LAUNCH_TIME=' "$META_FILE" | cut -d= -f2 || true)
  COMPLETE=$(grep '^COMPLETE_TIME=' "$META_FILE" | cut -d= -f2 || true)
  if [[ -n "$LAUNCH" && -n "$COMPLETE" ]]; then
    LAUNCH_SEC=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAUNCH" +%s 2>/dev/null || echo "")
    COMPLETE_SEC=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$COMPLETE" +%s 2>/dev/null || echo "")
    if [[ -n "$LAUNCH_SEC" && -n "$COMPLETE_SEC" ]]; then
      DURATION=$(( COMPLETE_SEC - LAUNCH_SEC ))
      print "Calculated: ${DURATION}s"
      if [[ -f "$METADATA" && -n "$PYTHON3" ]]; then
        "$PYTHON3" - <<PYEOF
import json
with open('$METADATA', 'r') as f:
    data = json.load(f)
if data.get('duration_seconds') is None:
    data['duration_seconds'] = $DURATION
    with open('$METADATA', 'w') as f:
        json.dump(data, f, indent=2)
    print('✓ Patched duration_seconds: ${DURATION}s')
else:
    print('  duration_seconds already set: ' + str(data['duration_seconds']))
PYEOF
      fi
    else
      print "  Could not parse timestamps from meta file"
    fi
  else
    print "  LAUNCH_TIME or COMPLETE_TIME not found — was a current launcher used?"
  fi
else
  print "  Meta file not found"
fi
print ""

print "=== Token Count ==="
if [[ -f "$CLEAN_LOG" ]]; then
  TOKENS_LAST="$(grep -oE '([0-9]+(\.[0-9]+)?k? tokens|Token usage: total=[0-9,]+)' "$CLEAN_LOG" 2>/dev/null | tail -1 || true)"
  if [[ -z "$TOKENS_LAST" && -f "$RAW_LOG" ]]; then
    TOKENS_LAST="$(strings "$RAW_LOG" \
      | grep -oE '([0-9]+(\.[0-9]+)?k? tokens|Token usage: total=[0-9,]+)' \
      2>/dev/null | tail -1 || true)"
    [[ -n "$TOKENS_LAST" ]] && print "  (found via strings fallback on raw log)"
  fi
  if [[ -n "$TOKENS_LAST" ]]; then
    print "Found: $TOKENS_LAST"
    if [[ -f "$METADATA" && -n "$PYTHON3" ]]; then
      "$PYTHON3" - <<PYEOF
import json, re
with open('$METADATA', 'r') as f:
    data = json.load(f)
if data.get('total_tokens_used') is None:
    tokens_str = '$TOKENS_LAST'
    m = re.match(r'([0-9]+\.?[0-9]*)k tokens', tokens_str)
    if m:
        tokens = int(float(m.group(1)) * 1000)
    else:
        m = re.match(r'Token usage: total=([0-9,]+)', tokens_str)
        if m:
            tokens = int(m.group(1).replace(',', ''))
        else:
            m = re.match(r'([0-9]+) tokens', tokens_str)
            tokens = int(m.group(1)) if m else None
    if tokens is not None:
        data['total_tokens_used'] = tokens
        with open('$METADATA', 'w') as f:
            json.dump(data, f, indent=2)
        print(f'✓ Patched total_tokens_used: {tokens}')
    else:
        print('  Could not parse number from: $TOKENS_LAST')
else:
    print('  total_tokens_used already set: ' + str(data['total_tokens_used']))
PYEOF
    fi
  else
    print "  No token pattern found in clean log or raw log."
    print "  total_tokens_used remains null. This is expected if the tool"
    print "  does not print token counts to terminal output."
    print "  For Codex: ensure --no-alt-screen is set in the launcher."
  fi
else
  print "  Clean log not found"
fi
print ""

print "=== Git diff since pass start ==="
if [[ -f "$META_FILE" ]]; then
  BASE_SHA="$(grep '^GIT_HEAD=' "$META_FILE" | cut -d= -f2 || true)"
  if [[ -n "$BASE_SHA" && "$BASE_SHA" != "unknown" && "$BASE_SHA" != "(unborn)" ]]; then
    git -C "$PROJECT_ROOT" diff --stat "$BASE_SHA" 2>/dev/null || print "(diff failed)"
  else
    print "(base SHA unknown or unborn — bootstrap on new repo)"
  fi
fi
print ""

print "=== Current git status ==="
git -C "$PROJECT_ROOT" status --short || true
print ""
print "=== Validation complete ==="
