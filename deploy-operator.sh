#!/bin/bash

set -Eeuo pipefail

# Parse arguments

while [[ $# -gt 0 ]]; do
    case $1 in
        --operator) OPERATOR="$2"; shift 2 ;;
        --fbc-tag) FBC_TAG_INPUT="$2"; shift 2 ;;
        --internal-registry) INTERNAL_REGISTRY="$2"; shift 2 ;;
        --internal-registry-auth) INTERNAL_REGISTRY_AUTH="$2"; shift 2 ;;
        --quay-auth) QUAY_AUTH="$2"; shift 2 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "${OPERATOR:-}" && -n "${FBC_TAG_INPUT:-}" ]]; then
    echo "ERROR: Provide either --operator or --fbc-tag, not both" >&2
    exit 1
fi

if [[ -z "${OPERATOR:-}" && -z "${FBC_TAG_INPUT:-}" ]]; then
    echo "ERROR: Provide either --operator or --fbc-tag" >&2
    exit 1
fi

if [[ -z "${QUAY_AUTH:-}" ]]; then
    echo "ERROR: --quay-auth is required" >&2
    exit 1
fi

if [[ -n "${INTERNAL_REGISTRY:-}" && -z "${INTERNAL_REGISTRY_AUTH:-}" ]] || [[ -z "${INTERNAL_REGISTRY:-}" && -n "${INTERNAL_REGISTRY_AUTH:-}" ]]; then
    echo "ERROR: Both --internal-registry and --internal-registry-auth must be provided together" >&2
    exit 1
fi

if [[ -n "${INTERNAL_REGISTRY:-}" ]]; then
    DISCONNECTED=true
    echo "Mode: Disconnected cluster"
else
    DISCONNECTED=false
    echo "Mode: Connected cluster"
fi

# Prerequisites

for cmd in oc opm jq podman; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not installed" >&2; exit 1; }
done

[[ ! -f "$QUAY_AUTH" ]] && { echo "ERROR: Quay auth file not found" >&2; exit 1; }
jq empty "$QUAY_AUTH" 2>/dev/null || { echo "ERROR: Invalid JSON in quay auth" >&2; exit 1; }

if [[ "$DISCONNECTED" == true ]]; then
    [[ ! -f "$INTERNAL_REGISTRY_AUTH" ]] && { echo "ERROR: Internal registry auth file not found" >&2; exit 1; }
    jq empty "$INTERNAL_REGISTRY_AUTH" 2>/dev/null || { echo "ERROR: Invalid JSON in internal auth" >&2; exit 1; }
fi

oc cluster-info &> /dev/null || { echo "ERROR: Cannot connect to cluster" >&2; exit 1; }

# Detect cluster version

VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1-2)
[[ -z "$VERSION" ]] && { echo "ERROR: Could not detect cluster version" >&2; exit 1; }
echo "Detected OCP version: ${VERSION}"

# Set operator config

if [[ -n "${OPERATOR:-}" ]]; then
    case "$OPERATOR" in
        sriov)
            FBC_TAG="ocp__${VERSION}__ose-sriov-network-rhel9-operator"
            ;;
        metallb)
            FBC_TAG="ocp__${VERSION}__metallb-rhel9-operator"
            ;;
        nmstate)
            FBC_TAG="ocp__${VERSION}__kubernetes-nmstate-rhel9-operator"
            ;;
        ptp)
            FBC_TAG="ocp__${VERSION}__ose-ptp-rhel9-operator"
            ;;
        pfstatus)
            FBC_TAG="ocp__${VERSION}__pf-status-relay-rhel9-operator"
            ;;
        *) echo "ERROR: Invalid operator: $OPERATOR" >&2; exit 1 ;;
    esac
    CATALOG_NAME="${OPERATOR}-konflux"
else
    FBC_TAG="${FBC_TAG_INPUT}"
    CATALOG_NAME=$(echo "$FBC_TAG" | sed 's/ocp__[^_]*__//' | sed 's/-rhel9-operator$//' | sed 's/-operator$//')-konflux
fi
FBC_SOURCE_IMAGE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
ART_IMAGES_SOURCE="quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share"

# Authenticate registries

