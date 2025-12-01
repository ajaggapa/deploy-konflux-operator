#!/bin/bash

set -Eeuo pipefail

VALID_OPERATORS="sriov metallb nmstate ptp pfstatus local-storage"

ART_IMAGES_SOURCE="quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share"
ART_FBC_BASE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc"

run_and_capture() {
    echo "+ $*" >&2
    "$@"
}

sanitize_name() {
    tr ':/_' '-' <<<"$1"
}

get_fbc_tag() {
    local op=$1
    local ver=$2
    case "$op" in
        sriov) echo "ocp__${ver}__ose-sriov-network-rhel9-operator" ;;
        metallb) echo "ocp__${ver}__metallb-rhel9-operator" ;;
        nmstate) echo "ocp__${ver}__kubernetes-nmstate-rhel9-operator" ;;
        ptp) echo "ocp__${ver}__ose-ptp-rhel9-operator" ;;
        pfstatus) echo "ocp__${ver}__pf-status-relay-rhel9-operator" ;;
        local-storage) echo "ocp__${ver}__ose-local-storage-rhel9-operator" ;;
        *) echo "" ;;
    esac
}

print_apply_snippet() {
    local title=$1
    local yaml=$2
    echo ""
    echo "### $title"
    echo "oc apply -f - <<'EOF'"
    printf '%s\n' "$yaml"
    echo "EOF"
}

generate_catalog_source_yaml() {
    local name=$1
    local image=$2
    cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${name}
  namespace: openshift-marketplace
spec:
  displayName: ${name}
  image: ${image}
  sourceType: grpc
EOF
}

generate_namespace_yaml() {
    local name=$1
    cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${name}
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF
}

generate_operator_group_yaml() {
    local namespace=$1
    local install_mode=$2
    local operator_name=$3
    if [[ "$install_mode" == "AllNamespaces" ]]; then
        cat <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${operator_name}
  namespace: ${namespace}
spec: {}
EOF
    else
        cat <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${operator_name}
  namespace: ${namespace}
spec:
  targetNamespaces:
  - ${namespace}
EOF
    fi
}

generate_subscription_yaml() {
    local operator_name=$1
    local namespace=$2
    local channel=$3
    local catalog=$4
    cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${operator_name}
  namespace: ${namespace}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${operator_name}
  source: ${catalog}
  sourceNamespace: openshift-marketplace
EOF
}

generate_idms_yaml() {
    local name=$1
    local mirror=$2
    local repos=$3
    cat <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${name}
spec:
  imageDigestMirrors:
$(while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    cat <<ENTRY
  - mirrors:
    - ${mirror}
    source: ${repo}
ENTRY
done <<< "$repos")
EOF
}

print_step() {
    local number=$1
    local description=$2
    echo ""
    echo "=================================================================="
    echo "Step ${number}: ${description}"
    echo "=================================================================="
}

if [[ "$#" -eq 0 ]]; then
    echo "Usage: $0 [--operator <name>[,<name>...> | --fbc-tag <tag>[,<tag>...]] [--internal-registry REG]"
    exit 1
fi

declare -a OPERATORS=()
declare -a FBC_TAGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --operator)
            OPERATOR="$2"
            shift 2
            ;;
        --fbc-tag)
            FBC_TAG_INPUT="$2"
            shift 2
            ;;
        --internal-registry)
            INTERNAL_REGISTRY="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -n "${OPERATOR:-}" && -n "${FBC_TAG_INPUT:-}" ]]; then
    echo "Provide either --operator or --fbc-tag"
    exit 1
fi

if [[ -z "${OPERATOR:-}" && -z "${FBC_TAG_INPUT:-}" ]]; then
    echo "Provide either --operator or --fbc-tag"
    exit 1
fi

if [[ -n "${OPERATOR:-}" ]]; then
    IFS=',' read -ra OPERATORS <<< "$OPERATOR"
    for op in "${OPERATORS[@]}"; do
        if [[ ! " $VALID_OPERATORS " =~ " $op " ]]; then
            echo "Invalid operator: $op"
            exit 1
        fi
    done
else
    IFS=',' read -ra FBC_TAGS <<< "$FBC_TAG_INPUT"
fi

DISCONNECTED=false
if [[ -n "${INTERNAL_REGISTRY:-}" ]]; then
    DISCONNECTED=true
fi

echo "Dry-run mode: no cluster changes will be made."

MCP_TIMEOUT="600s"

echo ""
echo "Retrieving cluster version..."
VERSION=$(run_and_capture oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1-2 || true)
if [[ -z "$VERSION" && -n "${OPERATORS:-}" ]]; then
    echo "Unable to detect cluster version; required for --operator mode."
    exit 1
fi
[[ -z "$VERSION" ]] && VERSION="unknown"
echo "OpenShift version detected: $VERSION"

