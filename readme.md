# Operator Deployment Script - Usage Guide

This script deploys Konflux-built operators on both **connected** and **disconnected** OpenShift clusters with automatic metadata extraction and intelligent mode detection.

---

## Connected Cluster Image Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          INTERNET (Quay.io)                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────────────────────┐   ┌─────────────────────────────┐ │
│  │  Quay FBC Repository             │   │  Quay ART Images Repository │ │
│  │  quay.io/.../art-fbc             │   │  quay.io/.../art-images-    │ │
│  │                                  │   │         share               │ │
│  │  🌐 PUBLIC (no auth needed)      │   │  🔒 PRIVATE (auth required)  │ │
│  │                                  │   │     Uses: --quay-auth       │ │
│  │  • FBC Images (contains          │   │                             │ │
│  │    relatedImages metadata):      │   │  • Operator Images:         │ │
│  │    ocp__4.20__sriov-operator     │   │    @sha256:abc123...        │ │
│  │    ocp__4.20__metallb-operator   │   │    @sha256:def456...        │ │
│  │    ocp__4.20__nmstate-operator   │   │    @sha256:ghi789...        │ │
│  │    ... etc                       │   │    ... (hundreds of images) │ │
│  └──────────────────────────────────┘   └─────────────────────────────┘ │
│           │                                        │                    │
│           │ ① Script reads                         │ ③ Cluster pulls   │
│           │    FBC directly                        │    images directly │
│           │    (no mirroring)                      │    when needed     │
│           │                                        │                    │
└───────────┼────────────────────────────────────────┼────────────────────┘
            │                                        │
            │                                        │
            ▼                                        │
┌─────────────────────────────────────────────────────────────────────────┐
│                    CONNECTED CLUSTER ENVIRONMENT                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    OpenShift Cluster                              │  │
│  │                                                                   │  │
│  │  ② Script updates cluster pull-secret with --quay-auth           │  │
│  │     credentials                                                   │  │
│  │                                                                   │  │
│  │  ┌────────────────────────────────────────────────────────────┐   │  │
│  │  │ ImageDigestMirrorSets (IDMS) - Per Operator                │   │  │
│  │  │                                                            │   │  │
│  │  │  sriov-art-idms:                                           │   │  │
│  │  │    source: registry.redhat.io/openshift4/ose-sriov-*       │   │  │
│  │  │    mirrors: quay.io/.../art-images-share                   │   │  │
│  │  │                                                            │   │  │
│  │  │  metallb-art-idms:                                         │   │  │
│  │  │    source: registry.redhat.io/openshift4/metallb-*         │   │  │
│  │  │    mirrors: quay.io/.../art-images-share                   │   │  │
│  │  │                                                            │   │  │
│  │  │  [... nmstate, ptp, pfstatus IDMS ...]                     │   │  │
│  │  └────────────────────────────────────────────────────────────┘   │  │
│  │                                │                                  │  │
│  │                                │ ④ When pod needs image          │  │
│  │                                ▼                                  │  │
│  │  ┌────────────────────────────────────────────────────────────┐   │  │
│  │  │                  CRI-O / Image Pull Flow                   │   │  │
│  │  │                                                            │   │  │
│  │  │  Pod requests:                                             │   │  │
│  │  │    registry.redhat.io/openshift4/ose-sriov@sha256:abc123   │   │  │
│  │  │                                                            │   │  │
│  │  │  IDMS redirects to:                                        │   │  │
│  │  │    quay.io/.../art-images-share@sha256:abc123 ──────       ┼   ┼  ┤
│  │  │                                                            │   │  │
│  │  │  ✓ Image pulled from Quay.io using cluster pull-secret     │   │  │
│  │  └────────────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

Legend:
  ① FBC Usage          - Script references FBC images directly from Quay.io (no mirroring)
  ② Pull-Secret Update - Script merges --quay-auth into cluster pull-secret
  ③ Direct Access      - Cluster pulls images directly from Quay.io (no mirroring needed)
  ④ Runtime Redirect   - IDMS redirects image pulls to Quay.io ART repository
