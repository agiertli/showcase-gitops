#!/bin/bash
# Scrape garak scan data every 60 seconds
# Keeps only the latest version of each file
# Stops when the pod enters Completed/Succeeded state

JOB_ID="beeeac41-f1fa-4140-a6e1-8bd9bfcb5469"
NS="csob-sandbox"
OUT_DIR="/Users/agiertli/Documents/work/showcase-gitops/csob-sandbox/red-teaming"
POD_PREFIX="beeeac41-f1fa-4140-a6e1-8b"
SCAN_DIR="/tmp/.cache/trustyai_garak_scans/${JOB_ID}"

while true; do
    POD=$(oc get pods -n "$NS" --no-headers 2>/dev/null | grep "$POD_PREFIX" | awk '{print $1}')

    if [ -z "$POD" ]; then
        echo "[$(date +%H:%M:%S)] Pod not found - scan may have finished"
        break
    fi

    POD_PHASE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)

    if [ "$POD_PHASE" = "Succeeded" ] || [ "$POD_PHASE" = "Failed" ]; then
        echo "[$(date +%H:%M:%S)] Pod phase: $POD_PHASE - doing final scrape attempt"
        oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.report.jsonl" > "${OUT_DIR}/granite-guard-scan-avid.jsonl" 2>/dev/null
        oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.hitlog.jsonl" > "${OUT_DIR}/granite-guard-scan-hitlog.jsonl" 2>/dev/null
        break
    fi

    # Scrape
    oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.report.jsonl" > "${OUT_DIR}/granite-guard-scan-avid.jsonl" 2>/dev/null
    LINES=$(wc -l < "${OUT_DIR}/granite-guard-scan-avid.jsonl" 2>/dev/null | tr -d ' ')

    oc exec "$POD" -n "$NS" -c adapter -- cat "${SCAN_DIR}/scan.hitlog.jsonl" > "${OUT_DIR}/granite-guard-scan-hitlog.jsonl" 2>/dev/null
    HITS=$(wc -l < "${OUT_DIR}/granite-guard-scan-hitlog.jsonl" 2>/dev/null | tr -d ' ')

    echo "[$(date +%H:%M:%S)] Scraped: ${LINES} report entries, ${HITS} hits | Pod: ${POD_PHASE}"

    sleep 60
done

echo "[$(date +%H:%M:%S)] Scraping loop ended"

# Fetch final results from EvalHub API
oc exec evalhub-7b87dbdd87-s4rmv -n "$NS" -c evalhub -- curl -s \
  "http://127.0.0.1:8444/api/v1/evaluations/jobs/${JOB_ID}" \
  -H "X-Tenant: csob-sandbox" -H "X-User: admin" > "${OUT_DIR}/granite-guard-scan-result.json" 2>/dev/null

echo "[$(date +%H:%M:%S)] EvalHub results saved"
