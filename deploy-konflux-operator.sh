#!/bin/bash

# Konflux Operator Installation Script for Disconnected OpenShift Cluster
# This script automates the complete installation process for telco operators:
# sriov, metallb, nmstate, ptp

set -Eeuo pipefail
set +x

# Function to display usage
usage() {
    cat <<EOF
Usage: $0 --version <version> --operator <operator> --internal-registry <registry_url> --internal-registry-auth <auth_file> --quay-auth <quay_auth_file> [--dry-run]

Arguments:
  --version <version>                    OpenShift version (e.g., 4.20)
  --operator <operator>                  Operator to install: sriov|metallb|nmstate|ptp
  --internal-registry <registry_url>     URL of internal registry
  --internal-registry-auth <auth_file>   Auth file for internal registry
  --quay-auth <quay_auth_file>          Auth file for quay.io
  --dry-run                             Show what would be done without executing (optional)

Examples:
  $0 --version 4.20 --operator sriov --internal-registry registry.example.com:5000 --internal-registry-auth /path/to/auth.json --quay-auth /path/to/quay-auth.json
  
  # Dry-run mode (shows what would be done without executing):
  $0 --version 4.20 --operator sriov --internal-registry registry.example.com:5000 --internal-registry-auth /path/to/auth.json --quay-auth /path/to/quay-auth.json --dry-run

EOF
    exit 1
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                VERSION="$2"
                shift 2
                ;;
            --operator)
                OPERATOR="$2"
                shift 2
                ;;
            --internal-registry)
                INTERNAL_REGISTRY="$2"
                shift 2
                ;;
            --internal-registry-auth)
                INTERNAL_REGISTRY_AUTH="$2"
                shift 2
                ;;
            --quay-auth)
                QUAY_AUTH="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift 1
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                ;;
        esac
    done

    # Verify all mandatory arguments are provided
    local missing_args=()
    [[ -z "${VERSION:-}" ]] && missing_args+=("--version")
    [[ -z "${OPERATOR:-}" ]] && missing_args+=("--operator")
    [[ -z "${INTERNAL_REGISTRY:-}" ]] && missing_args+=("--internal-registry")
    [[ -z "${INTERNAL_REGISTRY_AUTH:-}" ]] && missing_args+=("--internal-registry-auth")
    [[ -z "${QUAY_AUTH:-}" ]] && missing_args+=("--quay-auth")

    if [[ ${#missing_args[@]} -gt 0 ]]; then
        log_error "Missing mandatory arguments: ${missing_args[*]}"
        usage
    fi

    # Validate operator value
    case "$OPERATOR" in
        sriov|metallb|nmstate|ptp)
            ;;
        *)
            log_error "Invalid operator: $OPERATOR. Must be one of: sriov, metallb, nmstate, ptp"
            usage
            ;;
    esac
}

# Set operator-specific configuration
set_operator_config() {
    case "$OPERATOR" in
        sriov)
            FBC_TAG="ocp__${VERSION}__ose-sriov-network-rhel9-operator"
            OPERATOR_NAMESPACE="openshift-sriov-network-operator"
            OPERATOR_NAME="sriov-network-operator"
            ;;
        metallb)
            FBC_TAG="ocp__${VERSION}__metallb-rhel9-operator"
            OPERATOR_NAMESPACE="metallb-system"
            OPERATOR_NAME="metallb-operator"
            ;;
        nmstate)
            FBC_TAG="ocp__${VERSION}__kubernetes-nmstate-rhel9-operator"
            OPERATOR_NAMESPACE="openshift-nmstate"
            OPERATOR_NAME="kubernetes-nmstate-operator"
            ;;
        ptp)
            FBC_TAG="ocp__${VERSION}__ose-ptp-rhel9-operator"
            OPERATOR_NAMESPACE="openshift-ptp"
            OPERATOR_NAME="ptp-operator"
            ;;
    esac

    # Set dynamic configuration variables
    FBC_SOURCE_IMAGE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
    ART_IMAGES_SOURCE="quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share"
    CATALOG_NAME="${OPERATOR}-konflux"
    LOCAL_REGISTRY="$INTERNAL_REGISTRY"
    AUTHFILE="$INTERNAL_REGISTRY_AUTH"
}