```

---

## Disconnected Cluster Image Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          INTERNET (Quay.io)                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────────────────────┐   ┌─────────────────────────────┐ │
│  │  Quay FBC Repository             │   │  Quay ART Images Repository │ │
│  │  quay.io/.../art-fbc             │   │  quay.io/.../art-images-    │ │
│  │                                  │   │         share               │ │
│  │  🌐 PUBLIC (no auth needed)      │   │  🔒 PRIVATE (auth required)  │ │
│  │                                  │   │     Uses: --quay-auth       │ │
│  │  • FBC Images (contains          │   │                             │ │
│  │    relatedImages metadata):      │   │  • Operator Images:         │ │
│  │    ocp__4.20__sriov-operator     │   │    @sha256:abc123...        │ │
│  │    ocp__4.20__metallb-operator   │   │    @sha256:def456...        │ │
│  │    ocp__4.20__nmstate-operator   │   │    @sha256:ghi789...        │ │
│  │    ... etc                       │   │    ... (hundreds of images) │ │
│  └──────────────────────────────────┘   └─────────────────────────────┘ │
│           │                                        │                    │
└───────────┼────────────────────────────────────────┼────────────────────┘
            │                                        │
            │ ① Script pulls & mirrors               │ ② Script extracts
            │    FBC images (5 images)               │    relatedImages from FBC
            │                      │                 │    and mirrors ONLY those
            │                      └─────────────────┤    (26 unique images)
            ▼                                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    AIR-GAPPED ENVIRONMENT                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │              Internal Registry (registry.local:5000)              │  │
│  │  /redhat-user-workloads/ocp-art-tenant/                           │  │
│  │                                                                   │  │
│  │  ├─ art-fbc/                      ├─ art-images-share/            │  │
│  │  │   • ocp__4.20__sriov-operator  │   • @sha256:abc123...         │  │
│  │  │   • ocp__4.20__metallb-op...   │   • @sha256:def456...         │  │
│  │  │   • ocp__4.20__nmstate-op...   │   • @sha256:ghi789...         │  │
│  │  │   • ocp__4.20__ptp-operator    │   • ... (all 26 images)       │  │
│  │  │   • ocp__4.20__pfstatus-op...  │                               │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                │                                        │
│                                │ ③ Script references mirrored images   │
│                                │    when creating IDMS                  │
│                                ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    OpenShift Cluster                              │  │
│  │                                                                   │  │
│  │  ┌────────────────────────────────────────────────────────────┐  │  │
│  │  │ ImageDigestMirrorSets (IDMS) - Per Operator                │  │  │
│  │  │                                                            │  │  │
│  │  │  sriov-internal-idms:                                      │  │  │
│  │  │    source: registry.redhat.io/openshift4/ose-sriov-*       │  │  │
│  │  │    mirrors: registry.local:5000/.../art-images-share       │  │  │
│  │  │                                                            │  │  │
│  │  │  metallb-internal-idms:                                    │  │  │
│  │  │    source: registry.redhat.io/openshift4/metallb-*         │  │  │
│  │  │    mirrors: registry.local:5000/.../art-images-share       │  │  │
│  │  │                                                            │  │  │
│  │  │  [... nmstate, ptp, pfstatus IDMS ...]                     │  │  │
│  │  └────────────────────────────────────────────────────────────┘  │  │
│  │                                │                                 │  │
│  │                                │ ④ When pod needs image         │  │
│  │                                ▼                                 │  │
│  │  ┌────────────────────────────────────────────────────────────┐  │  │
│  │  │                  CRI-O / Image Pull Flow                   │  │  │
│  │  │                                                            │  │  │
│  │  │  Pod requests:                                             │  │  │
│  │  │    registry.redhat.io/openshift4/ose-sriov@sha256:abc123   │  │  │
│  │  │                                                            │  │  │
│  │  │  IDMS redirects to:                                        │  │  │
│  │  │    registry.local:5000/.../art-images-share@sha256:abc123  │  │  │
│  │  │                                                            │  │  │
│  │  │  ✓ Image pulled from internal registry                     │  │  │
│  │  └────────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘

Legend:
  ① FBC Mirroring      - Script mirrors catalog images (one per operator)
  ② Related Images     - Script reads relatedImages from FBC, then mirrors ONLY those 
                         specific images (deduplicated across all operators)
  ③ IDMS Creation      - Script creates image redirect rules per operator
  ④ Runtime Redirect   - IDMS transparently redirects image pulls to internal registry
```

---

