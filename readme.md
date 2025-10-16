# Operator Deployment Script - Usage Guide

This script deploys Konflux-built operators on both **connected** and **disconnected** OpenShift clusters with automatic metadata extraction and intelligent mode detection.

---

## Table of Contents
- [Prerequisites](#prerequisites)
- [Script Modes](#script-modes)
- [Arguments](#arguments)
- [Multiple Operators Deployment](#multiple-operators-deployment)
- [Connected Cluster Examples](#connected-cluster-examples)
- [Disconnected Cluster Examples](#disconnected-cluster-examples)
- [Authentication Files](#authentication-files)
- [Predefined Operators](#predefined-operators)
- [Features](#features)
- [Common Scenarios](#common-scenarios)
- [Error Examples](#error-examples)
- [Quick Reference](#quick-reference)

---

## Prerequisites

Required tools (script validates these automatically):
- **oc** - OpenShift CLI
- **opm** - Operator Package Manager
- **jq** - JSON processor  
- **podman** - Container tool for authentication

---

## Script Modes

### Connected Cluster Mode
For clusters that can directly access `quay.io`:

**What happens:**
- ✅ Updates cluster pull-secret with quay.io credentials
- ✅ Uses FBC image directly from quay.io
- ✅ Creates IDMS mapping to ART images on quay.io
- ✅ Waits for MCP updates to complete
- ❌ NO image mirroring to internal registry
- ❌ NO insecure registry configuration

**Usage:**
```bash
./deploy-operator.sh \
  --operator <name> \
  --quay-auth <quay-auth-file>
```

```bash
./deploy-operator.sh \
  --fbc-tag <fbc-image-tag> \
  --quay-auth <quay-auth-file>
```

### Disconnected Cluster Mode
For air-gapped clusters with internal registry:

**What happens:**
- ✅ Authenticates to both quay.io and internal registry
- ✅ Mirrors FBC image to internal registry
- ✅ Mirrors all related images to internal registry
- ✅ Creates IDMS mapping to internal registry
- ✅ Configures insecure registry (if needed)
- ✅ Waits for MCP updates to complete

**Usage:**
```bash
./deploy-operator.sh \
  --operator <name> \
  --internal-registry <host:port> \
  --internal-registry-auth <internal-auth-file> \
  --quay-auth <quay-auth-file>
```

```bash
./deploy-operator.sh \
  --fbc-tag <fbc-image-tag> \
  --internal-registry <host:port> \
  --internal-registry-auth <internal-auth-file> \
  --quay-auth <quay-auth-file>
```

---

## Features

### Automatic Detection & Extraction

#### 1. Cluster Version Detection
```bash
# Automatically runs:
oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2
# Result: 4.17
```

#### 2. Smart Quay.io Authentication
The script intelligently selects the best credentials from your auth file with priority:

1. **Priority 1**: Specific repository credentials  
   `quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share`
2. **Priority 2**: Broader repository credentials  
   `quay.io/redhat-user-workloads`
3. **Priority 3**: General domain credentials  
   `quay.io`

The script displays which credentials are being used:
```
Authenticating to quay.io using credentials from: quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share
  Username: redhat-user-workloads+ocp_art_tenant_art_images_share_98cc2cdb16_pull
```

#### 3. Operator Metadata Extraction
From the FBC bundle, the script automatically extracts:
- **Operator Name** - From bundle's `.package` field
- **Bundle Name** - Latest versioned bundle
- **Namespace** - From FBC annotation or derived as `openshift-<operator-name>`
- **Channel** - Default channel from package manifest
- **Install Mode** - SingleNamespace or AllNamespaces
- **Related Images** - All operator container images

#### 4. Mode Detection
```bash
# If --internal-registry provided → Disconnected mode
# If NOT provided → Connected mode
```

### Example Script Output

```
Mode: Connected cluster
Detected OCP version: 4.17
Updated cluster pull-secret with quay.io credentials
============================================================
Extracted Metadata:
============================================================
Operator Name:    sriov-network-operator
Bundle Name:      sriov-network-operator.v4.17.0-202501141644
Namespace:        openshift-sriov-network-operator (from FBC annotation)
Channel:          stable
Install Mode:     SingleNamespace
============================================================
Related Images:
============================================================
 1. quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share@sha256:abc123...
 2. quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share@sha256:def456...
 3. quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share@sha256:ghi789...
============================================================
```

### Error Handling

The script validates and handles errors intelligently:

**Pre-deployment Validation** (exits immediately):
- ✅ All required commands installed (`oc`, `opm`, `jq`, `podman`)
- ✅ Authentication files exist and contain valid JSON
- ✅ Cluster connectivity
- ✅ All operator names are valid
- ✅ Registry authentication succeeds
- ✅ Image mirroring operations complete
- ✅ IDMS creation succeeds

**Operator Deployment** (continues on failure when deploying multiple operators):
- ✅ If one operator fails, script continues with remaining operators
- ✅ Tracks successful and failed deployments separately
- ✅ Provides deployment summary at the end
- ✅ Exits with code 1 if any operators failed

All errors show descriptive messages to stderr.

---

## Arguments

### Required Arguments

| Argument | Description | Example |
|----------|-------------|---------|
| `--quay-auth FILE` | Authentication file for quay.io | `--quay-auth ~/quay-auth.json` |
| `--operator NAME[,NAME,...]` | Single or comma-separated operator names | `--operator sriov` or `--operator sriov,metallb,nmstate` |
| OR | | |
| `--fbc-tag TAG` | Custom FBC tag (single operator only) | `--fbc-tag ocp__4.17__custom-operator` |

**Note:** 
- Provide either `--operator` OR `--fbc-tag`, not both.
- Multiple operators can be specified with `--operator` as comma-separated list.
- Valid operators: `sriov`, `metallb`, `nmstate`, `ptp`, `pfstatus`

### Optional Arguments (Disconnected Mode)

| Argument | Description | Example |
|----------|-------------|---------|
| `--internal-registry HOST:PORT` | Internal registry URL | `--internal-registry registry.local:5000` |
| `--internal-registry-auth FILE` | Auth file for internal registry | `--internal-registry-auth ~/internal-auth.json` |

**Note:** Both `--internal-registry` and `--internal-registry-auth` must be provided together.

---

## Multiple Operators Deployment

The script supports deploying multiple operators in a single run, which is optimized for efficiency and time savings.

### Syntax

```bash
./deploy-operator.sh \
  --operator operator1,operator2,operator3,... \
  --quay-auth <quay-auth-file> \
  [--internal-registry <host:port>] \
  [--internal-registry-auth <internal-auth-file>]
```

### How It Works

When deploying multiple operators, the script optimizes the process:

1. **Parallel FBC Processing**: Processes all operator FBC images
2. **Deduplication**: Collects all related images and removes duplicates
3. **Bulk Mirroring**: Mirrors unique images once (in disconnected mode)
4. **Batch IDMS Creation**: 
   - **Loop 1**: Generates all IDMS YAMLs for each operator
   - **Loop 2**: Applies all IDMS to cluster together
   - **Single MCP Wait**: Waits for MachineConfigPool update only once (not per operator)
5. **Sequential Deployment**: Deploys each operator one by one
6. **Continue on Failure**: If one operator fails, continues with the rest
7. **Summary Report**: Shows deployment status for all operators

### Benefits

- ⚡ **Faster**: Single MCP update cycle instead of one per operator
- 🎯 **Efficient**: Unique images mirrored only once
- 💪 **Resilient**: Failed operator doesn't block others
- 📊 **Transparent**: Clear summary of successes and failures

### Examples

#### Deploy All Network Operators (Connected)
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --quay-auth ~/quay-auth.json
```

#### Deploy Multiple Operators (Disconnected)
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate \
  --internal-registry registry.local:5000 \
  --internal-registry-auth ~/internal-auth.json \
  --quay-auth ~/quay-auth.json
```

#### Deploy Two Operators
```bash
./deploy-operator.sh \
  --operator ptp,pfstatus \
  --quay-auth ~/quay-auth.json
```

### Example Output

```
Operators to deploy: sriov metallb nmstate ptp pfstatus
Mode: Disconnected cluster
Detected OCP version: 4.20

============================================================
Processing 5 operator(s)
============================================================

Processing operator: sriov
------------------------------------------------------------
Mirroring FBC image...
Extracting metadata from FBC...
  Operator Name:  sriov-network-operator
  Bundle:         sriov-network-operator.v4.20.0-202510141524
  Namespace:      openshift-sriov-network-operator (annotated)
  Channel:        stable
  Install Mode:   OwnNamespace
  Related Images: 11

[... processing metallb, nmstate, ptp, pfstatus ...]

============================================================
Total unique images across all operators: 26
============================================================
Mirroring related images...
  [1/26] Mirroring sha256:f0c8310d...
    ✓ Success
  [2/26] Mirroring sha256:a6c0a255...
    ✓ Success
[... continues for all 26 unique images ...]
Successfully mirrored all 26 images

Generating IDMS for each operator...
  Generating IDMS: sriov-internal-idms
  Generating IDMS: metallb-internal-idms
  Generating IDMS: nmstate-internal-idms
  Generating IDMS: ptp-internal-idms
  Generating IDMS: pfstatus-internal-idms

Applying all IDMS to cluster...
  Applying IDMS: sriov-internal-idms
  Applying IDMS: metallb-internal-idms
  Applying IDMS: nmstate-internal-idms
  Applying IDMS: ptp-internal-idms
  Applying IDMS: pfstatus-internal-idms

Waiting for MachineConfigPool to update (once for all operators)...

============================================================
Deploying 5 operator(s)
============================================================

Deploying operator: sriov
------------------------------------------------------------
  Creating CatalogSource...
  Creating Namespace...
  Creating OperatorGroup...
  Creating Subscription...
  Waiting for CSV sriov-network-operator.v4.20.0-202510141524...
  Waiting for operator pods...
  ✓ Operator sriov deployed successfully

[... continues for metallb, nmstate, ptp, pfstatus ...]

============================================================
Deployment Summary
============================================================
Successfully deployed (5): sriov metallb nmstate ptp pfstatus

All operators deployed successfully!
============================================================
```

### Failure Handling Example

If one operator fails, the script continues with others:

```
Deploying operator: sriov
------------------------------------------------------------
  Creating CatalogSource...
  ERROR: CatalogSource apply failed for sriov
  ✗ Operator sriov deployment failed, continuing with next operator...

Deploying operator: metallb
------------------------------------------------------------
  Creating CatalogSource...
  Creating Namespace...
  [... continues successfully ...]
  ✓ Operator metallb deployed successfully

[... continues with remaining operators ...]

============================================================
Deployment Summary
============================================================
Successfully deployed (4): metallb nmstate ptp pfstatus
Failed to deploy (1): sriov

Deployment completed with errors!
============================================================
```

The script will exit with code 1 if any operators failed, but only after attempting to deploy all of them.

---

## Connected Cluster Examples

### Deploy SR-IOV Operator
```bash
./deploy-operator.sh \
  --operator sriov \
  --quay-auth /path/to/quay-auth.json
```

**What happens:**
1. Detects OCP version automatically (e.g., 4.17)
2. Updates cluster pull-secret with quay.io credentials
3. Uses FBC image: `quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:ocp__4.17__ose-sriov-network-rhel9-operator`
4. Extracts operator metadata from FBC bundle
5. Creates IDMS mapping images to `quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share`
6. Waits for MCP updates
7. Creates CatalogSource, OperatorGroup, Subscription
8. Waits for CSV and operator pods to be ready

### Deploy MetalLB Operator
```bash
./deploy-operator.sh \
  --operator metallb \
  --quay-auth ~/auth/quay-pull-secret.json
```

### Deploy NMState Operator
```bash
./deploy-operator.sh \
  --operator nmstate \
  --quay-auth ~/.docker/quay-auth.json
```

### Deploy PTP Operator
```bash
./deploy-operator.sh \
  --operator ptp \
  --quay-auth /tmp/quay-auth.json
```

### Deploy PF Status Operator
```bash
./deploy-operator.sh \
  --operator pfstatus \
  --quay-auth /root/quay-auth.json
```

### Deploy Custom Operator with FBC Tag
```bash
./deploy-operator.sh \
  --fbc-tag ocp__4.17__my-custom-rhel9-operator \
  --quay-auth /path/to/quay-auth.json
```

---

## Disconnected Cluster Examples

### Deploy SR-IOV Operator (Disconnected)
```bash
./deploy-operator.sh \
  --operator sriov \
  --internal-registry registry.internal.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json
```

**What happens:**
1. Detects OCP version automatically
2. Authenticates to quay.io using provided credentials
3. Authenticates to internal registry
4. Mirrors FBC image to internal registry
5. Extracts operator metadata from FBC bundle
6. Mirrors all related images to internal registry
7. Creates IDMS mapping to internal registry
8. Waits for MCP updates
9. Configures insecure registry
10. Waits for MCP updates again
11. Deploys operator from internal registry

### Deploy MetalLB (Disconnected)
```bash
./deploy-operator.sh \
  --operator metallb \
  --internal-registry mirror.corp.com:443 \
  --internal-registry-auth ~/internal-registry-auth.json \
  --quay-auth ~/quay-auth.json
```

### Deploy NMState with IP Registry
```bash
./deploy-operator.sh \
  --operator nmstate \
  --internal-registry 192.168.1.100:5000 \
  --internal-registry-auth /root/auth/internal-auth.json \
  --quay-auth /root/auth/quay-auth.json
```

### Deploy PTP with Custom Port
```bash
./deploy-operator.sh \
  --operator ptp \
  --internal-registry registry.airgap.local:8443 \
  --internal-registry-auth /etc/auth/internal.json \
  --quay-auth /etc/auth/quay.json
```

### Deploy Custom Operator using FBC Tag (Disconnected)
```bash
./deploy-operator.sh \
  --fbc-tag ocp__4.16__custom-rhel9-operator \
  --internal-registry registry.private:5000 \
  --internal-registry-auth /opt/auth/internal.json \
  --quay-auth /opt/auth/quay.json
```

---

## Authentication Files

### Quay Auth File Format

The script supports auth files with **multiple registry entries** and automatically selects the most specific one.

**Simple format:**
```json
{
  "auths": {
    "quay.io": {
      "auth": "base64EncodedUsername:Password=="
    }
  }
}
```

**With specific registry path (recommended):**
```json
{
  "auths": {
    "quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share": {
      "auth": "base64EncodedUsername:Password=="
    }
  }
}
```

**Multiple registries in one file:**
```json
{
  "auths": {
    "quay.io": {
      "auth": "base64EncodedGeneralQuayAuth=="
    },
    "quay.io/redhat-user-workloads": {
      "auth": "base64EncodedWorkloadsAuth=="
    },
    "quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share": {
      "auth": "base64EncodedSpecificAuth=="
    },
    "registry.redhat.io": {
      "auth": "base64EncodedRedHatAuth=="
    }
  }
}
```
> **Note**: The script will use the most specific match (in this case, `art-images-share`)

### Internal Registry Auth File Format

```json
{
  "auths": {
    "registry.internal.example.com:5000": {
      "auth": "base64EncodedUsername:Password=="
    }
  }
}
```

### Creating Auth Files

From podman login:
```bash
# Login to quay.io
podman login quay.io --authfile=quay-auth.json

# Login to internal registry
podman login registry.internal:5000 --authfile=internal-auth.json
```

From username/password:
```bash
# Create base64 encoded credentials
echo -n "username:password" | base64

# Create auth file manually
cat > quay-auth.json <<EOF
{
  "auths": {
    "quay.io": {
      "auth": "dXNlcm5hbWU6cGFzc3dvcmQ="
    }
  }
}
EOF
```

---

## Predefined Operators

| Operator Name | CLI Argument | Package Name | Default Namespace |
|--------------|--------------|--------------|-------------------|
| SR-IOV Network Operator | `--operator sriov` | `sriov-network-operator` | `openshift-sriov-network-operator` |
| MetalLB Operator | `--operator metallb` | `metallb-operator` | `openshift-metallb` |
| NMState Operator | `--operator nmstate` | `kubernetes-nmstate-operator` | `openshift-nmstate` |
| PTP Operator | `--operator ptp` | `ptp-operator` | `openshift-ptp` |
| PF Status Relay Operator | `--operator pfstatus` | `pf-status-relay-operator` | Derived from operator name |

**Note:** The script automatically detects the OCP version and uses the appropriate FBC tag.

---



## Common Scenarios

### Scenario 1: Development Environment (Connected)
Quick operator deployment for testing:
```bash
./deploy-operator.sh \
  --operator metallb \
  --quay-auth ~/dev/quay-auth.json
```

### Scenario 2: Production Air-Gapped Cluster
Secure deployment with mirrored images:
```bash
./deploy-operator.sh \
  --operator sriov \
  --internal-registry prod-registry.secure.local:5000 \
  --internal-registry-auth /secure/auth/internal-auth.json \
  --quay-auth /secure/auth/quay-auth.json
```

### Scenario 3: Testing Custom Operator Build
Deploy custom Konflux-built operator:
```bash
./deploy-operator.sh \
  --fbc-tag ocp__4.17__test-operator-v2 \
  --quay-auth ~/test-auth.json
```

### Scenario 4: Multi-Cluster Deployment (Connected)
Deploy same operator to multiple clusters:
```bash
# Cluster 1
oc login https://cluster1.example.com:6443
./deploy-operator.sh --operator ptp --quay-auth ~/quay-auth.json

# Cluster 2  
oc login https://cluster2.example.com:6443
./deploy-operator.sh --operator ptp --quay-auth ~/quay-auth.json
```

### Scenario 5: Multi-Cluster Deployment (Disconnected)
Deploy to multiple air-gapped clusters with different registries:
```bash
# Cluster 1
oc login https://cluster1.airgap.local:6443
./deploy-operator.sh \
  --operator nmstate \
  --internal-registry registry1.airgap.local:5000 \
  --internal-registry-auth ~/auth/registry1.json \
  --quay-auth ~/auth/quay.json

# Cluster 2
oc login https://cluster2.airgap.local:6443
./deploy-operator.sh \
  --operator nmstate \
  --internal-registry registry2.airgap.local:5000 \
  --internal-registry-auth ~/auth/registry2.json \
  --quay-auth ~/auth/quay.json
```

### Scenario 6: Upgrade Existing Operator
Deploy newer version to same cluster:
```bash
# Delete existing deployment
oc delete namespace openshift-sriov-network-operator
oc delete catalogsource sriov-konflux -n openshift-marketplace

# Deploy new version
./deploy-operator.sh \
  --operator sriov \
  --quay-auth ~/quay-auth.json
```

---

## Error Examples

### Error: Missing Required Argument
```bash
./deploy-operator.sh --operator sriov
```
**Output:**
```
ERROR: --quay-auth is required
```

### Error: Both Operator and FBC Tag Provided
```bash
./deploy-operator.sh \
  --operator sriov \
  --fbc-tag ocp__4.17__metallb-rhel9-operator \
  --quay-auth ~/quay-auth.json
```
**Output:**
```
ERROR: Provide either --operator or --fbc-tag, not both
```

### Error: Neither Operator nor FBC Tag Provided
```bash
./deploy-operator.sh --quay-auth ~/quay-auth.json
```
**Output:**
```
ERROR: Provide either --operator or --fbc-tag
```

### Error: Incomplete Disconnected Mode Arguments
```bash
./deploy-operator.sh \
  --operator sriov \
  --internal-registry registry.local:5000 \
  --quay-auth ~/quay-auth.json
```
**Output:**
```
ERROR: Both --internal-registry and --internal-registry-auth must be provided together
```

### Error: Invalid Operator Name
```bash
./deploy-operator.sh \
  --operator invalid-operator \
  --quay-auth ~/quay-auth.json
```
**Output:**
```
ERROR: Invalid operator: invalid-operator
Valid operators: sriov metallb nmstate ptp pfstatus
```

### Error: Invalid Operator in Multiple Operators List
```bash
./deploy-operator.sh \
  --operator sriov,badname,metallb \
  --quay-auth ~/quay-auth.json
```
**Output:**
```
ERROR: Invalid operator: badname
Valid operators: sriov metallb nmstate ptp pfstatus
```

### Error: Auth File Not Found
```bash
./deploy-operator.sh \
  --operator sriov \
  --quay-auth /nonexistent/file.json
```
**Output:**
```
ERROR: Quay auth file not found
```

### Error: Invalid JSON in Auth File
```bash
./deploy-operator.sh \
  --operator sriov \
  --quay-auth ~/broken-auth.json
```
**Output:**
```
ERROR: Invalid JSON in quay auth
```

### Error: Cannot Connect to Cluster
```bash
# No cluster context or cluster unreachable
./deploy-operator.sh \
  --operator sriov \
  --quay-auth ~/quay-auth.json
```
**Output:**
```
ERROR: Cannot connect to cluster
```

---

## Quick Reference

### Connected Cluster Commands

**Single operator:**
```bash
./deploy-operator.sh \
  --operator <sriov|metallb|nmstate|ptp|pfstatus> \
  --quay-auth <quay-auth-file>
```

**Multiple operators:**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --quay-auth <quay-auth-file>
```

**Custom operator:**
```bash
./deploy-operator.sh \
  --fbc-tag <custom-fbc-tag> \
  --quay-auth <quay-auth-file>
```

### Disconnected Cluster Commands

**Single operator:**
```bash
./deploy-operator.sh \
  --operator <sriov|metallb|nmstate|ptp|pfstatus> \
  --internal-registry <host:port> \
  --internal-registry-auth <internal-auth-file> \
  --quay-auth <quay-auth-file>
```

**Multiple operators:**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate \
  --internal-registry <host:port> \
  --internal-registry-auth <internal-auth-file> \
  --quay-auth <quay-auth-file>
```

**Custom operator:**
```bash
./deploy-operator.sh \
  --fbc-tag <custom-fbc-tag> \
  --internal-registry <host:port> \
  --internal-registry-auth <internal-auth-file> \
  --quay-auth <quay-auth-file>
```

### Cleanup Commands

**Remove operator completely:**
```bash
# Delete namespace (removes all operator resources)
oc delete namespace <operator-namespace>

# Delete catalog source
oc delete catalogsource <catalog-name> -n openshift-marketplace

# Delete IDMS (connected mode)
oc delete imagedigestmirrorset <operator>-art-idms

# Delete IDMS (disconnected mode)
oc delete imagedigestmirrorset <operator>-internal-idms
```

**Example cleanup for SR-IOV:**
```bash
oc delete namespace openshift-sriov-network-operator
oc delete catalogsource sriov-konflux -n openshift-marketplace
oc delete imagedigestmirrorset sriov-art-idms  # or sriov-internal-idms for disconnected
```

**Cleanup multiple operators at once:**
```bash
# Delete all operator namespaces
for op in sriov metallb nmstate ptp pfstatus; do
  oc delete catalogsource ${op}-konflux -n openshift-marketplace --ignore-not-found
  oc delete imagedigestmirrorset ${op}-internal-idms --ignore-not-found
done

# Delete specific namespaces
oc delete namespace openshift-sriov-network-operator --ignore-not-found
oc delete namespace metallb-system --ignore-not-found
oc delete namespace openshift-nmstate --ignore-not-found
oc delete namespace openshift-ptp --ignore-not-found
oc delete namespace openshift-pf-status-relay-operator --ignore-not-found
```

---

## Additional Resources

- **OpenShift Documentation**: https://docs.openshift.com/
- **OLM Documentation**: https://olm.operatorframework.io/
- **Konflux Documentation**: https://konflux-ci.dev/
- **Podman Documentation**: https://podman.io/

---

## Support & Troubleshooting

### Enable Verbose Output
Add `set -x` to the script for detailed execution trace:
```bash
#!/bin/bash
set -Eeuo pipefail
set -x  # Add this line
```

### Check Prerequisites
```bash
oc version
opm version
jq --version
podman version
```

### Verify Cluster Connectivity
```bash
oc cluster-info
oc get clusterversion
```

### Check Authentication
```bash
# Test quay.io authentication
podman login --authfile=quay-auth.json quay.io

# Test internal registry authentication
podman login --authfile=internal-auth.json registry.internal:5000
```

### Monitor Operator Deployment
```bash
# Watch catalog source
oc get catalogsource -n openshift-marketplace -w

# Watch subscription
oc get subscription -n <operator-namespace> -w

# Watch CSV (ClusterServiceVersion)
oc get csv -n <operator-namespace> -w

# Watch operator pods
oc get pods -n <operator-namespace> -w
```

### Check IDMS Status
```bash
# List all IDMS
oc get imagedigestmirrorset

# View specific IDMS
oc get imagedigestmirrorset <idms-name> -o yaml
```

### Check MCP Status
```bash
# View MachineConfigPool status
oc get mcp

# Watch MCP updates
oc get mcp -w
```

---

**Script Version**: 3.0  
**Last Updated**: October 2025  
**Supported OCP Versions**: 4.10+

### What's New in v3.0
- ✅ **Multiple Operators Deployment**: Deploy multiple operators in single run with comma-separated list
- ✅ **Optimized IDMS Creation**: Batch IDMS generation and application to minimize MCP restarts
- ✅ **Continue on Failure**: Failed operator doesn't block others, provides deployment summary
- ✅ **Smart Quay Authentication**: Priority-based credential selection from auth file
- ✅ **Merged Auth for Mirroring**: Combines quay and internal registry auth for efficient image mirroring
- ✅ **Better Error Reporting**: Detailed error messages with context for troubleshooting