# Minimal logging functions
log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

# Dry-run helpers
show_command() {
    echo "[DRY-RUN] Command to be executed:"
    echo "===================================================================================="
    echo "  $1"
    echo "===================================================================================="
}

show_yaml() {
    local yaml_file="$1"
    local description="$2"
    echo "[DRY-RUN] $description"
    echo "===================================================================================="
    if [[ -f "$yaml_file" ]]; then
        # Indent YAML content for better visibility
        sed 's/^/  /' "$yaml_file"
    else
        echo "  File not found: $yaml_file"
    fi
    echo "===================================================================================="
    echo
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check required commands with helpful error messages
    local required_commands=("oc" "opm" "jq" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                oc) log_error "OpenShift CLI (oc) is not installed. Please install oc and try again." ;;
                opm) log_error "OPM CLI (opm) is not installed. Please install opm and try again." ;;
                jq) log_error "jq is not installed. Please install jq (for JSON parsing) and try again." ;;
                *) log_error "Required command not found: $cmd" ;;
            esac
            exit 1
        fi
    done
    
    # Check if required files exist
    if [[ ! -f "$AUTHFILE" ]]; then
        log_error "Auth file not found: $AUTHFILE. Please ensure the file exists and is readable."
        exit 1
    fi
    
    # Test cluster connectivity
    if ! oc cluster-info &> /dev/null; then
        log_error "Cannot connect to OpenShift cluster. Ensure you are logged in (oc login) and have administrative privileges."
        exit 1
    fi
      
    log_success "Prerequisites check passed"
}

cleanup_existing_resources() {
    log_info "Step 0: Cleaning up existing resources..."
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_command "oc delete namespace \"$OPERATOR_NAMESPACE\" --ignore-not-found"
        show_command "oc delete catalogsource \"$CATALOG_NAME\" -n openshift-marketplace --ignore-not-found"
        return 0
    fi
    
    # Delete existing resources
    oc delete namespace "$OPERATOR_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    oc delete catalogsource "$CATALOG_NAME" -n openshift-marketplace --ignore-not-found >/dev/null 2>&1 || true
    
    log_success "Resource cleanup completed"
}

# Step 1: Mirror FBC image to local registry
mirror_fbc_image() {
    log_info "Step 1: Mirroring FBC image..."
    
    local fbc_target_image="${LOCAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_command "oc image mirror -a=\"$QUAY_AUTH\" --keep-manifest-list=true \"$FBC_SOURCE_IMAGE\" \"$fbc_target_image\""
        echo "$fbc_target_image" > /tmp/fbc_image_url
    else
        if oc image mirror \
            -a="$QUAY_AUTH" \
            --keep-manifest-list=true \
            "$FBC_SOURCE_IMAGE" "$fbc_target_image"; then
            log_success "FBC image mirrored successfully"
            echo "$fbc_target_image" > /tmp/fbc_image_url
        else
            log_error "Failed to mirror FBC image"
            exit 1
        fi
    fi
}

