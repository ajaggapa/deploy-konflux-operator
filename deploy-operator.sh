#!/bin/bash

set -Eeuo pipefail

# Color codes for logging
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging functions
log_step() {
    echo ""
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}


log() {
    local level="$1"
    local msg="$2"
    case "$level" in
        "INFO")    echo -e "${CYAN}[INFO]${NC} $msg" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $msg" ;;
        "ERROR")   echo -e "${RED}[ERROR]${NC} $msg" >&2 ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${NC} $msg" ;;
        *)         echo "[$level] $msg" ;;
    esac
}

display_metadata() {
    echo ""
    echo "============================================================"
    echo -e "${YELLOW}              EXTRACTED OPERATOR METADATA FROM FBC${NC}"
    echo "============================================================"
    
    # Read all input into an array
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done
    
    # Find the empty line separator
    local separator_index=-1
    for i in "${!lines[@]}"; do
        if [[ -z "${lines[i]}" ]]; then
            separator_index=$i
            break
        fi
    done
    
    # Print basic metadata (before empty line)
    for ((i=0; i<separator_index; i++)); do
        if [[ -n "${lines[i]}" ]]; then
            echo -e "${YELLOW}${lines[i]}${NC}"
        fi
    done
    
    # Print related images with label but no extra separators
    echo -e "${YELLOW}Related Images:${NC}"
    for ((i=separator_index+1; i<${#lines[@]}; i++)); do
        if [[ -n "${lines[i]}" ]]; then
            echo -e "${YELLOW}${lines[i]}${NC}"
        fi
    done
    echo "============================================================"
}

# Parse arguments
log_step "INIT" "Starting Konflux Operator Deployment"
log "INFO" "Using MCP timeout: ${MCP_TIMEOUT:-600s}"

log "INFO" "Parsing command line arguments"

# Set default timeout
MCP_TIMEOUT="${MCP_TIMEOUT:-600s}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --operator) 
            OPERATOR="$2"
            log "INFO" "Operator specified: $2"
            shift 2 
            ;;
        --fbc-tag) 
            FBC_TAG_INPUT="$2"
            log "INFO" "FBC tag specified: $2"
            shift 2 
            ;;
        --internal-registry) 
            INTERNAL_REGISTRY="$2"
            log "INFO" "Internal registry specified: $2"
            shift 2 
            ;;
        --internal-registry-auth) 
            INTERNAL_REGISTRY_AUTH="$2"
            log "INFO" "Internal registry auth file specified: $2"
            shift 2 
            ;;
        --quay-auth) 
            QUAY_AUTH="$2"
            log "INFO" "Quay auth file specified: $2"
            shift 2 
            ;;
        --mcp-timeout) 
            MCP_TIMEOUT="$2"
            log "INFO" "MCP timeout set to: $2"
            shift 2 
            ;;
        *) 
            log "ERROR" "Unknown argument: $1"
            exit 1 
            ;;
    esac
done

log "INFO" "Validating operator configuration"

if [[ -n "${OPERATOR:-}" && -n "${FBC_TAG_INPUT:-}" ]]; then
    log "ERROR" "Provide either --operator or --fbc-tag, not both"
    exit 1
fi

if [[ -z "${OPERATOR:-}" && -z "${FBC_TAG_INPUT:-}" ]]; then
    log "ERROR" "Provide either --operator or --fbc-tag"
    exit 1
fi

# Parse comma-separated operators if provided
if [[ -n "${OPERATOR:-}" ]]; then
    IFS=',' read -ra OPERATORS <<< "$OPERATOR"
    log "INFO" "Parsing operators: ${OPERATORS[*]}"
    
    # Validate all operators are in predefined list
    VALID_OPERATORS="sriov metallb nmstate ptp pfstatus"
    for op in "${OPERATORS[@]}"; do
        if [[ ! " $VALID_OPERATORS " =~ " $op " ]]; then
            log "ERROR" "Invalid operator: $op"
            log "ERROR" "Valid operators: $VALID_OPERATORS"
            exit 1
        fi
    done
    log "SUCCESS" "Operators to deploy: ${OPERATORS[*]}"
else
    OPERATORS=()
    log "INFO" "No operators specified, will use FBC tag mode"
fi

log_step "CONFIG" "Determining cluster mode and validating requirements"

# Check if quay-auth is required for disconnected clusters
if [[ -n "${INTERNAL_REGISTRY:-}" && -z "${QUAY_AUTH:-}" ]]; then
    log "ERROR" "--quay-auth is required for disconnected clusters"
    exit 1
fi

if [[ -n "${INTERNAL_REGISTRY:-}" && -z "${INTERNAL_REGISTRY_AUTH:-}" ]] || [[ -z "${INTERNAL_REGISTRY:-}" && -n "${INTERNAL_REGISTRY_AUTH:-}" ]]; then
    log "ERROR" "Both --internal-registry and --internal-registry-auth must be provided together"
    exit 1
