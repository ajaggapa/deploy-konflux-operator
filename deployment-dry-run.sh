#!/bin/bash

set -Eeuo pipefail

VALID_OPERATORS="sriov metallb nmstate ptp pfstatus local-storage ingress-node-firewall"

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
        ingress-node-firewall) echo "ocp__${ver}__ingress-node-firewall-rhel9-operator" ;;
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
    cat <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${name}
spec:
  imageDigestMirrors:
    - mirrors:
        - ${mirror}
      source: registry.redhat.io
EOF
}

print_pull_secret_update() {
    local auth_file=$1
    printf '  AUTH_FILE=%s\n' "$auth_file"
    cat <<'EOF'
  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > current-pull-secret.json
  jq -s '
    .[0].auths as $current |
    (.[1].auths | with_entries(select(.key | contains("quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share") | not))) as $new |
    {auths: ($current + $new)}
  ' current-pull-secret.json "$AUTH_FILE" > merged-pull-secret.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=merged-pull-secret.json
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
    echo "Usage: $0 [--operator <name>[,<name>...> | --fbc-tag <tag>[,<tag>...]]"
    echo "          [--internal-registry REG | --internal-registry-proxy REG]"
    echo "          [--mcp-timeout DURATION]"
    exit 1
fi

declare -a OPERATORS=()
declare -a FBC_TAGS=()
MCP_TIMEOUT="${MCP_TIMEOUT:-600s}"

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
        --internal-registry-proxy)
            INTERNAL_REGISTRY_PROXY="$2"
            shift 2
            ;;
        --mcp-timeout)
            MCP_TIMEOUT="$2"
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

# Validate mutual exclusivity of registry modes
if [[ -n "${INTERNAL_REGISTRY:-}" && -n "${INTERNAL_REGISTRY_PROXY:-}" ]]; then
    echo "ERROR: Cannot use both --internal-registry and --internal-registry-proxy"
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
USE_REGISTRY_PROXY=false

if [[ -n "${INTERNAL_REGISTRY:-}" ]]; then
    DISCONNECTED=true
elif [[ -n "${INTERNAL_REGISTRY_PROXY:-}" ]]; then
    DISCONNECTED=true
    USE_REGISTRY_PROXY=true
fi

echo "Dry-run mode: no cluster changes will be made."

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
declare -a ALL_RELATED_IMAGES=()