# Step 2: Extract operator metadata (images, channel, install mode) using opm render
extract_operator_metadata() {
    log_info "Step 2: Extracting operator metadata using opm render..."
    
    local temp_render_output="/tmp/opm_render_output.json"
    local channel_file="/tmp/${OPERATOR}_default_channel.txt"
    local install_mode_file="/tmp/${OPERATOR}_install_mode.txt"
    
    # Use opm render to get the catalog content with quay auth (run even in dry-run to get real data)
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_command "REGISTRY_AUTH_FILE=\"$QUAY_AUTH\" opm render \"$FBC_SOURCE_IMAGE\" > \"$temp_render_output\""
        log_info "[DRY-RUN] Extracting operator metadata from FBC image to populate YAMLs with real data..."
    fi
    
    if REGISTRY_AUTH_FILE="$QUAY_AUTH" opm render "$FBC_SOURCE_IMAGE" > "$temp_render_output"; then
        log_success "OPM render completed successfully"
    else
        log_error "Failed to render FBC image with opm"
        exit 1
    fi
    
    # Extract relatedImages, repositories, and metadata
    log_info "Parsing operator metadata from catalog content..."
    
    local related_images_file="/tmp/${OPERATOR}_related_images.txt"
    local repositories_file="/tmp/${OPERATOR}_repositories.txt"
    
    # Clear previous files
    > "$related_images_file"
    > "$repositories_file"
    > "$channel_file"
    > "$install_mode_file"
    
    # Extract full related images and unique repositories
    if command -v jq &> /dev/null; then
        # Extract full related images (repo@digest format)
        jq -r '.relatedImages[]?.image // empty' "$temp_render_output" | \
        grep -v '^$' | sort -u > "$related_images_file"
        
        # Extract unique repositories (without digests) for IDMS
        jq -r '.relatedImages[]?.image // empty' "$temp_render_output" | \
        grep -v '^$' | \
        sed 's/@sha256:[a-f0-9]\{64\}$//' | \
        sort -u > "$repositories_file"
        
        # Extract defaultChannel from the package
        jq -r 'select(.schema == "olm.package") | .defaultChannel // empty' "$temp_render_output" | \
        head -1 > "$channel_file"
        
        # Extract installMode - find the first supported install mode from bundle metadata
        local supported_install_mode=$(jq -r '
            select(.schema == "olm.bundle") | 
            .properties[]? | 
            select(.type == "olm.csv.metadata") | 
            .value.installModes[]? | 
            select(.supported == true) | 
            .type' "$temp_render_output" | head -1)
        
        if [[ -n "$supported_install_mode" ]]; then
            echo "$supported_install_mode" > "$install_mode_file"
        else
            # Fallback to SingleNamespace if no modes found
            echo "SingleNamespace" > "$install_mode_file"
        fi
    else
        # Fallback if jq is not available
        grep -o '[^"]*@sha256:[a-f0-9]\{64\}' "$temp_render_output" | \
        sort -u > "$related_images_file"
        
        # Extract repositories without digests
        grep -o '[^"]*@sha256:[a-f0-9]\{64\}' "$temp_render_output" | \
        sed 's/@sha256:[a-f0-9]\{64\}$//' | \
        sort -u > "$repositories_file"
        
        # Extract defaultChannel using grep (fallback)
        grep -o '"defaultChannel"[[:space:]]*:[[:space:]]*"[^"]*"' "$temp_render_output" | \
        sed 's/.*"defaultChannel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | \
        head -1 > "$channel_file"
        
        # Extract install mode using grep (fallback) - find the first supported mode in bundle metadata
        # Look for installModes within olm.csv.metadata property
        if grep -q '"olm.csv.metadata"' "$temp_render_output"; then
            if grep -A 20 '"olm.csv.metadata"' "$temp_render_output" | \
               grep -A 5 -B 5 '"type"[[:space:]]*:[[:space:]]*"AllNamespaces"' | \
               grep -q '"supported"[[:space:]]*:[[:space:]]*true'; then
                echo "AllNamespaces" > "$install_mode_file"
            elif grep -A 20 '"olm.csv.metadata"' "$temp_render_output" | \
                 grep -A 5 -B 5 '"type"[[:space:]]*:[[:space:]]*"SingleNamespace"' | \
                 grep -q '"supported"[[:space:]]*:[[:space:]]*true'; then
                echo "SingleNamespace" > "$install_mode_file"
            elif grep -A 20 '"olm.csv.metadata"' "$temp_render_output" | \
                 grep -A 5 -B 5 '"type"[[:space:]]*:[[:space:]]*"MultiNamespace"' | \
                 grep -q '"supported"[[:space:]]*:[[:space:]]*true'; then
                echo "MultiNamespace" > "$install_mode_file"
            else
                echo "SingleNamespace" > "$install_mode_file"
            fi
        else
            echo "SingleNamespace" > "$install_mode_file"
        fi
    fi
    
    local images_count=$(wc -l < "$related_images_file")
    local repos_count=$(wc -l < "$repositories_file")
    local default_channel=$(cat "$channel_file" 2>/dev/null || echo "")
    local install_mode=$(cat "$install_mode_file" 2>/dev/null || echo "OwnNamespace")
    
    if [[ $images_count -eq 0 ]]; then
        log_error "No related images found"
        exit 1
    fi
    
    if [[ -z "$default_channel" ]]; then
        echo "stable" > "$channel_file"
        default_channel="stable"
    fi
    
    # Display extracted metadata (including in dry-run mode)
    log_info "Extracted operator metadata:"
    log_info "  - Default Channel: $default_channel"
    log_info "  - Install Mode: $install_mode"
    log_info "  - Related Images: $images_count"
    log_info "  - Repository Mappings: $repos_count"
    
    log_success "Operator metadata extraction completed successfully"
}

# Step 3: Mirror related images to local registry
mirror_related_images() {
    log_info "Step 3: Mirroring related images..."
    
    local related_images_file="/tmp/${OPERATOR}_related_images.txt"
    local mapping_file="/tmp/${OPERATOR}_image_mappings.txt"
    
    > "$mapping_file"
    
    local success_count=0
    local total_count=$(wc -l < "$related_images_file")
    
    while IFS= read -r image || [[ -n "$image" ]]; do
        [[ -z "$image" ]] && continue
        
        local digest=$(echo "$image" | grep -o 'sha256:[a-f0-9]\{64\}' || echo "")
        [[ -z "$digest" ]] && continue
        
        local source_image="${ART_IMAGES_SOURCE}@${digest}"
        local target_image="${LOCAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
        echo "${source_image}=${target_image}" >> "$mapping_file"
        
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            show_command "oc image mirror -a=\"$QUAY_AUTH\" --keep-manifest-list=true \"$source_image\" \"$target_image\""
            ((++success_count))
        else
            if oc image mirror \
                -a="$QUAY_AUTH" \
                --keep-manifest-list=true \
                "$source_image" "$target_image" </dev/null 2>/dev/null; then
                ((++success_count))
            else
                log_error "Failed to mirror image: $source_image"
                exit 1
            fi
        fi
    done < "$related_images_file"
    
    log_success "Successfully mirrored $success_count/$total_count images"
}

# Step 4: Create and apply ImageDigestMirrorSet
create_image_digest_mirror_set() {
    log_info "Step 4: Creating ImageDigestMirrorSet..."
    
    local repositories_file="/tmp/${OPERATOR}_repositories.txt"
    local idms_yaml="/tmp/${OPERATOR}_idms.yaml"
    
    if [[ ! -f "$repositories_file" ]] || [[ ! -s "$repositories_file" ]]; then
        log_error "Repositories file not found or empty: $repositories_file"
        exit 1
    fi
    
    local repos_count=$(wc -l < "$repositories_file")
    log_info "Creating IDMS with $repos_count repository mappings"
    
    # Create IDMS YAML header
    cat > "$idms_yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${OPERATOR}-internal-idms
spec:
  imageDigestMirrors:
EOF
    
    # Add each repository mapping to the IDMS
    while IFS= read -r repo || [[ -n "$repo" ]]; do
        [[ -z "$repo" ]] && continue
        
        cat >> "$idms_yaml" <<EOF
  - mirrors:
    - ${LOCAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share
    source: $repo
EOF
    done < "$repositories_file"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_yaml "$idms_yaml" "ImageDigestMirrorSet that would be applied"
        show_command "oc apply -f \"$idms_yaml\""
    else
        if oc apply -f "$idms_yaml"; then
            log_success "ImageDigestMirrorSet created successfully"
        else
            log_error "Failed to create ImageDigestMirrorSet"
            exit 1
        fi
    fi
}

# Step 5: Wait for MachineConfigPool updates after IDMS
wait_for_mcp_update() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "Step 5: [DRY-RUN] Would wait for MachineConfigPool updates..."
        show_command "oc wait --for=condition=Updating mcp --all --timeout=300s"
        show_command "oc wait --for=condition=Updating=false mcp --all --timeout=600s"
        return 0
    fi
    
    log_info "Step 5: Waiting for MachineConfigPool updates..."
    
    # Wait for MCP updates (best effort)
    oc wait --for=condition=Updating mcp --all --timeout=300s >/dev/null 2>&1 || true
    oc wait --for=condition=Updating=false mcp --all --timeout=600s >/dev/null 2>&1 || true
    
    log_success "MachineConfigPool update process completed"
}

# Step 6: Apply CatalogSource YAML
apply_catalog_source() {
    log_info "Step 6: Creating CatalogSource..."
    
    # Get FBC image URL - handle both dry-run and real execution
    local fbc_image_url
    if [[ -f "/tmp/fbc_image_url" ]]; then
        fbc_image_url=$(cat /tmp/fbc_image_url)
    else
        # Fallback for dry-run mode if file doesn't exist
        fbc_image_url="${LOCAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
    fi
    
    # Create proper operator display name (avoid ${OPERATOR^} syntax issues)
    local operator_display_name
    case "$OPERATOR" in
        sriov) operator_display_name="SRIOV" ;;
        metallb) operator_display_name="MetalLB" ;;
        nmstate) operator_display_name="NMState" ;;
        ptp) operator_display_name="PTP" ;;
        *) operator_display_name="$(echo "$OPERATOR" | sed 's/^./\U&/')" ;;
    esac
    
    local catalog_yaml="/tmp/${OPERATOR}_catalog_source.yaml"
    
    # Generate YAML with properly substituted variables
    cat > "$catalog_yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  displayName: ${operator_display_name} Konflux Catalog
  image: ${fbc_image_url}
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_yaml "$catalog_yaml" "CatalogSource that would be applied"
        show_command "oc apply -f \"$catalog_yaml\""
    else
        if oc apply -f "$catalog_yaml"; then
            log_success "CatalogSource created successfully"
        else
            log_error "Failed to create CatalogSource"
            exit 1
        fi
    fi
}