declare -a DEPLOYMENT_KEYS=()
declare -A CATALOG_NAMES
declare -A FBC_SOURCES
declare -A FBC_TARGETS
declare -A OPERATOR_NAMES
declare -A OPERATOR_BUNDLES
declare -A OPERATOR_NAMESPACES
declare -A OPERATOR_CHANNELS
declare -A OPERATOR_INSTALL_MODES
declare -A OPERATOR_RELATED_REPOS
declare -A OPERATOR_RELATED_IMAGES

if ((${#OPERATORS[@]} > 0)); then
    for op in "${OPERATORS[@]}"; do
        fbc_tag=$(get_fbc_tag "$op" "$VERSION")
        [[ -z "$fbc_tag" ]] && { echo "No FBC tag mapping for $op"; exit 1; }
        DEPLOYMENT_KEYS+=("$op")
        CATALOG_NAMES[$op]="${op}-konflux"
        FBC_SOURCES[$op]="${ART_FBC_BASE}:${fbc_tag}"
        if [[ "$DISCONNECTED" == true ]]; then
            FBC_TARGETS[$op]="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${fbc_tag}"
        else
            FBC_TARGETS[$op]="${FBC_SOURCES[$op]}"
        fi
    done
else
    for fbc_tag in "${FBC_TAGS[@]}"; do
        DEPLOYMENT_KEYS+=("$fbc_tag")
        sanitized=$(sanitize_name "$fbc_tag")
        CATALOG_NAMES[$fbc_tag]="${sanitized}-konflux"
        FBC_SOURCES[$fbc_tag]="${ART_FBC_BASE}:${fbc_tag}"
        if [[ "$DISCONNECTED" == true ]]; then
            FBC_TARGETS[$fbc_tag]="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${fbc_tag}"
        else
            FBC_TARGETS[$fbc_tag]="${FBC_SOURCES[$fbc_tag]}"
        fi
    done
fi

print_step 1 "Authenticate to registries"
if [[ "$DISCONNECTED" == true ]]; then
    echo "  podman login --authfile <quay-auth.json> quay.io"
    echo "  podman login --authfile <internal-registry-auth.json> ${INTERNAL_REGISTRY}"
else
    echo "  podman login --authfile <quay-auth.json> quay.io    # optional if cluster already has access"
    echo "  (deploy-operator.sh merges this auth into the cluster pull-secret when provided)"
fi

print_step 2 "Mirror FBC images (Disconnected only)"
if [[ "$DISCONNECTED" == true ]]; then
    for key in "${DEPLOYMENT_KEYS[@]}"; do
        echo "  oc image mirror --keep-manifest-list=true \"${FBC_SOURCES[$key]}\" \"${FBC_TARGETS[$key]}\""
    done
else
    echo "  Connected cluster: script reads FBC images directly from quay.io"
fi

print_step 3 "Extract metadata from FBC"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    fbc_source="${FBC_SOURCES[$key]}"
    echo ""
    echo ">>> Rendering ${fbc_source}"
    opm_output=$(run_and_capture opm render "$fbc_source")

    latest_bundle=$(echo "$opm_output" | jq -r 'select(.schema == "olm.bundle") | .name' | sort -V | tail -1)
    [[ -z "$latest_bundle" ]] && { echo "No bundle found for $key"; exit 1; }

    bundle_data=$(echo "$opm_output" | jq "select(.schema == \"olm.bundle\" and .name == \"$latest_bundle\")")
    operator_name=$(echo "$bundle_data" | jq -r '.package // empty' | head -1)
    [[ -z "$operator_name" ]] && { echo "Missing operator name for $key"; exit 1; }

    operator_namespace=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.annotations["operatorframework.io/suggested-namespace"] // empty' | head -1)
    namespace_source="annotated"
    if [[ -z "$operator_namespace" ]]; then
        operator_namespace="openshift-${operator_name}"
        namespace_source="derived"
    fi

    default_channel=$(echo "$opm_output" | jq -r 'select(.schema == "olm.package") | .defaultChannel // empty' | head -1)
    [[ -z "$default_channel" ]] && default_channel="stable"

    install_mode=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.installModes[]? | select(.supported == true) | .type' | head -1)
    [[ -z "$install_mode" ]] && install_mode="SingleNamespace"

    related_images=$(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | sort -u)
    related_repos=$(printf '%s\n' "$related_images" | sed 's/@sha256:[a-f0-9]\{64\}$//' | sort -u)

    OPERATOR_NAMES[$key]="$operator_name"
    OPERATOR_BUNDLES[$key]="$latest_bundle"
    OPERATOR_NAMESPACES[$key]="$operator_namespace"
    OPERATOR_CHANNELS[$key]="$default_channel"
    OPERATOR_INSTALL_MODES[$key]="$install_mode"
    OPERATOR_RELATED_REPOS[$key]="$related_repos"
    OPERATOR_RELATED_IMAGES[$key]="$related_images"

    echo "Extracted Metadata:"
    echo "  Operator Name   : $operator_name"
    echo "  Latest Bundle   : $latest_bundle"
    echo "  Namespace       : $operator_namespace ($namespace_source)"
    echo "  Default Channel : $default_channel"
    echo "  Install Mode    : $install_mode"
    echo "  Related Images:"
    printf '    - %s\n' $related_images
done

print_step 4 "Mirror related images (Disconnected only)"
if [[ "$DISCONNECTED" == true ]]; then
    digest_target="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
    for key in "${DEPLOYMENT_KEYS[@]}"; do
        related_list="${OPERATOR_RELATED_IMAGES[$key]}"
        [[ -z "$related_list" ]] && continue
        echo "  # ${key}"
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            digest=$(echo "$image" | grep -o 'sha256:[a-f0-9]\{64\}')
            [[ -z "$digest" ]] && continue
            echo "  oc image mirror --keep-manifest-list=true -a <auth-file-path-with-quay-and-internal-registry-auth> \"${ART_IMAGES_SOURCE}@${digest}\" \"${digest_target}\""
        done <<< "$related_list"
    done
else
    echo "  Connected cluster: use related images directly from quay.io"
fi

print_step 5 "Update cluster pull-secret (Connected only)"
if [[ "$DISCONNECTED" == true ]]; then
    echo "  Disconnected mode relies on internal registry auth; skip this step."
else
    echo "  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\\.dockerconfigjson}' | base64 -d > current-pull-secret.json"
    echo "  jq -s '{auths:(.[0].auths + .[1].auths)}' current-pull-secret.json <quay-auth.json> > merged-pull-secret.json"
    echo "  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=merged-pull-secret.json"
fi

print_step 6 "Configure insecure registry (Disconnected only)"
if [[ "$DISCONNECTED" == true ]]; then
    echo "  oc patch image.config.openshift.io/cluster --patch '{\"spec\":{\"registrySources\":{\"insecureRegistries\":[\"${INTERNAL_REGISTRY}\"]}}}' --type=merge"
else
    echo "  Connected cluster: no insecure registry configuration required."
fi

IDMS_MIRROR="$ART_IMAGES_SOURCE"
IDMS_SUFFIX="art-idms"
if [[ "$DISCONNECTED" == true ]]; then
    IDMS_MIRROR="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
    IDMS_SUFFIX="internal-idms"
fi

print_step 7 "Create Image Digest Mirror Sets (IDMS)"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    related_repos="${OPERATOR_RELATED_REPOS[$key]}"
    sanitized_key=$(sanitize_name "$key")
    idms_name="${sanitized_key}-${IDMS_SUFFIX}"
    print_apply_snippet "IDMS (${idms_name})" "$(generate_idms_yaml "$idms_name" "$IDMS_MIRROR" "$related_repos")"
done

print_step 8 "Wait for Machine Config Pool update"
echo "  oc wait --for=condition=Updating mcp --all --timeout=60s || true"
echo "  oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} || true"

print_step 9 "Create CatalogSource resources"
echo "  oc patch operatorhub cluster -p '{\"spec\":{\"disableAllDefaultSources\":true}}' --type=merge"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    catalog_name="${CATALOG_NAMES[$key]}"
    fbc_target="${FBC_TARGETS[$key]}"
    print_apply_snippet "CatalogSource (${catalog_name})" "$(generate_catalog_source_yaml "$catalog_name" "$fbc_target")"
done

print_step 10 "Create Namespaces"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    operator_namespace="${OPERATOR_NAMESPACES[$key]}"
    print_apply_snippet "Namespace (${operator_namespace})" "$(generate_namespace_yaml "$operator_namespace")"
done

print_step 11 "Create OperatorGroups"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    operator_namespace="${OPERATOR_NAMESPACES[$key]}"
    install_mode="${OPERATOR_INSTALL_MODES[$key]}"
    operator_name="${OPERATOR_NAMES[$key]}"
    print_apply_snippet "OperatorGroup (${operator_name})" "$(generate_operator_group_yaml "$operator_namespace" "$install_mode" "$operator_name")"
done

print_step 12 "Create Subscriptions"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    operator_name="${OPERATOR_NAMES[$key]}"
    operator_namespace="${OPERATOR_NAMESPACES[$key]}"
    default_channel="${OPERATOR_CHANNELS[$key]}"
    catalog_name="${CATALOG_NAMES[$key]}"
    print_apply_snippet "Subscription (${operator_name})" "$(generate_subscription_yaml "$operator_name" "$operator_namespace" "$default_channel" "$catalog_name")"
done

print_step 13 "Wait for CSV to reach Succeeded"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    operator_namespace="${OPERATOR_NAMESPACES[$key]}"
    latest_bundle="${OPERATOR_BUNDLES[$key]}"
    echo "  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv \"${latest_bundle}\" -n \"${operator_namespace}\" --timeout=120s"
done

print_step 14 "Wait for operator pods to be Ready"
for key in "${DEPLOYMENT_KEYS[@]}"; do
    operator_namespace="${OPERATOR_NAMESPACES[$key]}"
    echo "  oc wait --for=condition=Ready pods --all -n \"${operator_namespace}\" --timeout=120s"
done

echo ""
echo "Dry-run complete. Review the commands/YAML above to perform an actual deployment."