fi

if [[ -n "${INTERNAL_REGISTRY:-}" ]]; then
    DISCONNECTED=true
    log "INFO" "Operating in disconnected cluster mode"
else
    DISCONNECTED=false
    log "INFO" "Operating in connected cluster mode"
fi

log "INFO" "Checking required tools"

# Check core tools (always required)
for cmd in oc opm jq; do
    log "INFO" "Checking for $cmd..."
    command -v "$cmd" >/dev/null 2>&1 || { log "ERROR" "$cmd not installed"; exit 1; }
done

# Check podman (required for disconnected clusters or when quay-auth is provided)
if [[ "$DISCONNECTED" == true ]] || [[ -n "${QUAY_AUTH:-}" ]]; then
    log "INFO" "Checking for podman (required for registry authentication)..."
    command -v "podman" >/dev/null 2>&1 || { log "ERROR" "podman not installed (required for registry authentication)"; exit 1; }
    log "SUCCESS" "podman is available"
else
    log "INFO" "Skipping podman check (not needed for connected clusters without quay-auth)"
fi

log "SUCCESS" "All required tools are available"

log "INFO" "Validating authentication files"

# Only validate quay auth file if provided
if [[ -n "${QUAY_AUTH:-}" ]]; then
    log "INFO" "Validating quay auth file: $QUAY_AUTH"
    [[ ! -f "$QUAY_AUTH" ]] && { log "ERROR" "Quay auth file not found"; exit 1; }
    jq empty "$QUAY_AUTH" 2>/dev/null || { log "ERROR" "Invalid JSON in quay auth"; exit 1; }
    log "SUCCESS" "Quay auth file is valid"
else
    log "INFO" "No quay auth file provided"
fi

if [[ "$DISCONNECTED" == true ]]; then
    log "INFO" "Validating internal registry auth file: $INTERNAL_REGISTRY_AUTH"
    [[ ! -f "$INTERNAL_REGISTRY_AUTH" ]] && { log "ERROR" "Internal registry auth file not found"; exit 1; }
    jq empty "$INTERNAL_REGISTRY_AUTH" 2>/dev/null || { log "ERROR" "Invalid JSON in internal auth"; exit 1; }
    log "SUCCESS" "Internal registry auth file is valid"
fi

log "INFO" "Checking cluster connectivity"
log "INFO" "Attempting to connect to OpenShift cluster..."
oc cluster-info &> /dev/null || { log "ERROR" "Cannot connect to cluster"; exit 1; }
log "SUCCESS" "Successfully connected to cluster"

# Detect cluster version
log "INFO" "Detecting OpenShift version..."
VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1-2)
[[ -z "$VERSION" ]] && { log "ERROR" "Could not detect cluster version"; exit 1; }
log "SUCCESS" "Detected OpenShift version: $VERSION"

# Helper function to get FBC tag for operator
get_fbc_tag() {
    local op=$1
    local ver=$2
    case "$op" in
        sriov) echo "ocp__${ver}__ose-sriov-network-rhel9-operator" ;;
        metallb) echo "ocp__${ver}__metallb-rhel9-operator" ;;
        nmstate) echo "ocp__${ver}__kubernetes-nmstate-rhel9-operator" ;;
        ptp) echo "ocp__${ver}__ose-ptp-rhel9-operator" ;;
        pfstatus) echo "ocp__${ver}__pf-status-relay-rhel9-operator" ;;
        *) echo "" ;;
    esac
}

# Set operator config
ART_IMAGES_SOURCE="quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share"

# Arrays to store operator metadata
declare -A OPERATOR_FBC_TAGS
declare -A OPERATOR_CATALOG_NAMES
declare -A OPERATOR_FBC_SOURCES
declare -A OPERATOR_FBC_TARGETS
declare -A OPERATOR_NAMES
declare -A OPERATOR_BUNDLES
declare -A OPERATOR_NAMESPACES
declare -A OPERATOR_CHANNELS
declare -A OPERATOR_INSTALL_MODES