# Step 7: Check CatalogSource status
check_catalog_source_ready() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "Step 7: [DRY-RUN] Would wait for CatalogSource to be ready..."
        show_command "oc get catalogsource \"$CATALOG_NAME\" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}'"
        show_command "oc get catalogsource \"$CATALOG_NAME\" -n openshift-marketplace -o yaml"
        log_info "[DRY-RUN] Would wait for CatalogSource to become READY"
        return 0
    fi
    
    log_info "Step 7: Waiting for CatalogSource to be ready..."
    
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        local status=$(oc get catalogsource "$CATALOG_NAME" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        
        if [[ "$status" == "READY" ]]; then
            log_success "CatalogSource is ready"
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts: CatalogSource status is '$status', waiting..."
        sleep 10
        ((attempt++))
    done
    
    log_error "CatalogSource failed to become ready within timeout"
    oc get catalogsource "$CATALOG_NAME" -n openshift-marketplace -o yaml || true
    exit 1
}

# Step 8: Create operator namespace
create_operator_namespace() {
    log_info "Step 8: Creating operator namespace..."
    
    local namespace_yaml="/tmp/${OPERATOR}_namespace.yaml"
    
    cat > "$namespace_yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    openshift.io/sa.scc.mcs: s0:c27,c24
    openshift.io/sa.scc.supplemental-groups: 1000750000/10000
    openshift.io/sa.scc.uid-range: 1000750000/10000
    security.openshift.io/MinimallySufficientPodSecurityStandard: privileged
    workload.openshift.io/allowed: management
  labels:
    kubernetes.io/metadata.name: $OPERATOR_NAMESPACE
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: privileged
    pod-security.kubernetes.io/warn-version: latest
    security.openshift.io/scc.podSecurityLabelSync: "true"
  name: $OPERATOR_NAMESPACE
spec:
  finalizers:
  - kubernetes
EOF

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_yaml "$namespace_yaml" "Namespace that would be applied"
        show_command "oc apply -f \"$namespace_yaml\""
        log_info "[DRY-RUN] Would create namespace: $OPERATOR_NAMESPACE"
    else
        if oc apply -f "$namespace_yaml"; then
            log_success "Operator namespace created successfully"
        else
            log_error "Failed to create operator namespace"
            exit 1
        fi
    fi
}

