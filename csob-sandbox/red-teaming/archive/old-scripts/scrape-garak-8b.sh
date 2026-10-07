#!/bin/bash
# Scrape garak scan data every 60 seconds with rolling backup
# Keeps latest + previous version to avoid data loss
# Calculates ASR in real-time

NS="csob-sandbox"
OUT_DIR="/Users/agiertli/Documents/work/showcase-gitops/csob-sandbox/red-teaming"
REPORT_FILE="${OUT_DIR}/granite-guard-8b-scan-avid.jsonl"
HITLOG_FILE="${OUT_DIR}/granite-guard-8b-scan-hitlog.jsonl"
RESULT_FILE="${OUT_DIR}/granite-guard-8b-scan-result.json"

# Will be set after scan starts
JOB_ID=""
POD_PREFIX=""
SCAN_DIR=""

echo "Waiting for JOB_ID to be set..."
echo "Usage: export JOB_ID=<id> then re-run, or pass as arg: $0 <job-id>"

if [ -n "$1" ]; then
    JOB_ID="$1"
fi

if [ -z "$JOB_ID" ]; then
    echo "ERROR: JOB_ID required. Pass as argument or set env var."
    exit 1
fi

POD_PREFIX="${JOB_ID:0:24}"
SCAN_DIR="/tmp/.cache/trustyai_garak_scans/${JOB_ID}"

echo "Scraping job: ${JOB_ID}"
echo "Pod prefix: ${POD_PREFIX}"
echo "Output: ${OUT_DIR}/granite-guard-8b-scan-*"
echo ""

ITERATION=0
while true; do
    ITERATION=$((ITERATION + 1))
    POD=$(oc get pods -n "$NS" --no-headers 2>/dev/null | grep "$POD_PREFIX" | awk '{print $1}')

    if [ -z "$POD" ]; then
        echo "[$(date +%H:%M:%S)] Pod not found - scan may have finished"
        break
    fi

    POD_PHASE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)

    if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
        echo "[$(date +%H:%M:%S)] Pod phase: $POD_PHASE - doing final scrape"
    fi

    # Backup previous scrape before overwriting
    [ -f "$REPORT_FILE" ] && cp "$REPORT_FILE" "${REPORT_FILE}.bak"
    [ -f "$HITLOG_FILE" ] && cp "$HITLOG_FILE" "${HITLOG_FILE}.bak"

    # Scrape current data
    oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.report.jsonl" >| "$REPORT_FILE" 2>/dev/null
    oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.hitlog.jsonl" >| "$HITLOG_FILE" 2>/dev/null

    LINES=$(wc -l < "$REPORT_FILE" 2>/dev/null | tr -d ' ')
    HITS=$(wc -l < "$HITLOG_FILE" 2>/dev/null | tr -d ' ')

    # If scrape returned empty but we have backup, restore
    if [ "$LINES" = "0" ] && [ -f "${REPORT_FILE}.bak" ]; then
        BLINES=$(wc -l < "${REPORT_FILE}.bak" | tr -d ' ')
        if [ "$BLINES" -gt 0 ]; then
            cp "${REPORT_FILE}.bak" "$REPORT_FILE"
            LINES="$BLINES (restored from backup)"
        fi
    fi
    if [ "$HITS" = "0" ] && [ -f "${HITLOG_FILE}.bak" ]; then
        BHITS=$(wc -l < "${HITLOG_FILE}.bak" | tr -d ' ')
        if [ "$BHITS" -gt 0 ]; then
            cp "${HITLOG_FILE}.bak" "$HITLOG_FILE"
            HITS="$BHITS (restored from backup)"
        fi
    fi

    # Calculate ASR
    if [ "$LINES" -gt 0 ] 2>/dev/null; then
        TOTAL_PROBES=$(echo "$LINES" | grep -o '[0-9]*')
        TOTAL_HITS=$(echo "$HITS" | grep -o '[0-9]*')
        if [ "$TOTAL_PROBES" -gt 0 ] 2>/dev/null; then
            ASR=$(python3 -c "print(f'{${TOTAL_HITS}/${TOTAL_PROBES}*100:.2f}%')" 2>/dev/null || echo "N/A")
        else
            ASR="N/A"
        fi
    else
        ASR="N/A"
    fi

    echo "[$(date +%H:%M:%S)] #${ITERATION} | Reports: ${LINES} | Hits: ${HITS} | ASR: ${ASR} | Pod: ${POD_PHASE}"

    if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
        break
    fi

    sleep 60
done

echo "[$(date +%H:%M:%S)] Scraping loop ended"

# Fetch final results from EvalHub API
EVALHUB_POD=$(oc get pods -n "$NS" --no-headers | grep evalhub | awk '{print $1}' | head -1)
if [ -n "$EVALHUB_POD" ]; then
    oc exec "$EVALHUB_POD" -n "$NS" -c evalhub -- curl -s \
      "http://127.0.0.1:8444/api/v1/evaluations/jobs/${JOB_ID}" \
      -H "X-Tenant: csob-sandbox" -H "X-User: admin" > "$RESULT_FILE" 2>/dev/null
    echo "[$(date +%H:%M:%S)] EvalHub results saved to ${RESULT_FILE}"
fi
