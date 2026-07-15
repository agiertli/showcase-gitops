# Project Rules

## Operator Installation
- Every operator MUST be installed in its own dedicated namespace
- Never install multiple operators into a shared namespace (e.g., `openshift-operators`)
- For each operator, create: (1) a dedicated Namespace, (2) an OperatorGroup, (3) the Subscription — all in that namespace

## Documentation
- Always check the local `docs/` folder first for Red Hat product documentation PDFs
- docs.redhat.com is blocked — never attempt to WebFetch from it
- If a relevant doc is missing from `docs/`, ask the user to provide the PDF