# Step 9: Create OperatorGroup
create_operator_group() {
    log_info "Step 9: Creating OperatorGroup..."
    
    local operator_group_yaml="/tmp/${OPERATOR}_operator_group.yaml"
    local install_mode_file="/tmp/${OPERATOR}_install_mode.txt"
    local install_mode=$(cat "$install_mode_file" 2>/dev/null || echo "SingleNamespace")
    
    log_info "Using install mode: $install_mode"
    
    if [[ "$install_mode" == "AllNamespaces" ]]; then
        # Create OperatorGroup for AllNamespaces mode (watches all namespaces)
        cat > "$operator_group_yaml" <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec: {}
EOF
    else
        # Create OperatorGroup for SingleNamespace/MultiNamespace/OwnNamespace modes
        # (watches specific namespaces - defaults to operator's own namespace)
        cat > "$operator_group_yaml" <<EOF
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

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_yaml "$operator_group_yaml" "OperatorGroup that would be applied"
        show_command "oc apply -f \"$operator_group_yaml\""
        log_info "[DRY-RUN] Would create OperatorGroup: operator-group-${OPERATOR_NAME}"
    else
        if oc apply -f "$operator_group_yaml"; then
            log_success "OperatorGroup created successfully"
        else
            log_error "Failed to create OperatorGroup"
            exit 1
        fi
    fi
}

