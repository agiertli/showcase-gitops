ARGOCD_NAMESPACE=openshift-gitops
ARGOCD_TOOLING_NAMESPACE=tooling
ARGOCD_CR_NAME=openshift-gitops
ARGOCD_PROJECT_NAME="showcase-gitops"
ARGOCD_APP_NAME="${ARGOCD_PROJECT_NAME}-app-of-apps"

while getopts "p:" opt; do
  case $opt in
    p) ARGOCD_ADMIN_PASSWORD="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    exit 1
    ;;
  esac

  case $OPTARG in
    -*) echo "Option $opt needs a valid argument"
    exit 1
    ;;
  esac
done

echo "Creating Subscription: argocd"
oc apply -f argocd-subs.yaml

while [[ argoSecret=$(oc -n ${ARGOCD_NAMESPACE} get secret ${ARGOCD_CR_NAME}-cluster 2>&1 > /dev/null) == *"Error"* ]]
do
echo "Waiting until ArgoCD CR is ready..."
sleep 5
done
oc -n $ARGOCD_NAMESPACE patch secret $ARGOCD_CR_NAME-cluster --patch "{\"stringData\": {\"admin.password\": \"$ARGOCD_ADMIN_PASSWORD\"}}"
oc -n $ARGOCD_NAMESPACE patch secret argocd-secret --patch "{\"data\": {\"admin.password\": null}}"
oc new-project ${ARGOCD_TOOLING_NAMESPACE}

echo "Creating ArgoCD Project ${ARGOCD_PROJECT_NAME}"

oc apply -f tooling-project.yaml -n  ${ARGOCD_NAMESPACE}

echo "Creating ArgoCD App of Apps ${ARGOCD_APP_NAME}"

oc apply -f app-of-apps.yaml -n ${ARGOCD_NAMESPACE}

oc patch configmaps argocd-rbac-cm  -p '{"data":{"policy.default":" "}}' -n openshift-gitops

echo "Installation complete!" 