if [[ "$DISCONNECTED" == true ]]; then
    quay_auth_b64=""
    quay_auth_source=""
    
    # Priority 1: Try specific repository auth (quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share)
    quay_auth_key=$(jq -r '.auths | to_entries[] | select(.key | contains("quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share")) | .key' "$QUAY_AUTH" 2>/dev/null | head -1)
    if [[ -n "$quay_auth_key" ]]; then
        quay_auth_b64=$(jq -r --arg key "$quay_auth_key" '.auths[$key].auth' "$QUAY_AUTH" 2>/dev/null)
        quay_auth_source="$quay_auth_key"
    fi
    
    # Priority 2: Try broader repository auth (quay.io/redhat-user-workloads)
    if [[ -z "$quay_auth_b64" ]]; then
        quay_auth_key=$(jq -r '.auths | to_entries[] | select(.key | contains("quay.io/redhat-user-workloads")) | .key' "$QUAY_AUTH" 2>/dev/null | head -1)
        if [[ -n "$quay_auth_key" ]]; then
            quay_auth_b64=$(jq -r --arg key "$quay_auth_key" '.auths[$key].auth' "$QUAY_AUTH" 2>/dev/null)
            quay_auth_source="$quay_auth_key"
        fi
    fi
    
    # Priority 3: Fall back to general quay.io domain auth
    if [[ -z "$quay_auth_b64" ]]; then
        quay_auth_key=$(jq -r '.auths | to_entries[] | select(.key | test("^(https://)?quay\\.io/?$")) | .key' "$QUAY_AUTH" 2>/dev/null | head -1)
        if [[ -n "$quay_auth_key" ]]; then
            quay_auth_b64=$(jq -r --arg key "$quay_auth_key" '.auths[$key].auth' "$QUAY_AUTH" 2>/dev/null)
            quay_auth_source="$quay_auth_key"
        fi
    fi
    
    if [[ -n "$quay_auth_b64" ]]; then
        quay_user=$(echo "$quay_auth_b64" | base64 -d | cut -d: -f1)
        quay_pass=$(echo "$quay_auth_b64" | base64 -d | cut -d: -f2-)
        echo "Authenticating to quay.io using credentials from: $quay_auth_source"
        echo "  Username: $quay_user"
        echo "$quay_pass" | podman login --username "$quay_user" --password-stdin quay.io >/dev/null 2>&1
    else
        echo "Authenticating to quay.io using authfile: $QUAY_AUTH"
        podman login --authfile="$QUAY_AUTH" quay.io >/dev/null 2>&1
    fi || { echo "ERROR: Failed to auth quay.io" >&2; exit 1; }
    
    internal_auth_b64=$(jq -r --arg reg "$INTERNAL_REGISTRY" '.auths[$reg].auth // empty' "$INTERNAL_REGISTRY_AUTH" 2>/dev/null)
    if [[ -n "$internal_auth_b64" ]]; then
        internal_user=$(echo "$internal_auth_b64" | base64 -d | cut -d: -f1)
        internal_pass=$(echo "$internal_auth_b64" | base64 -d | cut -d: -f2-)
        echo "$internal_pass" | podman login --username "$internal_user" --password-stdin "$INTERNAL_REGISTRY" >/dev/null 2>&1
    else
        podman login --authfile="$INTERNAL_REGISTRY_AUTH" "$INTERNAL_REGISTRY" >/dev/null 2>&1
    fi || { echo "ERROR: Failed to auth internal registry" >&2; exit 1; }
else
    current_pull_secret=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
    quay_auth_content=$(cat "$QUAY_AUTH")
    merged_auth=$(echo "$current_pull_secret" "$quay_auth_content" | jq -s '.[0].auths * .[1].auths | {auths: .}')
    echo "$merged_auth" | oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin || \
        { echo "ERROR: Failed to update cluster pull-secret" >&2; exit 1; }
    echo "Updated cluster pull-secret with quay.io credentials"
fi

# Mirror FBC image

if [[ "$DISCONNECTED" == true ]]; then
    fbc_target="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
    oc image mirror --keep-manifest-list=true "$FBC_SOURCE_IMAGE" "$fbc_target" || \
        { echo "ERROR: Failed to mirror FBC" >&2; exit 1; }
else
    fbc_target="${FBC_SOURCE_IMAGE}"
fi

# Extract metadata from FBC image

opm_output=$(opm render "$FBC_SOURCE_IMAGE") || { echo "ERROR: opm render failed" >&2; exit 1; }

latest_bundle=$(echo "$opm_output" | jq -r 'select(.schema == "olm.bundle") | .name' | sort -V | tail -1)
[[ -z "$latest_bundle" ]] && { echo "ERROR: No bundle found" >&2; exit 1; }

bundle_data=$(echo "$opm_output" | jq "select(.schema == \"olm.bundle\" and .name == \"$latest_bundle\")")

OPERATOR_NAME=$(echo "$bundle_data" | jq -r '.package // empty' | head -1)
[[ -z "$OPERATOR_NAME" ]] && { echo "ERROR: Could not extract operator name from bundle" >&2; exit 1; }

OPERATOR_NAMESPACE=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.annotations["operatorframework.io/suggested-namespace"] // empty' | head -1)
if [[ -z "$OPERATOR_NAMESPACE" ]]; then
    OPERATOR_NAMESPACE="openshift-${OPERATOR_NAME}"
    NAMESPACE_SOURCE="derived from operator name"
else
    NAMESPACE_SOURCE="from FBC annotation"
fi

# Cleanup existing resources

oc delete namespace "$OPERATOR_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
oc delete catalogsource "$CATALOG_NAME" -n openshift-marketplace --ignore-not-found >/dev/null 2>&1 || true

default_channel=$(echo "$opm_output" | jq -r 'select(.schema == "olm.package") | .defaultChannel // "stable"' | head -1)
[[ -z "$default_channel" ]] && default_channel="stable"

install_mode=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.installModes[]? | select(.supported == true) | .type' | head -1)
[[ -z "$install_mode" ]] && install_mode="SingleNamespace"