## Table of Contents
- [Prerequisites](#prerequisites)
- [Script Modes](#script-modes)
- [Arguments](#arguments)
- [Multiple Operators Deployment](#multiple-operators-deployment)
- [Connected Cluster Examples](#connected-cluster-examples)
- [Disconnected Cluster Examples](#disconnected-cluster-examples)
- [Authentication Files](#authentication-files)
- [Features](#features)
- [Error Handling](#error-handling)
- [Error Examples](#error-examples)
- [Quick Reference](#quick-reference)
- [Cleanup Commands](#cleanup-commands)
- [Version Information](#version-information)

---

## Prerequisites

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

---

### Disconnected Cluster Mode
For air-gapped clusters without direct quay.io access:

**What happens:**
- ✅ Mirrors FBC image to internal registry
- ✅ Mirrors all related operator images to internal registry
- ✅ Configures internal registry as insecure
- ✅ Creates IDMS mapping to internal registry
- ✅ Waits for MCP updates to complete
- ❌ NO cluster pull-secret modification

**Usage:**
```bash
./deploy-operator.sh \
  --operator <name> \
  --internal-registry <host:port> \
  --internal-registry-auth <auth-file> \
  --quay-auth <quay-auth-file>
```

---

## Arguments

| Argument | Description | Required |
|----------|-------------|----------|
| `--operator <name>` | Operator to deploy: `sriov`, `metallb`, `nmstate`, `ptp`, `pfstatus`. Supports comma-separated list: `sriov,metallb,nmstate` | Yes |
| `--internal-registry <host:port>` | Internal registry location (enables disconnected mode) | No |
| `--internal-registry-auth <file>` | Auth file for internal registry (required if `--internal-registry` is set) | Conditional |
| `--quay-auth <file>` | Quay.io authentication file | Yes |

**Notes:**
- Multiple operators (`--operator sriov,metallb,nmstate`) only work with the `--operator` flag
- Valid operators: `sriov`, `metallb`, `nmstate`, `ptp`, `pfstatus`
- Disconnected mode requires both `--internal-registry` and `--internal-registry-auth`
- Script automatically detects mode based on `--internal-registry` presence

---

## Multiple Operators Deployment

### Syntax
```bash
./deploy-operator.sh --operator sriov,metallb,nmstate,ptp,pfstatus [other-args...]
```

### How It Works

1. **Parallel FBC Processing**: Script processes FBC metadata for all operators simultaneously
2. **Deduplication**: Collects `relatedImages` from all operators and removes duplicates
3. **Bulk Mirroring**: Mirrors unique images once (e.g., 26 images instead of 30 with duplicates)
4. **Batch IDMS Creation**: Creates separate IDMS for each operator, applies all at once
5. **Single MCP Wait**: Waits for MachineConfigPool update only once after all IDMS applied
6. **Sequential Deployment**: Deploys operators one by one
7. **Continue on Failure**: If one operator fails, continues with remaining operators
8. **Summary Report**: Shows success/failure status for all operators at the end

### Benefits
- **Time Savings**: Single MCP wait instead of one per operator (~5-10 minutes saved per operator)
- **Efficient Mirroring**: Deduplicates images across operators
- **Resilient**: Continues deploying even if one operator fails
- **Clear Reporting**: Shows exactly which operators succeeded/failed

### Examples

**Connected Mode:**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate \
  --quay-auth /path/to/quay-auth.json
```

**Disconnected Mode:**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json
```

### Example Output (Success)
```
Mode: Disconnected cluster
Detected OCP version: 4.21

Processing 5 operators: sriov metallb nmstate ptp pfstatus
...

Mirroring related images...
  [1/26] Mirroring sha256:abc123...
    ✓ Success
  [2/26] Mirroring sha256:def456...
    ✓ Success
  ...
Successfully mirrored all 26 images

Generating IDMS for each operator...
  Generating IDMS: sriov-internal-idms
  Generating IDMS: metallb-internal-idms
  ...

Applying all IDMS to cluster...
  Applying IDMS: sriov-internal-idms
  Applying IDMS: metallb-internal-idms
  ...

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
  Waiting for CSV sriov-operator.v4.21.0-202510151152...
  Waiting for operator pods...
  ✓ Operator sriov deployed successfully

...

============================================================
Deployment Summary
============================================================
Successfully deployed (5): sriov metallb nmstate ptp pfstatus

All operators deployed successfully!
============================================================
```

### Example Output (With Failure)
```
============================================================
Deployment Summary
============================================================
Successfully deployed (3): sriov metallb nmstate
Failed to deploy (2): ptp pfstatus

Deployment completed with errors!
============================================================
```

---

## Connected Cluster Examples

### Deploy Single Operator
```bash
./deploy-operator.sh \
  --operator sriov \
  --quay-auth /root/quay-auth.json
```

### Deploy Multiple Operators
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate \
  --quay-auth /root/quay-auth.json
```

**Expected Flow:**
1. Script detects connected mode (no `--internal-registry`)
2. Updates cluster pull-secret with quay.io credentials
3. Processes FBC metadata for all operators
4. Creates IDMS per operator (mapping `registry.redhat.io` → `quay.io`)
5. Applies all IDMS
6. Waits for MCP update once
7. Deploys operators sequentially

---

## Disconnected Cluster Examples

### Deploy Single Operator
```bash
./deploy-operator.sh \
  --operator metallb \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /root/internal-auth.json \
  --quay-auth /root/quay-auth.json
```

### Deploy Multiple Operators
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /root/internal-auth.json \
  --quay-auth /root/quay-auth.json
```

**Expected Flow:**
1. Script detects disconnected mode (`--internal-registry` provided)
2. Mirrors FBC images to internal registry for all operators
3. Extracts `relatedImages` from all FBC catalogs
4. Deduplicates images across operators
5. Mirrors unique images to internal registry
6. Configures internal registry as insecure
7. Creates IDMS per operator (mapping `registry.redhat.io` → internal registry)
8. Applies all IDMS
9. Waits for MCP update once
10. Deploys operators sequentially

---

## Authentication Files

Authentication files should be in Docker/Podman JSON format:

### Single Registry Example
```json
{
  "auths": {
    "quay.io": {
      "auth": "base64-encoded-credentials"
    }
  }
}
```

### Multiple Registries in One File
```json
{
  "auths": {
    "quay.io": {
      "auth": "base64-general-quay-credentials"
    },
    "quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share": {
      "auth": "base64-specific-repo-credentials"
    },
    "registry.example.com:5000": {
      "auth": "base64-internal-registry-credentials"
    }
  }
}
```

**Smart Credential Selection:**
The script automatically selects the most specific credentials:
- If auth file has both `quay.io` and `quay.io/redhat-user-workloads/...`, it uses the repository-specific credentials
- Displays which credentials are being used during execution

---

## Features

### 1. Smart Quay.io Authentication

**Priority-based Credential Selection:**
- Script checks for repository-specific credentials first (`quay.io/redhat-user-workloads/...`)
- Falls back to general domain credentials (`quay.io`) if specific ones not found
- Displays which credentials are being used:
  ```
  Using Quay.io auth for: quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share
  ```

### 2. Automatic Metadata Extraction
- **Operator Name**: From bundle's `metadata.name`
- **Namespace**: From FBC annotation `operatorframework.io/suggested-namespace`
- **Channel**: From FBC default channel
- **Install Mode**: From CSV's `installModes` (`AllNamespaces` or `OwnNamespace`)
- **Bundle Version**: Latest bundle from sorted list

### 3. Intelligent Mode Detection
Script auto-detects mode based on arguments:
- **Connected Mode**: When `--internal-registry` is NOT provided
- **Disconnected Mode**: When `--internal-registry` IS provided

### 4. Multiple Operator Support
- Deploy multiple operators in one command
- Deduplicates images across operators
- Single MCP wait for all operators
- Continues on individual operator failures
- Summary report of successes and failures

### 5. Insecure Registry Handling (Disconnected Mode)
- Automatically adds internal registry to `registries.conf`
- Patches `image.config.openshift.io` with insecure registry
- Waits for MachineConfigPool to reconcile

### 6. Error Handling
Robust error checking at every step with clear error messages.

---

## Error Handling

The script has two distinct error handling behaviors:

### Pre-deployment Validation
The script exits immediately if:
- Required arguments are missing
- Authentication fails to Quay.io or internal registry
- Invalid operator name provided
- Image mirroring fails (disconnected mode)
- IDMS creation/application fails
- MachineConfigPool update fails

**Behavior**: Script terminates and returns non-zero exit code.

### Operator Deployment
When deploying multiple operators, the script:
- **Continues** deploying remaining operators if one fails
- **Tracks** which operators succeeded and which failed
- **Reports** a summary at the end:
  ```
  Successfully deployed (3): sriov metallb nmstate
  Failed to deploy (2): ptp pfstatus
  ```
- **Exits** with code 1 if any operator failed, 0 if all succeeded

**Behavior**: Script completes all deployments, provides summary, then exits with appropriate code.

---

## Error Examples

### Invalid Operator Name (Single)
```bash
./deploy-operator.sh --operator invalid-op --quay-auth /root/quay-auth.json

ERROR: Invalid operator name 'invalid-op'
Valid operators: sriov, metallb, nmstate, ptp, pfstatus
```

### Invalid Operator in List
```bash
./deploy-operator.sh --operator sriov,invalid,metallb --quay-auth /root/quay-auth.json

ERROR: Invalid operator 'invalid' in list
Valid operators: sriov, metallb, nmstate, ptp, pfstatus
```

### Missing Internal Registry Auth
```bash
./deploy-operator.sh --operator sriov --internal-registry registry.example.com:5000 --quay-auth /root/quay-auth.json

ERROR: --internal-registry-auth is required when using --internal-registry
```

### Quay.io Authentication Failure
```bash
./deploy-operator.sh --operator sriov --quay-auth /root/invalid-auth.json

ERROR: Failed to authenticate to quay.io. Check your credentials in /root/invalid-auth.json
```

---

## Quick Reference

### Single operator

**Connected cluster:**
```bash
./deploy-operator.sh --operator sriov --quay-auth /path/to/quay-auth.json
```

**Disconnected cluster:**
```bash
./deploy-operator.sh \
  --operator sriov \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json
```

### Multiple operators

**Connected cluster:**
```bash
./deploy-operator.sh --operator sriov,metallb,nmstate --quay-auth /path/to/quay-auth.json
```

**Disconnected cluster:**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json
```

---

## Cleanup Commands

### Remove Single Operator
```bash
# Delete operator namespace
oc delete namespace openshift-sriov-network-operator

# Delete CatalogSource
oc delete catalogsource konflux-sriov-catalog -n openshift-marketplace

# Delete IDMS
oc delete imagedigestmirrorset sriov-internal-idms  # or sriov-art-idms for connected
```

### Bulk Cleanup for Multiple Operators
```bash
# Delete all operator namespaces
for op in sriov metallb nmstate ptp pfstatus; do
  case $op in
    sriov) ns="openshift-sriov-network-operator" ;;
    metallb) ns="metallb-system" ;;
    nmstate) ns="openshift-nmstate" ;;
    ptp) ns="openshift-ptp" ;;
    pfstatus) ns="openshift-pfstatus" ;;
  esac
  oc delete namespace $ns --ignore-not-found
done

# Delete all CatalogSources
oc delete catalogsource konflux-sriov-catalog -n openshift-marketplace --ignore-not-found
oc delete catalogsource konflux-metallb-catalog -n openshift-marketplace --ignore-not-found
oc delete catalogsource konflux-nmstate-catalog -n openshift-marketplace --ignore-not-found
oc delete catalogsource konflux-ptp-catalog -n openshift-marketplace --ignore-not-found
oc delete catalogsource konflux-pfstatus-catalog -n openshift-marketplace --ignore-not-found

# Delete all IDMS (choose based on your mode)
# For disconnected:
oc delete imagedigestmirrorset sriov-internal-idms --ignore-not-found
oc delete imagedigestmirrorset metallb-internal-idms --ignore-not-found
oc delete imagedigestmirrorset nmstate-internal-idms --ignore-not-found
oc delete imagedigestmirrorset ptp-internal-idms --ignore-not-found
oc delete imagedigestmirrorset pfstatus-internal-idms --ignore-not-found

# For connected:
oc delete imagedigestmirrorset sriov-art-idms --ignore-not-found
oc delete imagedigestmirrorset metallb-art-idms --ignore-not-found
oc delete imagedigestmirrorset nmstate-art-idms --ignore-not-found
oc delete imagedigestmirrorset ptp-art-idms --ignore-not-found
oc delete imagedigestmirrorset pfstatus-art-idms --ignore-not-found
```

---

## Version Information

**Version**: 3.0  
**Last Updated**: October 2025

### What's New in v3.0
- ✅ Multiple operators deployment support (`--operator sriov,metallb,nmstate`)
- ✅ Smart credential selection from auth files (repository-specific vs general domain)
- ✅ Credential visibility (displays which auth is being used)
- ✅ Image deduplication across operators
- ✅ Single MCP wait for all operators
- ✅ Batch IDMS creation and application
- ✅ Continue-on-failure for operator deployments
- ✅ Deployment summary reporting
- ✅ Operator validation against predefined list
- ✅ Enhanced error messages and debugging output
