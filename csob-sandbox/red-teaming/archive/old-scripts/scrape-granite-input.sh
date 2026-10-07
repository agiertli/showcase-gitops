#!/bin/bash
# Scrape garak scan data for Granite Guardian INPUT classifier test
NS="csob-sandbox"
OUT_DIR="/Users/agiertli/Documents/work/showcase-gitops/csob-sandbox/red-teaming"
REPORT_FILE="${OUT_DIR}/granite-input-scan-avid.jsonl"
HITLOG_FILE="${OUT_DIR}/granite-input-scan-hitlog.jsonl"
RESULT_FILE="${OUT_DIR}/granite-input-scan-result.json"

JOB_ID="d98ebff9-fbdb-4716-b233-938bb882e411"
POD_PREFIX="${JOB_ID:0:24}"
SCAN_DIR="/tmp/.cache/trustyai_garak_scans/${JOB_ID}"

echo "Scraping job: ${JOB_ID}"
echo "Pod prefix: ${POD_PREFIX}"
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

    [ -f "$REPORT_FILE" ] && cp "$REPORT_FILE" "${REPORT_FILE}.bak"
    [ -f "$HITLOG_FILE" ] && cp "$HITLOG_FILE" "${HITLOG_FILE}.bak"

    oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.report.jsonl" >| "$REPORT_FILE" 2>/dev/null
    oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.hitlog.jsonl" >| "$HITLOG_FILE" 2>/dev/null

    LINES=$(wc -l < "$REPORT_FILE" 2>/dev/null | tr -d ' ')
    HITS=$(wc -l < "$HITLOG_FILE" 2>/dev/null | tr -d ' ')

    if [ "$LINES" = "0" ] && [ -f "${REPORT_FILE}.bak" ]; then
        BLINES=$(wc -l < "${REPORT_FILE}.bak" | tr -d ' ')
        if [ "$BLINES" -gt 0 ]; then
            cp "${REPORT_FILE}.bak" "$REPORT_FILE"
            LINES="$BLINES (restored)"
        fi
    fi
    if [ "$HITS" = "0" ] && [ -f "${HITLOG_FILE}.bak" ]; then
        BHITS=$(wc -l < "${HITLOG_FILE}.bak" | tr -d ' ')
        if [ "$BHITS" -gt 0 ]; then
            cp "${HITLOG_FILE}.bak" "$HITLOG_FILE"
            HITS="$BHITS (restored)"
        fi
    fi

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

    # Get Granite Guardian request count
    GG_REQS=$(oc logs granite-guardian-5b5cbc97c4-pq2ck -n "$NS" --since=30m 2>&1 | grep -c "POST" 2>/dev/null || echo "?")

    echo "[$(date +%H:%M:%S)] #${ITERATION} | Reports: ${LINES} | Hits: ${HITS} | ASR: ${ASR} | GG_reqs: ${GG_REQS} | Pod: ${POD_PHASE}"

    if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
        break
    fi
    sleep 60
done

echo "[$(date +%H:%M:%S)] Scraping loop ended"

EVALHUB_POD=$(oc get pods -n "$NS" --no-headers | grep evalhub | grep -v postgres | awk '{print $1}' | head -1)
if [ -n "$EVALHUB_POD" ]; then
    oc exec "$EVALHUB_POD" -n "$NS" -c evalhub -- curl -s \
      "http://127.0.0.1:8444/api/v1/evaluations/jobs/${JOB_ID}" \
      -H "X-Tenant: csob-sandbox" -H "X-User: admin" > "$RESULT_FILE" 2>/dev/null
    echo "[$(date +%H:%M:%S)] EvalHub results saved"
fi