# Print extracted metadata

echo "============================================================"
echo "Extracted Metadata:"
echo "============================================================"
echo "Operator Name:    ${OPERATOR_NAME}"
echo "Bundle Name:      ${latest_bundle}"
echo "Namespace:        ${OPERATOR_NAMESPACE} (${NAMESPACE_SOURCE})"
echo "Channel:          ${default_channel}"
echo "Install Mode:     ${install_mode}"
echo "============================================================"
echo "Related Images:"
echo "============================================================"
echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sort -u | nl -w2 -s'. '
echo "============================================================"

# Mirror related images from FBC image

if [[ "$DISCONNECTED" == true ]]; then
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        digest=$(echo "$image" | grep -o 'sha256:[a-f0-9]\{64\}' || continue)
        [[ -z "$digest" ]] && continue
        
        source="${ART_IMAGES_SOURCE}@${digest}"
        target="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
        oc image mirror --keep-manifest-list=true "$source" "$target" </dev/null 2>/dev/null || \
            { echo "ERROR: Failed to mirror $digest" >&2; exit 1; }
    done < <(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sort -u)
fi

# Create IDMS from FBC image

if [[ "$DISCONNECTED" == true ]]; then
    IDMS_NAME=$(echo "$CATALOG_NAME" | sed 's/-konflux$//')-internal-idms
    IDMS_MIRROR="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
else
    IDMS_NAME=$(echo "$CATALOG_NAME" | sed 's/-konflux$//')-art-idms
    IDMS_MIRROR="${ART_IMAGES_SOURCE}"
fi

{
echo "apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${IDMS_NAME}
spec:
  imageDigestMirrors:"
while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    echo "  - mirrors:
    - ${IDMS_MIRROR}
    source: $repo"
done < <(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sed 's/@sha256:[a-f0-9]\{64\}$//' | sort -u)
} | oc apply -f - || { echo "ERROR: IDMS apply failed" >&2; exit 1; }

oc wait --for=condition=Updating mcp --all --timeout=60s >/dev/null 2>&1 || true
oc wait --for=condition=Updating=false mcp --all --timeout=600s >/dev/null 2>&1 || true

# Add insecure registry

if [[ "$DISCONNECTED" == true ]]; then
    oc patch image.config.openshift.io/cluster --patch '{"spec":{ "registrySources": { "insecureRegistries" : ["'"${INTERNAL_REGISTRY}"'"] }}}' --type=merge || \
        { echo "ERROR: Failed to patch image config" >&2; exit 1; }
    
    oc wait --for=condition=Updating mcp --all --timeout=60s >/dev/null 2>&1 || true
    oc wait --for=condition=Updating=false mcp --all --timeout=600s >/dev/null 2>&1 || true
fi

# Disable default catalogs

oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": true}}' --type=merge || \
    { echo "ERROR: Failed to disable default catalogs" >&2; exit 1; }

# Create CatalogSource

oc apply -f - <<EOF || { echo "ERROR: CatalogSource apply failed" >&2; exit 1; }
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  displayName: ${CATALOG_NAME}
  image: ${fbc_target}
  sourceType: grpc
EOF
# Wait for catalog ready
oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
    catalogsource "$CATALOG_NAME" -n openshift-marketplace --timeout=300s 2>/dev/null || true

# Create namespace

oc apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $OPERATOR_NAMESPACE
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF

# Create OperatorGroup

if [[ "$install_mode" == "AllNamespaces" ]]; then
    oc apply -f - <<EOF || { echo "ERROR: OperatorGroup apply failed" >&2; exit 1; }
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec: {}
EOF
else
    oc apply -f - <<EOF || { echo "ERROR: OperatorGroup apply failed" >&2; exit 1; }
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  targetNamespaces:
  - ${OPERATOR_NAMESPACE}
EOF
fi

# Create Subscription

oc apply -f - <<EOF || { echo "ERROR: Subscription apply failed" >&2; exit 1; }
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: $default_channel
  installPlanApproval: Automatic
  name: ${OPERATOR_NAME}
  source: $CATALOG_NAME
  sourceNamespace: openshift-marketplace
EOF

# Wait for CSV

echo "Waiting for CSV ${latest_bundle} to be created..."
oc wait --for=create csv "$latest_bundle" -n "$OPERATOR_NAMESPACE" --timeout=90s 2>/dev/null || \
    { echo "WARNING: CSV ${latest_bundle} was not created within timeout" >&2; }

echo "Waiting for CSV ${latest_bundle} to reach Succeeded phase..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv "$latest_bundle" -n "$OPERATOR_NAMESPACE" --timeout=120s 2>/dev/null || \
    { echo "WARNING: CSV ${latest_bundle} did not reach Succeeded phase within timeout" >&2; }

# Wait for operator pods
echo "Waiting for operator pods to be ready..."
oc wait --for=condition=Ready pods --all -n "$OPERATOR_NAMESPACE" --timeout=120s 2>/dev/null || \
    { echo "WARNING: Operator pods did not reach Ready state within timeout" >&2; }

