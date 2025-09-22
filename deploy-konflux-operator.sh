#!/bin/bash

# Konflux Operator Installation Script for Disconnected OpenShift Cluster
# This script automates the complete installation process for telco operators:
# sriov, metallb, nmstate, ptp

set -euo pipefail
set -x

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
    KUBECONFIG="/home/kni/clusterconfigs/auth/kubeconfig"
}

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Dry-run helpers
show_command() {
    echo -e "${YELLOW}[DRY-RUN COMMAND]${NC} $1"
}

show_yaml() {
    local yaml_file="$1"
    local description="$2"
    echo -e "${BLUE}[DRY-RUN YAML]${NC} $description"
    echo "------- File: $yaml_file -------"
    if [[ -f "$yaml_file" ]]; then
        cat "$yaml_file"
    else
        echo "File not found: $yaml_file"
    fi
    echo "------- End of File -------"
    echo
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if required files exist
    if [[ ! -f "$AUTHFILE" ]]; then
        log_error "Auth file not found: $AUTHFILE"
        exit 1
    fi
    
    if [[ ! -f "$KUBECONFIG" ]]; then
        log_error "Kubeconfig not found: $KUBECONFIG"
        exit 1
    fi
    
    # Check required commands
    local required_commands=("oc" "opm" "jq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
    
    # Export kubeconfig
    export KUBECONFIG="$KUBECONFIG"
    
    # Test cluster connectivity
    if ! oc cluster-info &> /dev/null; then
        log_error "Cannot connect to OpenShift cluster"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

cleanup_existing_resources() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "Step 0: [DRY-RUN] Would clean up existing resources..."
        show_command "oc delete namespace \"$OPERATOR_NAMESPACE\" --ignore-not-found"
        show_command "oc delete catalogsource \"$CATALOG_NAME\" -n openshift-marketplace --ignore-not-found"
        log_info "[DRY-RUN] Would ensure clean installation by removing existing operator resources"
        return 0
    fi
    
    log_info "Step 0: Cleaning up existing resources for clean installation..."
    
    # Delete existing operator namespace
    log_info "Removing existing operator namespace: $OPERATOR_NAMESPACE"
    if oc get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        log_info "Found existing namespace $OPERATOR_NAMESPACE, deleting..."
        oc delete namespace "$OPERATOR_NAMESPACE" --ignore-not-found
        
        # Wait for namespace deletion to complete
        log_info "Waiting for namespace deletion to complete..."
        local wait_count=0
        while oc get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1 && [[ $wait_count -lt 30 ]]; do
            sleep 2
            ((++wait_count))
        done
        
        if [[ $wait_count -eq 30 ]]; then
            log_warning "Namespace deletion is taking longer than expected, continuing anyway..."
        else
            log_success "Namespace $OPERATOR_NAMESPACE deleted successfully"
        fi
    else
        log_info "Namespace $OPERATOR_NAMESPACE does not exist, skipping..."
    fi
    
    # Delete existing catalog source
    log_info "Removing existing catalog source: $CATALOG_NAME"
    if oc get catalogsource "$CATALOG_NAME" -n openshift-marketplace >/dev/null 2>&1; then
        log_info "Found existing catalog source $CATALOG_NAME, deleting..."
        oc delete catalogsource "$CATALOG_NAME" -n openshift-marketplace --ignore-not-found
        log_success "Catalog source $CATALOG_NAME deleted successfully"
    else
        log_info "Catalog source $CATALOG_NAME does not exist, skipping..."
    fi
    
    # Wait a moment for resources to be fully cleaned up
    sleep 2
    log_success "Resource cleanup completed"
}

# Step 1: Mirror FBC image to local registry
mirror_fbc_image() {
    log_info "Step 1: Mirroring FBC image to local registry..."
    
    local fbc_target_image="${LOCAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
    
    log_info "Source: $FBC_SOURCE_IMAGE"
    log_info "Target: $fbc_target_image"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_command "oc image mirror -a=\"$QUAY_AUTH\" --keep-manifest-list=true \"$FBC_SOURCE_IMAGE\" \"$fbc_target_image\""
        log_info "[DRY-RUN] Would mirror FBC image to: $fbc_target_image"
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

# Step 2: Extract related images digests and install modes using opm render
extract_related_images() {
    log_info "Step 2: Extracting related images using opm render..."
    
    local temp_render_output="/tmp/opm_render_output.json"
    local channel_file="/tmp/${OPERATOR}_default_channel.txt"
    local install_mode_file="/tmp/${OPERATOR}_install_mode.txt"
    
    # Use opm render to get the catalog content with quay auth (run even in dry-run to get real data)
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_command "REGISTRY_AUTH_FILE=\"$QUAY_AUTH\" opm render \"$FBC_SOURCE_IMAGE\" > \"$temp_render_output\""
        log_info "[DRY-RUN] Extracting catalog content from FBC image to populate YAMLs with real data..."
    fi
    
    if REGISTRY_AUTH_FILE="$QUAY_AUTH" opm render "$FBC_SOURCE_IMAGE" > "$temp_render_output"; then
        log_success "OPM render completed successfully"
    else
        log_error "Failed to render FBC image with opm"
        exit 1
    fi
    
    # Extract relatedImages, repositories, and metadata
    log_info "Extracting related images and repositories from relatedImages..."
    
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
    
    log_success "Extracted $images_count related images and $repos_count unique repositories"
    
    if [[ $images_count -eq 0 ]]; then
        log_error "No related images found"
        exit 1
    fi
    
    if [[ -n "$default_channel" ]]; then
        log_success "Extracted default channel: $default_channel"
    else
        log_warning "Could not extract defaultChannel, using fallback: stable"
        echo "stable" > "$channel_file"
    fi
    
    log_success "Extracted install mode: $install_mode"
    
    # Display first few images and repositories for verification
    log_info "Sample related images:"
    head -3 "$related_images_file" | while read -r image; do
        echo "  $image"
    done
    
    log_info "Sample repositories for IDMS:"
    head -3 "$repositories_file" | while read -r repo; do
        echo "  $repo"
    done
}

# Step 3: Mirror related images to local registry
mirror_related_images() {
    log_info "Step 3: Mirroring related images to local registry..."
    
    local related_images_file="/tmp/${OPERATOR}_related_images.txt"
    local mapping_file="/tmp/${OPERATOR}_image_mappings.txt"
    
    # Clear mapping file
    > "$mapping_file"
    
    # Mirror each related image to local registry
    local success_count=0
    local total_count=$(wc -l < "$related_images_file")
    
    local image_counter=0
    
    while IFS= read -r image || [[ -n "$image" ]]; do
        ((++image_counter))
        [[ -z "$image" ]] && continue
        
        # Extract digest from the image
        local digest=$(echo "$image" | grep -o 'sha256:[a-f0-9]\{64\}' || echo "")
        
        if [[ -z "$digest" ]]; then
            log_warning "Skipping image without digest: $image"
            continue
        fi
        
        local source_image="${ART_IMAGES_SOURCE}@${digest}"
        local target_image="${LOCAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
        echo "${source_image}=${target_image}" >> "$mapping_file"
        
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            show_command "oc image mirror -a=\"$QUAY_AUTH\" --keep-manifest-list=true \"$source_image\" \"$target_image\""
            ((++success_count))
        else
            log_info "Mirroring: $source_image"
            if oc image mirror \
                -a="$QUAY_AUTH" \
                --keep-manifest-list=true \
                "$source_image" "$target_image" </dev/null 2>/dev/null;
            then
                ((++success_count))
            else
                log_error "Failed to mirror: $source_image"
                log_error "Image mirroring failed. Exiting..."
                exit 1
            fi
        fi
    done < "$related_images_file"
    
    log_success "Successfully mirrored $success_count/$total_count images"
    log_info "Created mapping file with $(wc -l < "$mapping_file") image mappings"
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
        show_command "oc get imagedigestmirrorset \"${OPERATOR}-quay-idms\""
        log_info "[DRY-RUN] Would create ImageDigestMirrorSet: ${OPERATOR}-quay-idms"
    else
        log_info "Applying ImageDigestMirrorSet..."
        if oc apply -f "$idms_yaml"; then
            log_success "ImageDigestMirrorSet created successfully"
            
            # Wait a moment for the IDMS to be processed
            log_info "Waiting for ImageDigestMirrorSet to be processed..."
            sleep 5
            
            # Check IDMS status
            if oc get imagedigestmirrorset "${OPERATOR}-quay-idms" &> /dev/null; then
                log_success "ImageDigestMirrorSet is active"
            else
                log_warning "ImageDigestMirrorSet may not be fully processed yet"
            fi
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
        show_command "oc get mcp"
        show_command "oc get mcp -o jsonpath='{.items[*].status.conditions[?(@.type==\"Updating\")].status}'"
        log_info "[DRY-RUN] Would wait for cluster nodes to start updating after IDMS application"
        log_info "[DRY-RUN] Would wait up to 5 minutes for MCP Updating status to become 'True'"
        log_info "[DRY-RUN] Would then wait for MCP Updating status to become 'False'"
        log_info "[DRY-RUN] Would wait an additional 10 minutes for cluster to stabilize"
        return 0
    fi
    
    log_info "Step 5: Waiting for MachineConfigPool updates after IDMS..."
    
    # First, wait for at least one MCP to start updating
    log_info "Waiting for cluster to start updating (MCP Updating=True)..."
    local max_wait_for_start=60  # 1 minute
    local wait_time=0
    local updating_started=false
    
    while [[ $wait_time -lt $max_wait_for_start ]]; do
        # Check if any MCP is updating
        local updating_status=$(oc get mcp -o jsonpath='{.items[*].status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "")
        
        if [[ "$updating_status" == *"True"* ]]; then
            log_success "Cluster has started updating (MCP Updating=True detected)"
            updating_started=true
            break
        fi
        
        log_info "Waiting for MCP updates to start... (${wait_time}s/${max_wait_for_start}s)"
        oc get mcp --no-headers 2>/dev/null || log_warning "Unable to get MCP status"
        sleep 15
        ((wait_time+=15))
    done
    
    if [[ "$updating_started" == "false" ]]; then
        log_warning "MCP updates did not start within ${max_wait_for_start} seconds"
        log_info "Current MCP status:"
        oc get mcp || true
        log_info "Proceeding anyway - IDMS may not require node updates"
        return 0
    fi
    
    # Now wait for all MCPs to finish updating
    log_info "Waiting for all MachineConfigPools to finish updating (MCP Updating=False)..."
    local max_wait_for_complete=600  # 10 minutes
    wait_time=0
    
    while [[ $wait_time -lt $max_wait_for_complete ]]; do
        local all_updated=true
        local mcp_status=""
        
        # Get status of all MCPs
        if mcp_status=$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Updating")].status},{end}' 2>/dev/null); then
            log_info "MCP Update Status: $mcp_status"
            
            # Check if any MCP is still updating
            if [[ "$mcp_status" == *"True"* ]]; then
                all_updated=false
            fi
        else
            log_warning "Unable to get MCP status, retrying..."
            all_updated=false
        fi
        
        if [[ "$all_updated" == "true" ]]; then
            log_success "All MachineConfigPools have finished updating"
            break
        fi
        
        log_info "MCPs still updating... waiting (${wait_time}s/${max_wait_for_complete}s)"
        sleep 30
        ((wait_time+=30))
    done
    
    if [[ $wait_time -ge $max_wait_for_complete ]]; then
        log_warning "MCP updates did not complete within ${max_wait_for_complete} seconds"
        log_info "Current MCP status:"
        oc get mcp || true
        log_info "Proceeding anyway - continuing with operator installation"
        return 0
    fi
    
    log_success "MachineConfigPool updates completed and cluster stabilized"
    
    # Final status check
    log_info "Final MCP status:"
    oc get mcp || true
}

# Step 6: Apply CatalogSource YAML
apply_catalog_source() {
    log_info "Step 6: Creating CatalogSource..."
    
    local fbc_image_url=$(cat /tmp/fbc_image_url)
    local catalog_yaml="/tmp/${OPERATOR}_catalog_source.yaml"
    
    cat > "$catalog_yaml" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_NAME
  namespace: openshift-marketplace
spec:
  displayName: ${OPERATOR^} Konflux Catalog
  image: $fbc_image_url
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        show_yaml "$catalog_yaml" "CatalogSource that would be applied"
        show_command "oc apply -f \"$catalog_yaml\""
        log_info "[DRY-RUN] Would create CatalogSource: $CATALOG_NAME"
    else
        log_info "Applying CatalogSource YAML..."
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
        log_info "Step 11: [DRY-RUN] Would monitor subscription health..."
        show_command "monitor_subscription_health \"${OPERATOR_NAME}\" \"$OPERATOR_NAMESPACE\" 180"
        log_info "Step 12: [DRY-RUN] Would wait for CSV resource creation..."
        show_command "oc get subscription \"${OPERATOR_NAME}\" -n \"$OPERATOR_NAMESPACE\" -o jsonpath='{.status.currentCSV}'"
        show_command "oc wait --for=jsonpath='{.status.phase}'=Succeeded \"csv/\$CURRENT_CSV\" -n \"$OPERATOR_NAMESPACE\" --timeout=180s"
        show_command "oc get csv -n \"$OPERATOR_NAMESPACE\""
        show_command "oc get pods -n \"$OPERATOR_NAMESPACE\""
        log_info "[DRY-RUN] Would wait for ${OPERATOR^} operator CSV to reach Succeeded phase"
        return 0
    fi
    
    # Step 11: Monitor subscription health before proceeding to CSV
    log_info "Step 11: Monitoring subscription health and resolving any issues..."
    if ! monitor_subscription_health "${OPERATOR_NAME}" "$OPERATOR_NAMESPACE" 180; then
        log_error "Subscription failed to become healthy. Checking current state for diagnostics..."
        log_info "Subscription details:"
        oc get subscription "${OPERATOR_NAME}" -n "$OPERATOR_NAMESPACE" -o yaml
        log_info "Catalog sources:"
        oc get catalogsource -n openshift-marketplace
        log_info "Package manifests:"
        oc get packagemanifest -n openshift-marketplace | grep "${OPERATOR}" || true
        exit 1
    fi

    # Step 12: Wait for CSV creation and success
    log_info "Step 12: Waiting for operator CSV to be installed and running..."

    # Get the current CSV from the subscription (it should be set now)
    local current_csv=$(oc get subscription "${OPERATOR_NAME}" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")

    if [ -n "${current_csv}" ]; then
        log_info "Subscription resolved to CSV: ${current_csv}"
        log_info "Waiting for CSV ${current_csv} to reach Succeeded state..."
        
        if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${current_csv}" -n "$OPERATOR_NAMESPACE" --timeout=180s; then
            log_warning "CSV ${current_csv} did not reach 'Succeeded' phase in time."
            log_info "CSV status:"
            oc get csv "${current_csv}" -n "$OPERATOR_NAMESPACE" -o yaml | grep -A 30 "status:" || true
            log_info "Checking for installation issues..."
        else
            log_success "CSV ${current_csv} successfully reached Succeeded state!"
        fi
    else
        log_warning "No currentCSV found in subscription. Falling back to detecting any new CSV..."
        
        # Fallback: Wait for any CSV to reach Succeeded state
        log_info "Waiting for any CSV in namespace to reach Succeeded state..."
        if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded csv --all -n "$OPERATOR_NAMESPACE" --timeout=120s; then
            log_warning "No CSV reached 'Succeeded' phase in time. Check 'oc get csv -n $OPERATOR_NAMESPACE'."
        fi
    fi
    
    # Step 13: Final verification and status reporting
    log_info "Step 13: Final verification and status reporting..."
    echo
    log_info "Current CSV status:"
    oc get csv -n "$OPERATOR_NAMESPACE"
    echo
    
    log_info "Current operator pods:"
    oc get pods -n "$OPERATOR_NAMESPACE" 2>/dev/null || echo "No pods found in $OPERATOR_NAMESPACE"
    echo
    
    log_info "Subscription status:"
    oc get subscription "${OPERATOR_NAME}" -n "$OPERATOR_NAMESPACE" -o custom-columns="NAME:.metadata.name,PACKAGE:.spec.name,SOURCE:.spec.source,CHANNEL:.spec.channel,CURRENT_CSV:.status.currentCSV,STATE:.status.state" 2>/dev/null || echo "Subscription status unavailable"
    echo
    
    # Check if operator pods are running
    local operator_pods_ready=$(oc get pods -n "$OPERATOR_NAMESPACE" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -o "true" | wc -l || echo "0")
    local total_operator_pods=$(oc get pods -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "${total_operator_pods}" -gt 0 ] && [ "${operator_pods_ready}" -eq "${total_operator_pods}" ]; then
        log_success "${OPERATOR^} operator installation completed successfully!"
        log_success "All ${total_operator_pods} operator pods are running and ready"
    else
        log_warning "${OPERATOR^} operator installation may have issues:"
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
}

# Cleanup function
cleanup() {
    log_info "Cleaning up temporary files..."
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
    
    # Export kubeconfig
    export KUBECONFIG
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_warning "=== DRY-RUN MODE ENABLED ==="
        log_warning "No resources will be created on the cluster. Only showing what would be done."
        # Temporarily disable pipefail in dry-run mode to prevent early exit
        set +e
        echo
    fi
    
    log_info "Starting ${OPERATOR^} Operator installation for disconnected OpenShift cluster"
    log_info "Version: $VERSION"
    log_info "Operator: $OPERATOR"
    log_info "Local Registry: $LOCAL_REGISTRY"
    log_info "Kubeconfig: $KUBECONFIG"
    log_info "Auth file: $AUTHFILE"
    log_info "FBC Source Image: $FBC_SOURCE_IMAGE"
    log_info "Operator Namespace: $OPERATOR_NAMESPACE"
    log_info "Catalog Name: $CATALOG_NAME"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "Mode: DRY-RUN (no actual changes will be made)"
    fi
    echo
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Execute steps
    check_prerequisites
    cleanup_existing_resources
    mirror_fbc_image
    extract_related_images
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
        echo
        log_success "🎉 [DRY-RUN] ${OPERATOR^} Operator installation plan completed!"
        log_info "=== DRY-RUN SUMMARY ==="
        log_info "The following YAML files would be created and applied to the cluster:"
        echo "  1. ImageDigestMirrorSet: /tmp/${OPERATOR}_idms.yaml"
        echo "  2. CatalogSource:        /tmp/${OPERATOR}_catalog_source.yaml"
        echo "  3. Namespace:            /tmp/${OPERATOR}_namespace.yaml"
        echo "  4. OperatorGroup:        /tmp/${OPERATOR}_operator_group.yaml"
        echo "  5. Subscription:         /tmp/${OPERATOR}_subscription.yaml"
        echo
        log_info "Additional steps that would be executed:"
        echo "  - Wait for MachineConfigPool updates after IDMS (up to 35 minutes + 10 min stabilization)"
        echo "  - Monitor CatalogSource readiness"
        echo "  - Wait for CSV installation completion"
        log_info "All YAML contents were displayed above during the dry-run."
        log_info "To execute the actual installation, run the same command without --dry-run"
    else
        log_success "🎉 ${OPERATOR^} Operator installation completed successfully!"
        log_info "You can now use the ${OPERATOR} operator in your disconnected cluster."
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
