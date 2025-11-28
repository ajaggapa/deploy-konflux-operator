# Operator Deployment Script - Usage Guide

This script deploys Konflux-built operators on both **connected** and **disconnected** OpenShift clusters with metadata extracted from FBC image.

---
## Table of Contents
- [Prerequisites](#prerequisites)
- [Procedure](#procedure)
- [Arguments](#arguments)
- [Usage](#usage)

---

## Connected Cluster Image Flow

```
┌───────────────────────────────────────────────────────────────────────────┐
│                          INTERNET (Quay.io)                               │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌──────────────────────────────────┐   ┌───────────────────────────────┐ │
│  │  Quay FBC Repository             │   │  Quay ART Images Repository   │ │
│  │  quay.io/.../art-fbc             │   │  quay.io/.../art-images-share │ │
│  │                                  │   │                               │ │
│  │  🌐 PUBLIC (no auth needed)      │   │  🔒 PRIVATE (auth required)   │ │
│  │                                  │   │     Uses: --quay-auth         │ │
│  │  • FBC Images (contains          │   │                               │ │
│  │    relatedImages metadata):      │   │  • Operator Images:           │ │
│  │    ocp__4.20__sriov-operator     │   │    @sha256:abc123...          │ │
│  │    ocp__4.20__metallb-operator   │   │    @sha256:def456...          │ │
│  └──────────────────────────────────┘   └───────────────────────────────┘ │
│           │                                        │                      │
│           │ ① Script reads                         │ ③ Cluster pulls     │
│           │    FBC directly                        │    images directly   │
│           │    (no mirroring)                      │    when needed       │
│           │                                        │                      │
└───────────┼────────────────────────────────────────┼──────────────────────┘
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
```

---

## Disconnected Cluster Image Flow

```
┌───────────────────────────────────────────────────────────────────────────┐
│                          INTERNET (Quay.io)                               │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌──────────────────────────────────┐   ┌───────────────────────────────┐ │
│  │  Quay FBC Repository             │   │  Quay ART Images Repository   │ │
│  │  quay.io/.../art-fbc             │   │  quay.io/.../art-images-share │ │
│  │                                  │   │                               │ │
│  │  🌐 PUBLIC (no auth needed)      │   │  🔒 PRIVATE (auth required)   │ │
│  │                                  │   │     Uses: --quay-auth         │ │
│  │  • FBC Images (contains          │   │                               │ │
│  │    relatedImages metadata):      │   │  • Operator Images:           │ │
│  │    ocp__4.20__sriov-operator     │   │    @sha256:abc123...          │ │
│  │    ocp__4.20__metallb-operator   │   │    @sha256:def456...          │ │
│  └──────────────────────────────────┘   └───────────────────────────────┘ │
│           │                                        │                      │
└───────────┼────────────────────────────────────────┼──────────────────────┘
            │                                        │
            │ ① Script pulls & mirrors              │ ② Script extracts
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
│  │  ┌────────────────────────────────────────────────────────────┐   │  │
│  │  │ ImageDigestMirrorSets (IDMS) - Per Operator                │   │  │
│  │  │                                                            │   │  │
│  │  │  sriov-internal-idms:                                      │   │  │
│  │  │    source: registry.redhat.io/openshift4/ose-sriov-*       │   │  │
│  │  │    mirrors: registry.local:5000/.../art-images-share       │   │  │
│  │  │                                                            │   │  │
│  │  │  metallb-internal-idms:                                    │   │  │
│  │  │    source: registry.redhat.io/openshift4/metallb-*         │   │  │
│  │  │    mirrors: registry.local:5000/.../art-images-share       │   │  │
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
│  │  │    registry.local:5000/.../art-images-share@sha256:abc123  │   │  │
│  │  │                                                            │   │  │
│  │  │  ✓ Image pulled from internal registry                     │   │  │
│  │  └────────────────────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```
---

## Prerequisites

- **oc** - OpenShift CLI
- **opm** - Operator Package Manager
- **jq** - JSON processor  
- **podman** - Container tool for authentication

---

## Procedure

The script follows these steps when deploying an operator:

1. **Authenticate to registries** - Validates Quay.io and internal registry credentials
2. **Mirror FBC images** (Disconnected only) - Copies FBC images to internal registry
3. **Extract metadata** - Reads operator details (name, namespace, channel, install mode) from FBC
4. **Mirror related images** (Disconnected only) - Copies all operator container images to internal registry
5. **Update cluster pull-secret** (Connected only) - Adds Quay.io credentials to cluster
6. **Configure insecure registry** (Disconnected only) - Adds internal registry to cluster configuration
7. **Create IDMS** - Sets up image redirect rules (one per operator)
8. **Wait for MCP update** - Waits for cluster nodes to apply new configuration (once for all operators)
9. **Create CatalogSource** - Registers operator catalog
10. **Create Namespace** - Creates operator namespace
11. **Create OperatorGroup** - Configures operator deployment scope
12. **Create Subscription** - Initiates operator installation
13. **Wait for CSV** - Waits for ClusterServiceVersion to be created
14. **Wait for operator pods** - Waits for all operator pods to be ready

---

## Arguments

| Argument | Description | Required |
|----------|-------------|----------|
| `--operator <name>` | Operator to deploy: `sriov`, `metallb`, `nmstate`, `ptp`, `pfstatus`, `local-storage`. Supports comma-separated list: `sriov,metallb,nmstate` | Yes* |
| `--fbc-tag <tags>` | Custom FBC image tag(s). Alternative to `--operator` for advanced usage. Supports comma-separated list for multiple tags (e.g., `ocp__4.20__metallb-rhel9-operator,ocp__4.20__ose-sriov-network-rhel9-operator`) | Yes* |
| `--internal-registry <host:port>` | Internal registry location (enables disconnected mode) | No |
| `--internal-registry-auth <file>` | Auth file for internal registry (required if `--internal-registry` is set) | Conditional |
| `--quay-auth <file>` | Quay.io authentication file | Conditional |
| `--mcp-timeout <duration>` | Timeout duration for MachineConfigPool updates (e.g., `600s`). Default: `600s` | No |

**Notes:**
- **Either** `--operator` **or** `--fbc-tag` is required (not both)
- Valid operators: `sriov`, `metallb`, `nmstate`, `ptp`, `pfstatus`, `local-storage`
- Disconnected mode requires both `--internal-registry` and `--internal-registry-auth`
- Script automatically detects mode based on `--internal-registry` presence
- `--quay-auth` is required for disconnected mode, optional for connected mode if cluster's pull-secret already contains auth for quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share repository
- For larger clusters, consider increasing `--mcp-timeout` if node updates take longer (e.g., `--mcp-timeout 1200s`)

**Environment Variables:**
- `KONFLUX_DEPLOY_OPERATORS=false` - Skip all operator deployments entirely
- `KONFLUX_DEPLOY_CATALOG_SOURCE=false` - Skip CatalogSource creation only
- `KONFLUX_DEPLOY_SUBSCRIPTION=false` - Skip Subscription creation only (useful for deploying catalog without installing operators)


---

## Usage

### Connected Cluster

**Predefined Telco Operators:**
```bash
# Single operator (with quay-auth)
./deploy-operator.sh \
  --operator sriov \
  --quay-auth /path/to/quay-auth.json

# Single operator (using cluster's existing pull-secret auth)
./deploy-operator.sh \
  --operator sriov

# Multiple operators
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --quay-auth /path/to/quay-auth.json
```

**Custom FBC Tag:**
```bash
# Single FBC tag (with quay-auth)
./deploy-operator.sh \
  --fbc-tag ocp__4.20__metallb-rhel9-operator \
  --quay-auth /path/to/quay-auth.json

# Single FBC tag (using cluster's existing pull-secret auth)
./deploy-operator.sh \
  --fbc-tag ocp__4.20__metallb-rhel9-operator

# Multiple FBC tags (comma-separated)
./deploy-operator.sh \
  --fbc-tag ocp__4.20__metallb-rhel9-operator,ocp__4.20__ose-sriov-network-rhel9-operator \
  --quay-auth /path/to/quay-auth.json
```

**Custom MCP Timeout (for larger clusters):**
```bash
./deploy-operator.sh \
  --operator sriov,metallb \
  --quay-auth /path/to/quay-auth.json \
  --mcp-timeout 1200s
```

---

### Disconnected Cluster

**Predefined Telco Operators:**
```bash
# Single operator
./deploy-operator.sh \
  --operator sriov \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json

# Multiple operators
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json
```

**Custom FBC Tag:**
```bash
# Single FBC tag
./deploy-operator.sh \
  --fbc-tag ocp__4.21__ose-sriov-network-rhel9-operator \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json

# Multiple FBC tags (comma-separated)
./deploy-operator.sh \
  --fbc-tag ocp__4.21__ose-sriov-network-rhel9-operator,ocp__4.21__metallb-rhel9-operator \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json
```

**Custom MCP Timeout (for larger clusters):**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,ptp \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json \
  --mcp-timeout 20m
```

---