if [[ ${#OPERATORS[@]} -gt 0 ]]; then
    # Multiple operators mode
    for op in "${OPERATORS[@]}"; do
        fbc_tag=$(get_fbc_tag "$op" "$VERSION")
        OPERATOR_FBC_TAGS[$op]="$fbc_tag"
        OPERATOR_CATALOG_NAMES[$op]="${op}-konflux"
        OPERATOR_FBC_SOURCES[$op]="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:${fbc_tag}"
        if [[ "$DISCONNECTED" == true ]]; then
            OPERATOR_FBC_TARGETS[$op]="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${fbc_tag}"
        else
            OPERATOR_FBC_TARGETS[$op]="${OPERATOR_FBC_SOURCES[$op]}"
        fi
    done
else
    # Single FBC tag mode
    FBC_TAG="${FBC_TAG_INPUT}"
    CATALOG_NAME=$(echo "$FBC_TAG" | sed 's/ocp__[^_]*__//' | sed 's/-rhel9-operator$//' | sed 's/-operator$//')-konflux
    FBC_SOURCE_IMAGE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
fi

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
    if [[ -n "${QUAY_AUTH:-}" ]]; then
        log "INFO" "Updating cluster pull-secret with quay.io credentials"
        
        log "INFO" "Retrieving current cluster pull-secret..."
        current_pull_secret=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
        log "SUCCESS" "Retrieved current pull-secret"
        
        log "INFO" "Merging quay.io credentials into pull-secret..."
        quay_auth_content=$(cat "$QUAY_AUTH")
        
        # Create a temporary file for the merged auth
        merged_auth_file=$(mktemp)
        
        # Merge auth entries, only adding new ones that don't exist
        # Create temporary files for the JSON inputs
        current_auth_file=$(mktemp)
        quay_auth_file=$(mktemp)
        echo "$current_pull_secret" > "$current_auth_file"
        echo "$quay_auth_content" > "$quay_auth_file"
        
        # Debug: Check the content of the files
        log "INFO" "Debugging JSON inputs..."
        log "INFO" "Current pull-secret file size: $(wc -c < "$current_auth_file") bytes"
        log "INFO" "Quay auth file size: $(wc -c < "$quay_auth_file") bytes"
        
        # Validate JSON inputs before merging
        if ! jq empty "$current_auth_file" 2>/dev/null; then
            log "ERROR" "Current pull-secret is not valid JSON"
            log "ERROR" "First 200 chars of current pull-secret: $(head -c 200 "$current_auth_file")"
            rm -f "$current_auth_file" "$quay_auth_file" "$merged_auth_file"
            exit 1
        fi
        
        if ! jq empty "$quay_auth_file" 2>/dev/null; then
            log "ERROR" "Quay auth content is not valid JSON"
            log "ERROR" "First 200 chars of quay auth: $(head -c 200 "$quay_auth_file")"
            rm -f "$current_auth_file" "$quay_auth_file" "$merged_auth_file"
            exit 1
        fi
        
        # Check if both files have the expected structure
        if ! jq -e '.auths' "$current_auth_file" >/dev/null 2>&1; then
            log "ERROR" "Current pull-secret does not contain 'auths' field"
            log "ERROR" "Current pull-secret structure: $(jq keys "$current_auth_file" 2>/dev/null || echo 'Invalid JSON')"
            rm -f "$current_auth_file" "$quay_auth_file" "$merged_auth_file"
            exit 1
        fi
        
        if ! jq -e '.auths' "$quay_auth_file" >/dev/null 2>&1; then
            log "ERROR" "Quay auth does not contain 'auths' field"
            log "ERROR" "Quay auth structure: $(jq keys "$quay_auth_file" 2>/dev/null || echo 'Invalid JSON')"
            rm -f "$current_auth_file" "$quay_auth_file" "$merged_auth_file"
            exit 1
        fi
        
        log "INFO" "Both JSON files are valid and contain 'auths' fields"
        
        jq -s '
            .[0].auths as $current |
            .[1].auths as $new |
            {
                auths: ($current + $new)
            }
        ' "$current_auth_file" "$quay_auth_file" > "$merged_auth_file"
        
        # Cleanup temporary files
        rm -f "$current_auth_file" "$quay_auth_file"
        
        # Apply the merged auth
        log "INFO" "Comparing current and updated pull-secret..."
        if ! cmp -s <(echo "$current_pull_secret" | jq -S) "$merged_auth_file"; then
            log "INFO" "Updating cluster pull-secret with new quay.io credentials..."
            cat "$merged_auth_file" | oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin || \
                { log "ERROR" "Failed to update cluster pull-secret"; rm -f "$merged_auth_file"; exit 1; }
            log "SUCCESS" "Updated cluster pull-secret with quay.io credentials"
        else
            log "SUCCESS" "Pull-secret already contains all required quay.io credentials"
        fi
        
        # Cleanup
        rm -f "$merged_auth_file"
    fi
fi

# Mirror FBC images and extract metadata
log_step "METADATA" "Extracting operator metadata from FBC"

if [[ ${#OPERATORS[@]} -gt 0 ]]; then
    log "INFO" "Processing ${#OPERATORS[@]} operator(s)"
    
    # Temporary file to collect all related images across all operators
    ALL_IMAGES_FILE=$(mktemp)
    
    for op in "${OPERATORS[@]}"; do
        log "INFO" "Processing operator: $op"
        
        fbc_source="${OPERATOR_FBC_SOURCES[$op]}"
        fbc_target="${OPERATOR_FBC_TARGETS[$op]}"
        
        # Mirror FBC image if disconnected
        if [[ "$DISCONNECTED" == true ]]; then
            echo "Mirroring FBC image..."
            mirror_output=$(oc image mirror --keep-manifest-list=true "$fbc_source" "$fbc_target" 2>&1)
            mirror_status=$?
            if [[ $mirror_status -ne 0 ]]; then
                echo "ERROR: Failed to mirror FBC for $op" >&2
                echo "Source: $fbc_source" >&2
                echo "Target: $fbc_target" >&2
                echo "Error output:" >&2
                echo "$mirror_output" >&2
                exit 1
            fi
        fi
        
        # Extract metadata from FBC
        log "INFO" "Rendering FBC: $fbc_source"
        opm_output=$(opm render "$fbc_source") || { log "ERROR" "opm render failed for $op"; exit 1; }
        
        log "INFO" "Finding latest bundle version..."
        latest_bundle=$(echo "$opm_output" | jq -r 'select(.schema == "olm.bundle") | .name' | sort -V | tail -1)
        [[ -z "$latest_bundle" ]] && { log "ERROR" "No bundle found for $op"; exit 1; }
        
        log "INFO" "Extracting bundle data..."
        bundle_data=$(echo "$opm_output" | jq "select(.schema == \"olm.bundle\" and .name == \"$latest_bundle\")")
        
        log "INFO" "Extracting operator metadata..."
        operator_name=$(echo "$bundle_data" | jq -r '.package // empty' | head -1)
        [[ -z "$operator_name" ]] && { log "ERROR" "Could not extract operator name for $op"; exit 1; }
        
        operator_namespace=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.annotations["operatorframework.io/suggested-namespace"] // empty' | head -1)
        if [[ -z "$operator_namespace" ]]; then
            operator_namespace="openshift-${operator_name}"
            namespace_source="derived"
        else
            namespace_source="annotated"
        fi
        
        default_channel=$(echo "$opm_output" | jq -r 'select(.schema == "olm.package") | .defaultChannel // "stable"' | head -1)
        [[ -z "$default_channel" ]] && default_channel="stable"
        
        install_mode=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.installModes[]? | select(.supported == true) | .type' | head -1)
        [[ -z "$install_mode" ]] && install_mode="SingleNamespace"
        
        # Store metadata
        OPERATOR_NAMES[$op]="$operator_name"
        OPERATOR_BUNDLES[$op]="$latest_bundle"
        OPERATOR_NAMESPACES[$op]="$operator_namespace"
        OPERATOR_CHANNELS[$op]="$default_channel"
        OPERATOR_INSTALL_MODES[$op]="$install_mode"
        
        # Print metadata using display_metadata function
        {
            echo "Operator Name:    $operator_name"
            echo "Bundle Name:      $latest_bundle"
            echo "Namespace:        $operator_namespace ($namespace_source)"
            echo "Channel:          $default_channel"
            echo "Install Mode:     $install_mode"
            echo ""
            echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sort -u | nl -w2 -s'. '
        } | display_metadata
        
        # Collect related images to temp file
        echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' 2>/dev/null | grep -v '^$' >> "$ALL_IMAGES_FILE"
    done
    
    # Calculate total unique images
    total_images=$(sort -u "$ALL_IMAGES_FILE" | wc -l)
    
    echo ""
    echo "============================================================"
    echo "Total unique images across all operators: $total_images"
    echo "============================================================"
    
    # Mirror all related images if disconnected
    if [[ "$DISCONNECTED" == true ]]; then
        # Merge quay and internal auth files for oc image mirror (pull+push)
        MERGED_AUTH_FILE=$(mktemp)
        jq -s '{auths: (.[0].auths + .[1].auths)}' "$QUAY_AUTH" "$INTERNAL_REGISTRY_AUTH" > "$MERGED_AUTH_FILE" || \
            { echo "ERROR: Failed to merge auth files for image mirroring" >&2; rm -f "$MERGED_AUTH_FILE" "$ALL_IMAGES_FILE"; exit 1; }
        
        # Sort unique images to a new file (avoids pipefail issues with process substitution)
        SORTED_IMAGES_FILE=$(mktemp)
        sort -u "$ALL_IMAGES_FILE" > "$SORTED_IMAGES_FILE"
        rm -f "$ALL_IMAGES_FILE"
        
        echo "Mirroring related images..."
        image_count=0
        
        # Read directly from the sorted file
        set +e  # Temporarily disable exit on error for the loop
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            
            digest=$(echo "$image" | grep -o 'sha256:[a-f0-9]\{64\}')
            [[ -z "$digest" ]] && continue
            
            ((image_count++))
            echo "  [$image_count/$total_images] Mirroring $digest..."
            source="${ART_IMAGES_SOURCE}@${digest}"
            target="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
            
            mirror_output=$(oc image mirror --keep-manifest-list=true -a "$MERGED_AUTH_FILE" "$source" "$target" </dev/null 2>&1)
            mirror_status=$?
            if [[ $mirror_status -eq 0 ]]; then
                echo "    ✓ Success"
            else
                set -e  # Re-enable exit on error
                echo "ERROR: Failed to mirror $digest" >&2
                echo "Source: $source" >&2
                echo "Target: $target" >&2
                echo "Digest: $digest" >&2
                echo "Error output:" >&2
                echo "$mirror_output" >&2
                rm -f "$MERGED_AUTH_FILE" "$SORTED_IMAGES_FILE"
                exit 1
            fi
        done < "$SORTED_IMAGES_FILE"
        set -e  # Re-enable exit on error
        
        echo "Successfully mirrored all $image_count images"
        rm -f "$MERGED_AUTH_FILE" "$SORTED_IMAGES_FILE"
    else
        rm -f "$ALL_IMAGES_FILE"
    fi
    
else
    # Single FBC tag mode (original behavior)
    log "INFO" "Processing single operator from FBC tag"
    
    if [[ "$DISCONNECTED" == true ]]; then
        log "INFO" "Mirroring FBC image for disconnected cluster..."
        fbc_target="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:${FBC_TAG}"
        mirror_output=$(oc image mirror --keep-manifest-list=true "$FBC_SOURCE_IMAGE" "$fbc_target" 2>&1)
        mirror_status=$?
        if [[ $mirror_status -ne 0 ]]; then
            log "ERROR" "Failed to mirror FBC"
            log "ERROR" "Source: $FBC_SOURCE_IMAGE"
            log "ERROR" "Target: $fbc_target"
            log "ERROR" "Error output:"
            echo "$mirror_output" >&2
            exit 1
        fi
        log "SUCCESS" "FBC image mirrored successfully"
    else
        fbc_target="${FBC_SOURCE_IMAGE}"
    fi
    
    log "INFO" "Rendering FBC: $FBC_SOURCE_IMAGE"
    opm_output=$(opm render "$FBC_SOURCE_IMAGE") || { log "ERROR" "opm render failed"; exit 1; }
    
    log "INFO" "Finding latest bundle version..."
    latest_bundle=$(echo "$opm_output" | jq -r 'select(.schema == "olm.bundle") | .name' | sort -V | tail -1)
    [[ -z "$latest_bundle" ]] && { log "ERROR" "No bundle found"; exit 1; }
    
    log "INFO" "Extracting bundle data..."
    bundle_data=$(echo "$opm_output" | jq "select(.schema == \"olm.bundle\" and .name == \"$latest_bundle\")")
    
    log "INFO" "Extracting operator metadata..."
    OPERATOR_NAME=$(echo "$bundle_data" | jq -r '.package // empty' | head -1)
    [[ -z "$OPERATOR_NAME" ]] && { log "ERROR" "Could not extract operator name from bundle"; exit 1; }
    
    OPERATOR_NAMESPACE=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.annotations["operatorframework.io/suggested-namespace"] // empty' | head -1)
    if [[ -z "$OPERATOR_NAMESPACE" ]]; then
        OPERATOR_NAMESPACE="openshift-${OPERATOR_NAME}"
        NAMESPACE_SOURCE="derived from operator name"
    else
        NAMESPACE_SOURCE="from FBC annotation"
    fi
    
    default_channel=$(echo "$opm_output" | jq -r 'select(.schema == "olm.package") | .defaultChannel // "stable"' | head -1)
    [[ -z "$default_channel" ]] && default_channel="stable"
    
    install_mode=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.installModes[]? | select(.supported == true) | .type' | head -1)
    [[ -z "$install_mode" ]] && install_mode="SingleNamespace"
    
    {
        echo "Operator Name:    ${OPERATOR_NAME}"
        echo "Bundle Name:      ${latest_bundle}"
        echo "Namespace:        ${OPERATOR_NAMESPACE} (${NAMESPACE_SOURCE})"
        echo "Channel:          ${default_channel}"
        echo "Install Mode:     ${install_mode}"
        echo ""
        echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sort -u | nl -w2 -s'. '
    } | display_metadata
    
    if [[ "$DISCONNECTED" == true ]]; then
        echo "Mirroring related images..."
        image_count=0
        total_images=$(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | wc -l)
        
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            digest=$(echo "$image" | grep -o 'sha256:[a-f0-9]\{64\}' || continue)
            [[ -z "$digest" ]] && continue
            
            ((image_count++))
            echo "  [$image_count/$total_images] Mirroring $digest..."
            source="${ART_IMAGES_SOURCE}@${digest}"
            target="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
            
            mirror_output=$(oc image mirror --keep-manifest-list=true "$source" "$target" </dev/null 2>&1)
            mirror_status=$?
            
            if [[ $mirror_status -eq 0 ]]; then
                echo "$mirror_output" | tail -2
                echo "    ✓ Success"
            else
                echo "ERROR: Failed to mirror image" >&2
                echo "$mirror_output" | tail -10 >&2
                echo "  Source: $source" >&2
                echo "  Target: $target" >&2
                echo "  Digest: $digest" >&2
                exit 1
            fi
        done < <(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sort -u)
        echo "Successfully mirrored all $image_count images"
    fi
fi

# Create IDMS
log_step "IDMS" "Creating Image Digest Mirror Sets (IDMS)"

if [[ ${#OPERATORS[@]} -gt 0 ]]; then
    # Create separate IDMS for each operator
    log "INFO" "Generating IDMS for each operator"
    
    if [[ "$DISCONNECTED" == true ]]; then
        IDMS_MIRROR="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"
        IDMS_SUFFIX="internal-idms"
    else
        IDMS_MIRROR="${ART_IMAGES_SOURCE}"
        IDMS_SUFFIX="art-idms"
    fi
    
    # Store IDMS YAMLs in temp files
    declare -A OPERATOR_IDMS_FILES
    
    # Loop 1: Generate all IDMS YAMLs
    for op in "${OPERATORS[@]}"; do
        fbc_source="${OPERATOR_FBC_SOURCES[$op]}"
        idms_name="${op}-${IDMS_SUFFIX}"
        
        echo "  Generating IDMS: $idms_name"
        
        # Re-render FBC to get bundle data for this operator
        opm_output=$(opm render "$fbc_source" 2>/dev/null) || { echo "ERROR: opm render failed for $op" >&2; exit 1; }
        latest_bundle=$(echo "$opm_output" | jq -r 'select(.schema == "olm.bundle") | .name' | sort -V | tail -1)
        bundle_data=$(echo "$opm_output" | jq "select(.schema == \"olm.bundle\" and .name == \"$latest_bundle\")")
        
        # Create temp file for this IDMS
        idms_file=$(mktemp)
        OPERATOR_IDMS_FILES[$op]="$idms_file"
        
        {
        echo "apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${idms_name}
spec:
  imageDigestMirrors:"
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            echo "  - mirrors:
    - ${IDMS_MIRROR}
    source: $repo"
        done < <(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sed 's/@sha256:[a-f0-9]\{64\}$//' | sort -u)
        } > "$idms_file"
    done
    
    # Loop 2: Apply all IDMS YAMLs to cluster
    echo ""
    echo "Applying all IDMS to cluster..."
    for op in "${OPERATORS[@]}"; do
        idms_file="${OPERATOR_IDMS_FILES[$op]}"
        idms_name="${op}-${IDMS_SUFFIX}"
        echo "  Applying IDMS: $idms_name"
        oc apply -f "$idms_file" || { echo "ERROR: IDMS apply failed for $op" >&2; exit 1; }
        rm -f "$idms_file"
    done
    
    log "INFO" "Waiting for Machine Config Pool update after IDMS creation..."
    oc wait --for=condition=Updating mcp --all --timeout=60s >/dev/null 2>&1 || true
    oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} >/dev/null 2>&1 || true
    log "SUCCESS" "Machine Config Pool update completed"
    
else
    # Single operator IDMS
    log "INFO" "Generating IDMS for single operator"
    
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
    } | oc apply -f - || { log "ERROR" "IDMS apply failed"; exit 1; }
    
    log "INFO" "Waiting for Machine Config Pool update after IDMS creation..."
    oc wait --for=condition=Updating mcp --all --timeout=60s >/dev/null 2>&1 || true
    oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} >/dev/null 2>&1 || true
    log "SUCCESS" "Machine Config Pool update completed"
fi

# Add insecure registry
log "INFO" "Configuring cluster settings"

if [[ "$DISCONNECTED" == true ]]; then
    log "INFO" "Adding insecure registry configuration..."
    oc patch image.config.openshift.io/cluster --patch '{"spec":{ "registrySources": { "insecureRegistries" : ["'"${INTERNAL_REGISTRY}"'"] }}}' --type=merge || \
        { log "ERROR" "Failed to patch image config"; exit 1; }
    
    log "INFO" "Waiting for Machine Config Pool update after registry config..."
    oc wait --for=condition=Updating mcp --all --timeout=60s >/dev/null 2>&1 || true
    oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} >/dev/null 2>&1 || true
    log "SUCCESS" "Machine Config Pool update completed"
fi

# Disable default catalogs
log "INFO" "Disabling default catalogs..."
oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": true}}' --type=merge || \
    { log "ERROR" "Failed to disable default catalogs"; exit 1; }
log "SUCCESS" "Default catalogs disabled"

# Deploy operators
log_step "DEPLOY" "Starting Operator Deployment"

if [[ ${#OPERATORS[@]} -gt 0 ]]; then
    # Deploy multiple operators
    log "INFO" "Deploying ${#OPERATORS[@]} operator(s)"
    
    # Arrays to track deployment status
    declare -a FAILED_OPERATORS=()
    declare -a SUCCESS_OPERATORS=()
    
    for op in "${OPERATORS[@]}"; do
        echo ""
        echo "Deploying operator: $op"
        echo "------------------------------------------------------------"
        
        catalog_name="${OPERATOR_CATALOG_NAMES[$op]}"
        fbc_target="${OPERATOR_FBC_TARGETS[$op]}"
        operator_name="${OPERATOR_NAMES[$op]}"
        operator_namespace="${OPERATOR_NAMESPACES[$op]}"
        latest_bundle="${OPERATOR_BUNDLES[$op]}"
        default_channel="${OPERATOR_CHANNELS[$op]}"
        install_mode="${OPERATOR_INSTALL_MODES[$op]}"
        
        # Flag to track if this operator deployment failed
        deployment_failed=false
        
        # Cleanup existing resources
        log "INFO" "Cleaning up existing resources for $op..."
        log "INFO" "  - Deleting namespace: $operator_namespace"
        oc delete namespace "$operator_namespace" --ignore-not-found >/dev/null 2>&1 || true
        log "INFO" "  - Deleting CatalogSource: $catalog_name"
        oc delete catalogsource "$catalog_name" -n openshift-marketplace --ignore-not-found >/dev/null 2>&1 || true
        log "SUCCESS" "Cleanup completed for $op"
        
        # Temporarily disable exit on error for this operator's deployment
        set +e
        
        # Create CatalogSource
        log "INFO" "Creating CatalogSource for $op..."
        if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${catalog_name}
  namespace: openshift-marketplace
spec:
  displayName: ${catalog_name}
  image: ${fbc_target}
  sourceType: grpc
EOF
        then
            log "ERROR" "CatalogSource apply failed for $op"
            deployment_failed=true
        else
            log "SUCCESS" "CatalogSource created"
        fi
        
        # Wait for catalog ready
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Waiting for CatalogSource to be ready..."
            if ! oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
                catalogsource "$catalog_name" -n openshift-marketplace --timeout=300s 2>/dev/null; then
                log "ERROR" "CatalogSource $catalog_name not ready within timeout"
                deployment_failed=true
            else
                log "SUCCESS" "CatalogSource is ready"
            fi
        fi
        
        # Create namespace
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Creating Namespace for $op..."
            if oc apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $operator_namespace
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF
            then
                log "SUCCESS" "Namespace created"
            else
                log "ERROR" "Namespace creation failed for $op"
                deployment_failed=true
            fi
        fi
        
        # Create OperatorGroup
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Creating OperatorGroup for $op..."
            if [[ "$install_mode" == "AllNamespaces" ]]; then
                if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${operator_name}
  namespace: ${operator_namespace}
spec: {}
EOF
                then
                    log "ERROR" "OperatorGroup apply failed for $op"
                    deployment_failed=true
                else
                    log "SUCCESS" "OperatorGroup created"
                fi
            else
                if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${operator_name}
  namespace: ${operator_namespace}
spec:
  targetNamespaces:
  - ${operator_namespace}
EOF
                then
                    log "ERROR" "OperatorGroup apply failed for $op"
                    deployment_failed=true
                else
                    log "SUCCESS" "OperatorGroup created"
                fi
            fi
        fi
        
        # Create Subscription
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Creating Subscription for $op..."
            if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${operator_name}
  namespace: ${operator_namespace}
spec:
  channel: $default_channel
  installPlanApproval: Automatic
  name: ${operator_name}
  source: $catalog_name
  sourceNamespace: openshift-marketplace
EOF
            then
                log "ERROR" "Subscription apply failed for $op"
                deployment_failed=true
            else
                log "SUCCESS" "Subscription created"
            fi
        fi
        
        # Wait for subscription to get currentCSV
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Waiting for subscription to resolve..."
            if ! oc wait --for=jsonpath='{.status.currentCSV}'="${latest_bundle}" subscription "${operator_name}" -n "${operator_namespace}" --timeout=120s 2>/dev/null; then
                log "ERROR" "Subscription did not resolve within timeout"
                deployment_failed=true
            else
                log "SUCCESS" "Subscription resolved"
            fi
        fi
        
        # Wait for CSV
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Waiting for CSV ${latest_bundle} to be created..."
            if ! oc wait --for=create csv "$latest_bundle" -n "$operator_namespace" --timeout=90s 2>/dev/null; then
                log "ERROR" "CSV ${latest_bundle} not created within timeout"
                deployment_failed=true
            else
                log "SUCCESS" "CSV created"
            fi
        fi
        
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Waiting for CSV ${latest_bundle} to reach Succeeded phase..."
            if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded csv "$latest_bundle" -n "$operator_namespace" --timeout=120s 2>/dev/null; then
                log "ERROR" "CSV ${latest_bundle} did not reach Succeeded phase"
                deployment_failed=true
            else
                log "SUCCESS" "CSV reached Succeeded phase"
            fi
        fi
        
        # Wait for operator pods
        if [[ "$deployment_failed" == false ]]; then
            log "INFO" "Waiting for operator pods to be ready..."
            if ! oc wait --for=condition=Ready pods --all -n "$operator_namespace" --timeout=120s 2>/dev/null; then
                log "ERROR" "Operator pods not ready within timeout"
                deployment_failed=true
            else
                log "SUCCESS" "All operator pods are ready"
            fi
        fi
        
        # Re-enable exit on error
        set -e
        
        # Record result
        if [[ "$deployment_failed" == true ]]; then
            FAILED_OPERATORS+=("$op")
            log "ERROR" "Operator $op deployment failed, continuing with next operator..."
        else
            SUCCESS_OPERATORS+=("$op")
            log "SUCCESS" "Operator $op deployed successfully"
        fi
    done
    
    log_step "SUMMARY" "Deployment Summary"
    
    if [[ ${#SUCCESS_OPERATORS[@]} -gt 0 ]]; then
        log "SUCCESS" "Successfully deployed (${#SUCCESS_OPERATORS[@]}): ${SUCCESS_OPERATORS[*]}"
    fi
    
    if [[ ${#FAILED_OPERATORS[@]} -gt 0 ]]; then
        log "ERROR" "Failed to deploy (${#FAILED_OPERATORS[@]}): ${FAILED_OPERATORS[*]}"
        log "ERROR" "Deployment completed with errors!"
        exit 1
    else
        log "SUCCESS" "All operators deployed successfully!"
    fi
    
else
    # Deploy single operator (original behavior)
    log "INFO" "Deploying single operator"
    
    # Cleanup existing resources
    log "INFO" "Cleaning up existing resources..."
    log "INFO" "  - Deleting namespace: $OPERATOR_NAMESPACE"
    oc delete namespace "$OPERATOR_NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    log "INFO" "  - Deleting CatalogSource: $CATALOG_NAME"
    oc delete catalogsource "$CATALOG_NAME" -n openshift-marketplace --ignore-not-found >/dev/null 2>&1 || true
    log "SUCCESS" "Cleanup completed"
    
    # Create CatalogSource
    log "INFO" "Creating CatalogSource..."
    oc apply -f - <<EOF || { log "ERROR" "CatalogSource apply failed"; exit 1; }
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
    log "SUCCESS" "CatalogSource created"
    
    # Wait for catalog ready
    log "INFO" "Waiting for CatalogSource to be ready..."
    oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
        catalogsource "$CATALOG_NAME" -n openshift-marketplace --timeout=300s 2>/dev/null || true
    log "SUCCESS" "CatalogSource is ready"
    
    # Create namespace
    log "INFO" "Creating Namespace..."
    oc apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $OPERATOR_NAMESPACE
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF
    log "SUCCESS" "Namespace created"
    
    # Create OperatorGroup
    log "INFO" "Creating OperatorGroup..."
    if [[ "$install_mode" == "AllNamespaces" ]]; then
        oc apply -f - <<EOF || { log "ERROR" "OperatorGroup apply failed"; exit 1; }
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec: {}
EOF
    log "SUCCESS" "OperatorGroup created"
    else
        oc apply -f - <<EOF || { log "ERROR" "OperatorGroup apply failed"; exit 1; }
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  targetNamespaces:
  - ${OPERATOR_NAMESPACE}
EOF
    log "SUCCESS" "OperatorGroup created"
    fi
    
    # Create Subscription
    log "INFO" "Creating Subscription..."
    oc apply -f - <<EOF || { log "ERROR" "Subscription apply failed"; exit 1; }
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
    log "SUCCESS" "Subscription created"
    
    # Wait for subscription to get currentCSV
    log "INFO" "Waiting for subscription to resolve..."
    if ! oc wait --for=jsonpath='{.status.currentCSV}'="${latest_bundle}" subscription "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=120s 2>/dev/null; then
        log "ERROR" "Subscription did not resolve within timeout"
        exit 1
    fi
    log "SUCCESS" "Subscription resolved"
    
    # Wait for CSV
    log "INFO" "Waiting for CSV ${latest_bundle} to be created..."
    oc wait --for=create csv "$latest_bundle" -n "$OPERATOR_NAMESPACE" --timeout=180s 2>/dev/null || \
        { log "WARNING" "CSV ${latest_bundle} was not created within timeout"; }
    log "SUCCESS" "CSV created"
    
    log "INFO" "Waiting for CSV ${latest_bundle} to reach Succeeded phase..."
    oc wait --for=jsonpath='{.status.phase}'=Succeeded csv "$latest_bundle" -n "$OPERATOR_NAMESPACE" --timeout=180s 2>/dev/null || \
        { log "WARNING" "CSV ${latest_bundle} did not reach Succeeded phase within timeout"; }
    log "SUCCESS" "CSV reached Succeeded phase"
    
    # Wait for operator pods
    log "INFO" "Waiting for operator pods to be ready..."
    oc wait --for=condition=Ready pods --all -n "$OPERATOR_NAMESPACE" --timeout=180s 2>/dev/null || \
        { log "WARNING" "Operator pods did not reach Ready state within timeout"; }
    log "SUCCESS" "All operator pods are ready"
fi