# Step 10: Create Subscription
create_subscription() {
    log_info "Step 10: Creating Subscription..."
    
    local subscription_yaml="/tmp/${OPERATOR}_subscription.yaml"
    local channel_file="/tmp/${OPERATOR}_default_channel.txt"
    local operator_channel="stable"  # fallback default
    
    # Read the extracted channel from file
    if [[ -f "$channel_file" ]]; then
        operator_channel=$(cat "$channel_file" 2>/dev/null || echo "stable")
        if [[ -z "$operator_channel" ]]; then
            operator_channel="stable"
        fi
    fi
    
    log_info "Using operator channel: $operator_channel"
    
    cat > "$subscription_yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/${OPERATOR_NAME}.${OPERATOR_NAMESPACE}: ""
  name: ${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: $operator_channel
  installPlanApproval: Automatic
  name: ${OPERATOR_NAME}
  source: $CATALOG_NAME
  sourceNamespace: openshift-marketplace
EOF

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_yaml "$subscription_yaml" "Subscription that would be applied"
        show_command "oc apply -f \"$subscription_yaml\""
        log_info "[DRY-RUN] Would create Subscription: ${OPERATOR_NAME}"
    else
        if oc apply -f "$subscription_yaml"; then
            log_success "Subscription created successfully"
        else
            log_error "Failed to create Subscription"
            exit 1
        fi
    fi
}

# Step 11: Wait for CSV creation
# Function to monitor subscription health and handle common issues
monitor_subscription_health() {
    local subscription_name="$1"
    local namespace="$2"
    local timeout_seconds="${3:-120}"
    local deadline=$((SECONDS + timeout_seconds))
    
    log_info "Monitoring subscription health for ${subscription_name} in namespace ${namespace}..."
    
    while [ ${SECONDS} -lt ${deadline} ]; do
        # Get subscription status
        local sub_status=$(oc get subscription "${subscription_name}" -n "${namespace}" -o jsonpath='{.status}' 2>/dev/null || echo '{}')
        
        # Check for ResolutionFailed condition
        local resolution_failed=$(echo "${sub_status}" | jq -r '.conditions[]? | select(.type=="ResolutionFailed") | .status' 2>/dev/null || echo "")
        local resolution_message=$(echo "${sub_status}" | jq -r '.conditions[]? | select(.type=="ResolutionFailed") | .message' 2>/dev/null || echo "")
        
        # Check for CatalogSourcesUnhealthy condition
        local catalog_unhealthy=$(echo "${sub_status}" | jq -r '.conditions[]? | select(.type=="CatalogSourcesUnhealthy") | .status' 2>/dev/null || echo "")
        
        # Check if subscription has currentCSV (indicates successful resolution)
        local current_csv=$(echo "${sub_status}" | jq -r '.currentCSV // empty' 2>/dev/null)
        
        if [ "${resolution_failed}" = "True" ]; then
            log_warning "Subscription resolution failed: ${resolution_message}"
            
            # Try to identify and fix problematic catalog sources
            log_info "Attempting to identify and remove problematic catalog sources..."
            
            # Extract problematic catalog source names from error message
            local problematic_catalogs=$(echo "${resolution_message}" | grep -oE "openshift-marketplace/[a-zA-Z0-9-]+" | sed 's|openshift-marketplace/||g' | sort -u)
            
            if [ -n "${problematic_catalogs}" ]; then
                log_info "Found problematic catalog sources: ${problematic_catalogs}"
                
                for catalog in ${problematic_catalogs}; do
                    # Skip our own catalog source
                    if [ "${catalog}" != "${CATALOG_NAME}" ]; then
                        log_info "Checking catalog source: ${catalog}"
                        
                        # Check if catalog source pods are failing
                        local catalog_pod_status=$(oc get pods -n openshift-marketplace -l "olm.catalogSource=${catalog}" -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
                        
                        if [[ "${catalog_pod_status}" == *"Failed"* ]] || [[ "${catalog_pod_status}" == *"Pending"* ]] || [ -z "${catalog_pod_status}" ]; then
                            log_warning "Catalog source ${catalog} appears problematic (pod status: ${catalog_pod_status:-"not found"})"
                            log_info "Removing problematic catalog source: ${catalog}"
                            
                            if oc delete catalogsource "${catalog}" -n openshift-marketplace --timeout=30s 2>/dev/null; then
                                log_success "Successfully removed catalog source: ${catalog}"
                            else
                                log_warning "Failed to remove catalog source: ${catalog}"
                            fi
                        fi
                    fi
                done
                
                log_info "Waiting 10 seconds for OLM to refresh after catalog source changes..."
                sleep 10
                continue # Restart the monitoring loop
            fi
        fi
        
        if [ "${catalog_unhealthy}" = "True" ]; then
            log_warning "Some catalog sources are unhealthy, but continuing to monitor..."
        fi
        
        if [ -n "${current_csv}" ]; then
            log_success "Subscription successfully resolved. Current CSV: ${current_csv}"
            return 0
        fi
        
        # Check if bundle is unpacking
        local bundle_unpacking=$(echo "${sub_status}" | jq -r '.conditions[]? | select(.type=="BundleUnpacking") | .status' 2>/dev/null || echo "")
        if [ "${bundle_unpacking}" = "True" ]; then
            log_info "Bundle unpacking in progress..."
        fi
        
        log_info "Subscription not yet resolved, checking again in 5 seconds..."
        sleep 5
    done
    
    log_error "Subscription monitoring timed out after ${timeout_seconds} seconds"
    log_info "Subscription status:"
    oc get subscription "${subscription_name}" -n "${namespace}" -o yaml | grep -A 20 "status:" || true
    return 1
}

wait_for_csv() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "Step 11: [DRY-RUN] Would wait for CSV installation..."
        show_command "oc wait --for=jsonpath='{.status.phase}'=Succeeded csv --all -n \"$OPERATOR_NAMESPACE\" --timeout=180s"
        return 0
    fi
    
    log_info "Step 11: Waiting for CSV installation..."
    
    # Monitor subscription health and wait for CSV
    if ! monitor_subscription_health "${OPERATOR_NAME}" "$OPERATOR_NAMESPACE" 180; then
        log_error "Subscription failed to become healthy"
        exit 1
    fi

    # Wait for CSV to reach Succeeded state
    if oc wait --for=jsonpath='{.status.phase}'=Succeeded csv --all -n "$OPERATOR_NAMESPACE" --timeout=180s; then
        log_success "CSV installation completed successfully"
    else
        log_warning "CSV did not reach Succeeded state in time"
    fi
}

# Cleanup function
cleanup() {
    rm -f /tmp/fbc_image_url /tmp/opm_render_output.json
    rm -f /tmp/${OPERATOR:-*}_related_images.txt /tmp/${OPERATOR:-*}_repositories.txt /tmp/${OPERATOR:-*}_default_channel.txt /tmp/${OPERATOR:-*}_install_mode.txt /tmp/${OPERATOR:-*}_image_mappings.txt
    rm -f /tmp/${OPERATOR:-*}_catalog_source.yaml /tmp/${OPERATOR:-*}_namespace.yaml /tmp/${OPERATOR:-*}_operator_group.yaml /tmp/${OPERATOR:-*}_subscription.yaml /tmp/${OPERATOR:-*}_idms.yaml
}

# Main execution
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Set operator-specific configuration
    set_operator_config
    
    
    log_info "Starting ${OPERATOR} operator installation for OpenShift ${VERSION}"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "DRY-RUN MODE - No resources will be created"
        set +e
    fi
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Execute steps
    check_prerequisites
    cleanup_existing_resources
    mirror_fbc_image
    extract_operator_metadata
    mirror_related_images
    create_image_digest_mirror_set
    wait_for_mcp_update
    apply_catalog_source
    check_catalog_source_ready
    create_operator_namespace
    create_operator_group
    create_subscription
    wait_for_csv
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_success "Dry-run completed successfully"
        log_info "To execute: remove --dry-run flag and re-run"
    else
        # Final verification and status reporting
        log_info "Final verification and status reporting..."
        echo
        log_info "Current CSV status:"
        oc get csv -n "$OPERATOR_NAMESPACE" 2>/dev/null || echo "No CSVs found in $OPERATOR_NAMESPACE"
        echo
        
        log_info "Current operator pods:"
        oc get pods -n "$OPERATOR_NAMESPACE" 2>/dev/null || echo "No pods found in $OPERATOR_NAMESPACE"
        echo
        
        log_info "Subscription status:"
        oc get subscription -n "$OPERATOR_NAMESPACE" -o custom-columns="NAME:.metadata.name,PACKAGE:.spec.name,SOURCE:.spec.source,CHANNEL:.spec.channel,CURRENT_CSV:.status.currentCSV,STATE:.status.state" 2>/dev/null || echo "Subscription status unavailable"
        echo
        
        # Check if operator pods are running
        local operator_pods_ready=$(oc get pods -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -o "true" | wc -l || echo "0")
        local total_operator_pods=$(oc get pods -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
        
        if [ "${total_operator_pods}" -gt 0 ] && [ "${operator_pods_ready}" -eq "${total_operator_pods}" ]; then
            log_success "${OPERATOR} operator installation completed successfully!"
            log_success "All ${total_operator_pods} operator pods are running and ready"
        else
            log_warning "${OPERATOR} operator installation may have issues:"
            log_info "   - Total pods: ${total_operator_pods}"
            log_info "   - Ready pods: ${operator_pods_ready}"
            log_info "   Please check pod status and logs for issues."
        fi
        
        echo
        log_info "Verification commands:"
        echo "   Check operator status: oc get pods -n $OPERATOR_NAMESPACE"
        echo "   Check CSV status: oc get csv -n $OPERATOR_NAMESPACE"  
        echo "   Check subscription: oc get subscription -n $OPERATOR_NAMESPACE"
        echo "   Check operator logs: oc logs -n $OPERATOR_NAMESPACE -l app.kubernetes.io/name=${OPERATOR}-operator --tail=50"
        echo
        log_success "${OPERATOR} operator installation script finished."
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