if ((${#OPERATORS[@]} > 0)); then
    for op in "${OPERATORS[@]}"; do
        fbc_tag=$(get_fbc_tag "$op" "$VERSION")
        [[ -z "$fbc_tag" ]] && { echo "No FBC tag mapping for $op"; exit 1; }
        DEPLOYMENT_KEYS+=("$op")
        CATALOG_NAMES[$op]="${op}-konflux"
        FBC_SOURCES[$op]="${ART_FBC_BASE}:${fbc_tag}"
        if [[ "$DISCONNECTED" == true ]]; then
            registry_target="${INTERNAL_REGISTRY:-}"
            if [[ "$USE_REGISTRY_PROXY" == true ]]; then
                registry_target="${INTERNAL_REGISTRY_PROXY}"
            fi
            FBC_TARGETS[$op]="${registry_target}/redhat-user-workloads/ocp-art-tenant/art-fbc:${fbc_tag}"
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
            registry_target="${INTERNAL_REGISTRY:-}"
            if [[ "$USE_REGISTRY_PROXY" == true ]]; then
                registry_target="${INTERNAL_REGISTRY_PROXY}"
            fi
            FBC_TARGETS[$fbc_tag]="${registry_target}/redhat-user-workloads/ocp-art-tenant/art-fbc:${fbc_tag}"
        else
            FBC_TARGETS[$fbc_tag]="${FBC_SOURCES[$fbc_tag]}"
        fi
    done
fi

print_step 1 "Prepare registry authentication"
if [[ "$DISCONNECTED" == true ]]; then
    if [[ "$USE_REGISTRY_PROXY" == true ]]; then
        echo "  # Proxy mode: merge --internal-registry-proxy-auth into the cluster pull-secret."
        print_pull_secret_update "/path/to/internal-registry-proxy-auth.json"
    else
        echo "  # Mirror mode: authenticate to the internal registry."
        echo "  INTERNAL_REGISTRY_AUTH=/path/to/internal-registry-auth.json"
        echo "  podman login --authfile=\"\$INTERNAL_REGISTRY_AUTH\" \"${INTERNAL_REGISTRY}\""
        echo "  # --registry-auth supplies stage pull credentials for Step 4."
    fi
else
    echo "  # Optional: use --registry-auth if the cluster pull-secret lacks stage registry credentials."
    print_pull_secret_update "/path/to/registry-auth.json"
fi

print_step 2 "Mirror FBC images (Disconnected mirror mode only)"
if [[ "$DISCONNECTED" == true && "$USE_REGISTRY_PROXY" == false ]]; then
    for key in "${DEPLOYMENT_KEYS[@]}"; do
        echo "  oc image mirror --keep-manifest-list=true \"${FBC_SOURCES[$key]}\" \"${FBC_TARGETS[$key]}\""
    done
elif [[ "$USE_REGISTRY_PROXY" == true ]]; then
    echo "  Proxy mode: Images pulled through proxy registry - no mirroring needed"
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
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        ALL_RELATED_IMAGES+=("$image")
    done <<< "$related_images"

    OPERATOR_NAMES[$key]="$operator_name"
    OPERATOR_BUNDLES[$key]="$latest_bundle"
    OPERATOR_NAMESPACES[$key]="$operator_namespace"
    OPERATOR_CHANNELS[$key]="$default_channel"
    OPERATOR_INSTALL_MODES[$key]="$install_mode"

    echo "Extracted Metadata:"
    echo "  Operator Name   : $operator_name"
    echo "  Latest Bundle   : $latest_bundle"
    echo "  Namespace       : $operator_namespace ($namespace_source)"
    echo "  Default Channel : $default_channel"
    echo "  Install Mode    : $install_mode"
    echo "  Related Images:"
    while IFS= read -r image; do
        [[ -z "$image" ]] || printf '    - %s\n' "$image"
    done <<< "$related_images"
done

print_step 4 "Mirror related images (Disconnected mirror mode only)"
if [[ "$DISCONNECTED" == true && "$USE_REGISTRY_PROXY" == false ]]; then
    echo "  # Merge --registry-auth and --internal-registry-auth for stage pulls and internal pushes."
    cat <<'EOF'
  REGISTRY_AUTH=/path/to/registry-auth.json
  jq -s '{auths: ((.[0].auths | with_entries(select(.key | contains("quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share") | not))) + .[1].auths)}' "$REGISTRY_AUTH" "$INTERNAL_REGISTRY_AUTH" > merged-auth.json
EOF
    mapfile -t UNIQUE_RELATED_IMAGES < <(printf '%s\n' "${ALL_RELATED_IMAGES[@]}" | sed '/^$/d' | sort -u)
    for image in "${UNIQUE_RELATED_IMAGES[@]}"; do
        if [[ ! "$image" =~ ^registry\.redhat\.io/([^@]+)@sha256:([a-f0-9]{64})$ ]]; then
            echo "ERROR: Expected a registry.redhat.io related image with a sha256 digest: $image" >&2
            exit 1
        fi
        image_path="${BASH_REMATCH[1]}"
        source="registry.stage.redhat.io/${image#registry.redhat.io/}"
        target="${INTERNAL_REGISTRY}/${image_path%:*}"
        echo "  oc image mirror --keep-manifest-list=true -a merged-auth.json \"${source}\" \"${target}\""
    done
    echo "  rm -f merged-auth.json"
elif [[ "$USE_REGISTRY_PROXY" == true ]]; then
    echo "  Proxy mode: Related images are pulled through the proxy at the same repository path and digest."
else
    echo "  Connected cluster: the IDMS in Step 5 directs related image pulls to registry.stage.redhat.io."
fi

print_step 5 "Create Image Digest Mirror Set (IDMS)"
if [[ "$DISCONNECTED" == true ]]; then
    IDMS_MIRROR="${INTERNAL_REGISTRY:-$INTERNAL_REGISTRY_PROXY}"
    IDMS_NAME="internal-idms"
else
    IDMS_MIRROR="registry.stage.redhat.io"
    IDMS_NAME="stage-idms"
fi
print_apply_snippet "IDMS (${IDMS_NAME})" "$(generate_idms_yaml "$IDMS_NAME" "$IDMS_MIRROR")"

print_step 6 "Wait for Machine Config Pool update after IDMS"
echo "  oc wait --for=condition=Updating mcp --all --timeout=60s || true"
echo "  oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} || true"

print_step 7 "Configure insecure registry (Disconnected only)"
if [[ "$DISCONNECTED" == true ]]; then
    registry_to_configure="${INTERNAL_REGISTRY:-$INTERNAL_REGISTRY_PROXY}"
    echo "  oc patch image.config.openshift.io/cluster --patch '{\"spec\":{\"registrySources\":{\"insecureRegistries\":[\"${registry_to_configure}\"]}}}' --type=merge"
else
    echo "  Connected cluster: no insecure registry configuration required."
fi

print_step 8 "Wait for Machine Config Pool update after registry configuration"
if [[ "$DISCONNECTED" == true ]]; then
    echo "  oc wait --for=condition=Updating mcp --all --timeout=60s || true"
    echo "  oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} || true"
else
    echo "  Connected cluster: no second Machine Config Pool update required."
fi

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

