# Operator Deployment Script - Usage Guide

This script deploys Konflux-built operators on both **connected** and **disconnected** OpenShift clusters with automatic metadata extraction and intelligent mode detection.

---

## Table of Contents
- [Prerequisites](#prerequisites)
- [Script Modes](#script-modes)
- [Arguments](#arguments)
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

#### 2. Operator Metadata Extraction
From the FBC bundle, the script automatically extracts:
- **Operator Name** - From bundle's `.package` field
- **Bundle Name** - Latest versioned bundle
- **Namespace** - From FBC annotation or derived as `openshift-<operator-name>`
- **Channel** - Default channel from package manifest
- **Install Mode** - SingleNamespace or AllNamespaces
- **Related Images** - All operator container images

#### 3. Mode Detection
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

The script validates and exits immediately on errors:
- ✅ All required commands installed (`oc`, `opm`, `jq`, `podman`)
- ✅ Authentication files exist and contain valid JSON
- ✅ Cluster connectivity
- ✅ Registry authentication succeeds
- ✅ Image mirroring operations complete
- ✅ Kubernetes resource creation succeeds

All errors show descriptive messages to stderr.

---

## Arguments

### Required Arguments

| Argument | Description | Example |
|----------|-------------|---------|
| `--quay-auth FILE` | Authentication file for quay.io | `--quay-auth ~/quay-auth.json` |
| `--operator NAME` | Predefined operator name | `--operator sriov` |
| OR | | |
| `--fbc-tag TAG` | Custom FBC tag | `--fbc-tag ocp__4.17__custom-operator` |

**Note:** Provide either `--operator` OR `--fbc-tag`, not both.

### Optional Arguments (Disconnected Mode)

| Argument | Description | Example |
|----------|-------------|---------|
| `--internal-registry HOST:PORT` | Internal registry URL | `--internal-registry registry.local:5000` |
| `--internal-registry-auth FILE` | Auth file for internal registry | `--internal-registry-auth ~/internal-auth.json` |

**Note:** Both `--internal-registry` and `--internal-registry-auth` must be provided together.

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

**With specific registry path:**
```json
{
  "auths": {
    "quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share": {
      "auth": "base64EncodedUsername:Password=="
    }
  }
}
```

**With protocol:**
```json
{
  "auths": {
    "https://quay.io": {
      "auth": "base64EncodedUsername:Password=="
    }
  }
}
```

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

**Predefined operator:**
```bash
./deploy-operator.sh \
  --operator <sriov|metallb|nmstate|ptp|pfstatus> \
  --quay-auth <quay-auth-file>
```

**Custom operator:**
```bash
./deploy-operator.sh \
  --fbc-tag <custom-fbc-tag> \
  --quay-auth <quay-auth-file>
```

### Disconnected Cluster Commands

**Predefined operator:**
```bash
./deploy-operator.sh \
  --operator <sriov|metallb|nmstate|ptp|pfstatus> \
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
oc delete imagedigestmirrorset sriov-art-idms
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

**Script Version**: 2.0  
**Last Updated**: January 2025  
**Supported OCP Versions**: 4.10+
