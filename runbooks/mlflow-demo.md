# MLflow on RHOAI — Demo Runbook

**Time**: ~15 minutes | **Audience**: Platform engineers, ML engineers, decision-makers
**Story**: "Every LLM call in your AI application is automatically traced. You get full observability into what your models are doing — no code changes required."

## Prerequisites

```bash
pip install mlflow openai
```

Set these for your cluster:

```bash
export MAAS_URL="https://maas.apps.ocp.xlwsd.sandbox1213.opentlc.com/rhoai-playground/qwen3-8b/v1"
export MAAS_API_KEY="<YOUR_MAAS_API_KEY>"
export MLFLOW_TRACKING_URI="https://mlflow.redhat-ods-applications.svc:8443/mlflow"
```

> **Note**: If running from outside the cluster, use the dashboard URL instead:
> `export MLFLOW_TRACKING_URI="https://rh-ai.apps.ocp.xlwsd.sandbox1213.opentlc.com/mlflow/"`
> and authenticate via `export MLFLOW_TRACKING_TOKEN=$(oc whoami -t)`.

---

## Part 1: LLM Tracing (5 min) — The Hook

This is the demo opener. One decorator, full observability.

Save as `demo_tracing.py`:

```python
import mlflow
import openai
import os
import time

mlflow.openai.autolog()

mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
mlflow.set_workspace("rhoai-playground")
mlflow.set_experiment("llm-tracing-demo")

client = openai.OpenAI(
    base_url=os.environ["MAAS_URL"],
    api_key=os.environ["MAAS_API_KEY"],
)

prompts = [
    "Explain Kubernetes to a 5-year-old in two sentences.",
    "What are the three biggest risks of running ML models in production?",
    "Write a haiku about container orchestration.",
]

for prompt in prompts:
    print(f"\n--- Prompt: {prompt}")
    response = client.chat.completions.create(
        model="qwen3-8b",
        messages=[{"role": "user", "content": prompt}],
        max_tokens=256,
    )
    print(response.choices[0].message.content[:200])

mlflow.flush_trace_async_logging(terminate=True)
time.sleep(3)
print("\nDone. Check MLflow UI -> Traces tab.")
```

```bash
python demo_tracing.py
```

**What to show in the UI**:
1. Open MLflow: `https://rh-ai.apps.ocp.xlwsd.sandbox1213.opentlc.com/mlflow/`
2. Select workspace **rhoai-playground** (top-left dropdown)
3. Click **Traces** tab
4. Each LLM call appears as a trace — click one to expand
5. Point out: full request/response body, latency, token counts, model name — all captured automatically

**Talking point**: "This is `mlflow.openai.autolog()` — one line of code. It works with any OpenAI-compatible endpoint, which is exactly what vLLM on RHOAI exposes. No SDK lock-in."

---

## Part 2: Experiment Tracking with Prompt Comparison (5 min)

Show how teams compare different prompt strategies systematically.

Save as `demo_experiment.py`:

```python
import mlflow
import openai
import os
import time

mlflow.openai.autolog()

mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
mlflow.set_workspace("rhoai-playground")
mlflow.set_experiment("prompt-engineering")

client = openai.OpenAI(
    base_url=os.environ["MAAS_URL"],
    api_key=os.environ["MAAS_API_KEY"],
)

TASK = "Summarize the benefits of Red Hat OpenShift for enterprise AI workloads."

strategies = [
    {
        "name": "direct",
        "system": "You are a helpful assistant.",
        "temperature": 0.3,
        "max_tokens": 200,
    },
    {
        "name": "concise-expert",
        "system": "You are a senior cloud architect. Be concise. Use bullet points.",
        "temperature": 0.1,
        "max_tokens": 200,
    },
    {
        "name": "creative",
        "system": "You are a tech evangelist writing for a blog audience. Be engaging.",
        "temperature": 0.9,
        "max_tokens": 300,
    },
]

for strategy in strategies:
    with mlflow.start_run(run_name=strategy["name"]):
        mlflow.log_params({
            "strategy": strategy["name"],
            "system_prompt": strategy["system"][:80],
            "temperature": strategy["temperature"],
            "max_tokens": strategy["max_tokens"],
            "model": "qwen3-8b",
        })

        response = client.chat.completions.create(
            model="qwen3-8b",
            messages=[
                {"role": "system", "content": strategy["system"]},
                {"role": "user", "content": TASK},
            ],
            temperature=strategy["temperature"],
            max_tokens=strategy["max_tokens"],
        )

        output = response.choices[0].message.content
        usage = response.usage

        mlflow.log_metrics({
            "prompt_tokens": usage.prompt_tokens,
            "completion_tokens": usage.completion_tokens,
            "total_tokens": usage.total_tokens,
            "response_length": len(output),
        })
        mlflow.log_text(output, "response.txt")

        print(f"\n[{strategy['name']}] tokens={usage.total_tokens} len={len(output)}")
        print(output[:150] + "...")

mlflow.flush_trace_async_logging(terminate=True)
time.sleep(3)
print("\nDone. Compare runs in MLflow UI.")
```

