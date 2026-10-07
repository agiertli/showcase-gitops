# Garak Scan Proxy — Why It Exists and What's Upstream

## Context

The `07-model-router-proxy.yaml` deploys a Python proxy (`maas-auth-proxy`) in `csob-sandbox` that sits between Garak and the model endpoints. Garak connects to the proxy as if it were a single OpenAI-compatible endpoint; the proxy routes requests to the correct backend based on the `model` field in the request body.

**Backends:**
- `gemma-4-12b` → direct vLLM pool (`gemma-pool.csob-sandbox.svc.cluster.local:8000`, 3 instances) or original KServe endpoint (weighted random)
- `gemma-4-12b-guard` → NemoGuardrails endpoint (rewrites model name to `gemma-4-12b` before forwarding)
- `qwen36-35b-a3b`, `gpt-oss-120b` → RHDP MaaS (`maas-rhdp.apps.maas.redhatworkshops.io`)

## Proxy Functions vs. Upstream Status

### 1. Multi-Backend API Key Injection — PARTIALLY addressable

**What the proxy does:** Injects different `Authorization: Bearer` headers depending on the target backend (RHDP key, vLLM key, guard key). This lets a single Garak run scan multiple endpoints with different auth.

**Upstream:** Garak's `OpenAICompatible` generator supports `api_key` in YAML config since [PR #1021](https://github.com/NVIDIA/garak/pull/1021). [Issue #1008](https://github.com/NVIDIA/garak/issues/1008) was the original request. But Garak only supports ONE generator with ONE `api_key` per run.

**Can we drop the proxy?** Only if we run separate Garak invocations per endpoint. Multi-backend routing in a single scan is a custom requirement with no upstream equivalent.

### 2. Timeout / Hang Prevention — OPEN upstream bug, NO fix

**What the proxy does:** Hard `timeout=120` on `urllib.request.urlopen`. Returns a clean 502 on timeout instead of hanging.

**Upstream:** [Issue #2141](https://github.com/NVIDIA/garak/issues/2141) — **OPEN**, no fix, no PR, no workaround. `@backoff.on_exception()` in `OpenAICompatible._call_model()` has no `max_tries` or `max_time`. A single unreachable endpoint hangs the entire scan permanently. The reporter offered a PR but no maintainer response.

**Related:** [Issue #1967](https://github.com/NVIDIA/garak/issues/1967) — NIM generator aborts entire probe on a single transient HTTP 408 (fixed via [PR #2019](https://github.com/NVIDIA/garak/pull/2019), but only for the NIM generator, not `OpenAICompatible`).

**Can we drop the proxy?** **No.** This is the hard blocker. Until #2141 is fixed, any transient connectivity issue can stall a multi-hour scan indefinitely.

### 3. TLS Skip-Verify — No upstream support

**What the proxy does:** `ssl.CERT_NONE` — skips TLS verification for internal KServe endpoints using OpenShift service-serving CA certificates.

**Upstream:** Zero issues filed about TLS/SSL verification in Garak. The `OpenAICompatible` generator passes no TLS config to the OpenAI SDK. No `verify_ssl`, `insecure`, or `REQUESTS_CA_BUNDLE` handling exists.

**Workaround without proxy:** Setting `SSL_CERT_FILE` or `REQUESTS_CA_BUNDLE` env vars before running Garak (the underlying `httpx` library respects these). Fragile and untested with Garak specifically.

**Can we drop the proxy?** **No** — unless all endpoints are exposed via external Routes with trusted certs. The KServe internal services use service-serving CA which Garak can't trust.

### 4. Model Name Rewriting — Custom requirement

**What the proxy does:** Rewrites `gemma-4-12b-guard` → `gemma-4-12b` before forwarding to NemoGuardrails. This lets both guarded and unguarded scans use the same Garak config with different model names.

**Upstream:** No equivalent feature. Each generator connects to one endpoint with one model name.

**Can we drop it?** Only with separate Garak runs per endpoint.

### 5. Throttling / Concurrency Control — NOT used

**What the proxy does:** Nothing. The code explicitly comments: "No throttling needed — 4 total gemma instances handle garak's max_concurrency=10."

**How we solved it:** Scaled the backend to 3 pool instances + 1 original KServe instance. Garak's `--parallel_attempts` CLI flag provides coarse control.

**Upstream:** No fine-grained per-request rate limiting in Garak, but the scaling approach makes it unnecessary.

## Summary

| Function | Upstream Issue | Fix Available? | Proxy Needed? |
|---|---|---|---|
| Multi-backend API key routing | [#1008](https://github.com/NVIDIA/garak/issues/1008) (single key works) | Partial | **Yes** (or separate runs) |
| Timeout / hang prevention | [#2141](https://github.com/NVIDIA/garak/issues/2141) (OPEN) | **No** | **Yes** |
| TLS skip-verify | None filed | No | **Yes** (env var workaround possible) |
| Model name rewriting | N/A | N/A | **Yes** (or separate runs) |
| Throttling | N/A | CLI flags exist | **No** (scaling solved it) |

## Recommendation

**The proxy is still justified** for any multi-endpoint scan. The hard blocker is [#2141](https://github.com/NVIDIA/garak/issues/2141) — without a fix, even single-endpoint scans risk indefinite hangs.

If restructured into per-endpoint Garak runs with external Routes (trusted TLS), the proxy could be eliminated for:
- Single-endpoint scans with valid certs
- Environments where `SSL_CERT_FILE` workaround is acceptable

## Items for Red Hat Engineering

1. **TLS skip-verify in Garak** — every KServe endpoint uses service-serving CA by default. Filing an upstream Garak issue for `verify_ssl` support would benefit all OpenShift/KServe users running red-team scans.

2. **Unbounded backoff ([#2141](https://github.com/NVIDIA/garak/issues/2141))** — critical for production scans. A single transient failure (pod restart, network blip) can stall the entire benchmark indefinitely. The reporter offered to submit a PR but received no maintainer response. This needs traction.

3. **EvalHub integration** — RHOAI 3.5 EvalHub uses Garak internally. If EvalHub wraps Garak with its own timeout/retry logic, #2141 may already be mitigated in that path. Worth verifying before filing a separate RFE.