```bash
python demo_experiment.py
```

**What to show in the UI**:
1. Click **Experiments** -> **prompt-engineering**
2. You see three runs: `direct`, `concise-expert`, `creative`
3. Select all three -> click **Compare**
4. Show the **Parameters** comparison (system prompt, temperature)
5. Show the **Metrics** comparison (token usage, response length)
6. Click into a run -> **Artifacts** -> `response.txt` to see the actual output

**Talking point**: "This is how ML teams do prompt engineering at scale. Instead of tweaking prompts in a notebook and losing track, every variation is versioned, measured, and comparable. The traces show you exactly what went to the model and what came back."

---

## Part 3: Agentic Workflow Tracing (5 min) — Advanced

Show that MLflow captures multi-step tool-calling workflows, not just single completions.

Save as `demo_agent.py`:

```python
import mlflow
import openai
import json
import os
import time

mlflow.openai.autolog()

mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
mlflow.set_workspace("rhoai-playground")
mlflow.set_experiment("agent-tracing")

client = openai.OpenAI(
    base_url=os.environ["MAAS_URL"],
    api_key=os.environ["MAAS_API_KEY"],
)

tools = [
    {
        "type": "function",
        "function": {
            "name": "get_cluster_status",
            "description": "Get the current status of an OpenShift cluster",
            "parameters": {
                "type": "object",
                "properties": {
                    "cluster_name": {"type": "string", "description": "Name of the cluster"},
                },
                "required": ["cluster_name"],
            },
        },
    },
]

def fake_get_cluster_status(cluster_name):
    return json.dumps({
        "cluster": cluster_name,
        "status": "healthy",
        "nodes": 6,
        "gpu_nodes": 2,
        "running_models": ["qwen3-8b"],
        "cpu_utilization": "42%",
    })

with mlflow.start_run(run_name="ops-agent"):
    messages = [
        {"role": "system", "content": "You are an OpenShift operations assistant."},
        {"role": "user", "content": "Check the status of cluster 'production-east' and tell me if we have capacity for another model."},
    ]

    # Step 1: model decides to call a tool
    response = client.chat.completions.create(
        model="qwen3-8b", messages=messages, tools=tools, max_tokens=512,
    )
    msg = response.choices[0].message

    if msg.tool_calls:
        messages.append(msg)
        for tc in msg.tool_calls:
            result = fake_get_cluster_status(json.loads(tc.function.arguments).get("cluster_name", "unknown"))
            messages.append({"role": "tool", "tool_call_id": tc.id, "content": result})
            print(f"Tool call: {tc.function.name}({tc.function.arguments}) -> {result}")

        # Step 2: model synthesizes the tool result
        response = client.chat.completions.create(
            model="qwen3-8b", messages=messages, max_tokens=512,
        )
        print(f"\nAgent response:\n{response.choices[0].message.content}")
    else:
        print(f"Response (no tool call):\n{msg.content}")

mlflow.flush_trace_async_logging(terminate=True)
time.sleep(3)
print("\nDone. Check Traces tab for multi-step agent trace.")
```

```bash
python demo_agent.py
```

**What to show in the UI**:
1. Go to **Traces** tab in the `agent-tracing` experiment
2. The trace shows the multi-step flow: initial call -> tool invocation -> follow-up call
3. Each step has its own span with inputs/outputs

**Talking point**: "As you build agentic AI applications — chains of LLM calls with tool use — MLflow captures the entire execution graph. You can debug exactly where an agent went wrong, which tool returned unexpected data, and how the model interpreted it."

---

## Key Messages for Customers

| Concern | Answer |
|---------|--------|
| "We already use Weights & Biases" | MLflow is open-source, runs on-prem, no data leaves your cluster |
| "How much code do we change?" | One line: `mlflow.openai.autolog()`. Zero for LangChain (`mlflow.langchain.autolog()`) |
| "Does it work with our models?" | Any OpenAI-compatible endpoint — vLLM, TGI, or external providers |
| "What about production?" | Same MLflow instance tracks dev experiments and prod traces. RBAC via OpenShift |
| "Cost?" | Included with RHOAI. No per-seat licensing |

## Cleanup

The experiments and traces persist in MLflow. No cleanup needed — they serve as reference data.
