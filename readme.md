# Operator Deployment Script - Usage Guide

This script deploys Konflux-built operators on **connected** and **disconnected** OpenShift clusters using metadata extracted from an FBC image.

---

## Table of Contents

- [Connected Cluster Image Flow](#connected-cluster-image-flow)
- [Disconnected Cluster Image Flow (Mirror Mode)](#disconnected-cluster-image-flow-mirror-mode)
- [Disconnected Cluster Image Flow (Proxy Mode)](#disconnected-cluster-image-flow-proxy-mode)
- [Existing Mirror Configuration](#existing-mirror-configuration)
- [Prerequisites](#prerequisites)
- [Procedure](#procedure)
- [Arguments](#arguments)
- [Usage](#usage)
- [Dry-Run Planning](#dry-run-planning)

---

## Connected Cluster Image Flow

The FBC image stays at `quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:<tag>`. Its related image references use `registry.redhat.io/<repository>@sha256:<digest>`. The script creates one IDMS for the cluster:

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: stage-idms
spec:
  imageDigestMirrors:
    - mirrors:
        - registry.stage.redhat.io
      source: registry.redhat.io
```

When a pod requests a related image from `registry.redhat.io`, the IDMS directs the pull to `registry.stage.redhat.io` with the same repository path and digest. Stage pulls require registry credentials in the cluster pull-secret. Supply them with `--registry-auth` if they are not already present. The script does not copy related images in connected mode.

## Disconnected Cluster Image Flow (Mirror Mode)

With `--internal-registry`, the script copies each FBC image to `${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-fbc:<tag>`. It reads the related images from the FBC and mirrors each unique image reference from the stage registry into the same repository path in the internal registry:

```text
Original: registry.redhat.io/openshift4/ose-metallb-operator-bundle@sha256:<digest>
Mirror source: registry.stage.redhat.io/openshift4/ose-metallb-operator-bundle@sha256:<digest>
Mirror target: ${INTERNAL_REGISTRY}/openshift4/ose-metallb-operator-bundle
```

The script requires each related image reference to start with `registry.redhat.io/` and end with a SHA-256 digest. It then creates one IDMS so cluster pulls use the copied images:

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: internal-idms
spec:
  imageDigestMirrors:
    - mirrors:
        - ${INTERNAL_REGISTRY}
      source: registry.redhat.io
```

`--registry-auth` is required to pull the stage images, and `--internal-registry-auth` supplies credentials for the destination registry. The FBC image does not require `--registry-auth`. The script excludes any `art-images-share` credentials when merging the auth files for mirroring.

## Disconnected Cluster Image Flow (Proxy Mode)

With `--internal-registry-proxy`, the script does not copy images. It points the FBC image to `${INTERNAL_REGISTRY_PROXY}/redhat-user-workloads/ocp-art-tenant/art-fbc:<tag>` and creates one `internal-idms` that maps `registry.redhat.io` to `${INTERNAL_REGISTRY_PROXY}`. A related image pull therefore keeps its path and digest under the proxy host:

```text
registry.redhat.io/openshift4/ose-metallb-operator-bundle@sha256:<digest>
  -> ${INTERNAL_REGISTRY_PROXY}/openshift4/ose-metallb-operator-bundle@sha256:<digest>
```

The proxy must serve both the Quay FBC path and the stage related image paths, including authenticated stage pulls. Its upstream routing and stage credentials are configured outside this repository; verify both before using proxy mode.

## Existing Mirror Configuration

The script leaves existing per-operator IDMS resources in place. Their mappings can still affect image pulls on clusters where earlier versions of the script ran. Check the effective mirror for related images before relying on the new IDMS.

---

## Prerequisites

- **oc** - OpenShift CLI
- **opm** - Operator Package Manager
- **jq** - JSON processor
- **podman** - Container tool for authentication in disconnected mirror mode

---

## Procedure

The script follows these steps when deploying an operator:

1. **Validate inputs and cluster access** - Checks tools, auth files, and the OpenShift version.
2. **Authenticate** - Logs in to the internal registry in mirror mode and uses `--registry-auth` for stage pulls. In connected mode, merges supplied stage credentials into the cluster pull-secret; proxy mode merges proxy credentials.
3. **Mirror FBC images** (disconnected mirror mode only) - Copies FBC images to the internal registry.
4. **Extract metadata** - Reads operator details and related image references from the FBC.
5. **Mirror related images** (disconnected mirror mode only) - Copies the stage images by digest into matching repository paths in the internal registry.
6. **Create IDMS** - Applies one registry-level mapping to stage, the internal registry, or the proxy according to the mode.
7. **Wait for cluster configuration** - Waits for the Machine Config Pool, configures the disconnected registry as insecure, and waits again.
8. **Deploy operators** - Creates CatalogSources, Namespaces, OperatorGroups, and Subscriptions, then waits for CSVs and pods. The CatalogSource and Subscription steps can be disabled with environment variables.
9. **Clean up legacy credentials** - After successful subscription deployment, removes the `art-images-share` entry from the cluster pull-secret if present.

---

## Arguments

| Argument | Description | Required |
|----------|-------------|----------|
| `--operator <name>` | Operator to deploy: `sriov`, `metallb`, `nmstate`, `ptp`, `pfstatus`, `local-storage`, `ingress-node-firewall`. Supports comma-separated list: `sriov,metallb,nmstate` | Yes* |
| `--fbc-tag <tags>` | Custom FBC image tag(s). Alternative to `--operator` for advanced usage. Supports comma-separated list for multiple tags (e.g., `ocp__4.20__metallb-rhel9-operator,ocp__4.20__ose-sriov-network-rhel9-operator`) | Yes* |
| `--internal-registry <host:port>` | Internal registry location for **mirror mode** (enables disconnected mode with image mirroring) | No |
| `--internal-registry-auth <file>` | Auth file for internal registry (required if `--internal-registry` is set) | Conditional |
| `--internal-registry-proxy <host:port>` | Internal registry proxy for **proxy mode** (enables disconnected mode without image mirroring) | No |
| `--internal-registry-proxy-auth <file>` | Auth file for internal registry proxy (required if `--internal-registry-proxy` is set) | Conditional |
| `--registry-auth <file>` | Stage registry auth file; required for disconnected mirror mode, or for connected mode when the cluster pull-secret lacks stage credentials | Conditional |
| `--mcp-timeout <duration>` | Timeout duration for MachineConfigPool updates (e.g., `600s`). Default: `600s` | No |

**Notes:**
- **Either** `--operator` **or** `--fbc-tag` is required (not both)
- Valid operators: `sriov`, `metallb`, `nmstate`, `ptp`, `pfstatus`, `local-storage`, `ingress-node-firewall`
- **Disconnected mirror mode** requires `--internal-registry`, `--internal-registry-auth`, and `--registry-auth` (mirrors FBC and related images)
- **Disconnected proxy mode** requires `--internal-registry-proxy` and `--internal-registry-proxy-auth` (no mirroring, images pulled through proxy)
- Cannot use both `--internal-registry` and `--internal-registry-proxy` simultaneously
- The FBC image does not need `--registry-auth`; stage related images do. In connected mode, the cluster pull-secret can already contain the stage credentials. The flag is unused in proxy mode.
- For larger clusters, consider increasing `--mcp-timeout` if node updates take longer (e.g., `--mcp-timeout 1200s`)

**Environment Variables:**
- `KONFLUX_DEPLOY_OPERATORS=false` - Skip all operator deployments entirely
- `KONFLUX_DEPLOY_CATALOG_SOURCE=false` - Skip CatalogSource creation only
- `KONFLUX_DEPLOY_SUBSCRIPTION=false` - Skip Subscription creation only (useful for deploying catalog without installing operators)

---

## Usage

### Connected Cluster

The examples without `--registry-auth` assume the cluster pull-secret already contains credentials for `registry.stage.redhat.io`.

```bash
# Single operator
./deploy-operator.sh --operator sriov

# Multiple operators
./deploy-operator.sh --operator sriov,metallb,nmstate,ptp,pfstatus

# Custom FBC tag
./deploy-operator.sh --fbc-tag ocp__4.20__metallb-rhel9-operator

# Add stage registry credentials to the cluster pull-secret
./deploy-operator.sh \
  --operator sriov \
  --registry-auth /path/to/registry-auth.json
```

---

### Disconnected Cluster - Mirror Mode

```bash
# Single operator
./deploy-operator.sh \
  --operator sriov \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --registry-auth /path/to/registry-auth.json

# Multiple operators
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --registry-auth /path/to/registry-auth.json

# Custom FBC tag
./deploy-operator.sh \
  --fbc-tag ocp__4.21__ose-sriov-network-rhel9-operator \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --registry-auth /path/to/registry-auth.json
```

---

### Disconnected Cluster - Proxy Mode

**Predefined Telco Operators:**
```bash
# Single operator
./deploy-operator.sh \
  --operator sriov \
  --internal-registry-proxy proxy.example.com:5000 \
  --internal-registry-proxy-auth /path/to/internal-proxy-auth.json

# Multiple operators
./deploy-operator.sh \
  --operator sriov,metallb,nmstate,ptp,pfstatus \
  --internal-registry-proxy proxy.example.com:5000 \
  --internal-registry-proxy-auth /path/to/internal-proxy-auth.json
```

**Custom FBC Tag:**
```bash
# Single FBC tag
./deploy-operator.sh \
  --fbc-tag ocp__4.21__ose-sriov-network-rhel9-operator \
  --internal-registry-proxy proxy.example.com:5000 \
  --internal-registry-proxy-auth /path/to/internal-proxy-auth.json

# Multiple FBC tags (comma-separated)
./deploy-operator.sh \
  --fbc-tag ocp__4.21__ose-sriov-network-rhel9-operator,ocp__4.21__metallb-rhel9-operator \
  --internal-registry-proxy proxy.example.com:5000 \
  --internal-registry-proxy-auth /path/to/internal-proxy-auth.json
```

---

### Custom MCP Timeout

**For larger clusters (mirror mode):**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,ptp \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --registry-auth /path/to/registry-auth.json \
  --mcp-timeout 20m
```

**For larger clusters (proxy mode):**
```bash
./deploy-operator.sh \
  --operator sriov,metallb,ptp \
  --internal-registry-proxy proxy.example.com:5000 \
  --internal-registry-proxy-auth /path/to/internal-proxy-auth.json \
  --mcp-timeout 20m
```

---

## Dry-Run Planning

Use `deployment-dry-run.sh` to inspect the deployment plan without changing the cluster. It reads the OpenShift version with `oc` and renders FBC metadata with `opm`, so those tools and `jq` must be available. The helper prints the registry commands and resource manifests, including one registry-level IDMS. In mirror mode, it prints one command per unique related image, pulling from `registry.stage.redhat.io` into the matching internal repository path.

| Argument | Description | Required |
|----------|-------------|----------|
| `--operator <name>` | Same operator list as the deployment script; accepts comma-separated values. | Yes* |
| `--fbc-tag <tags>` | Custom FBC tag(s); mutually exclusive with `--operator`. | Yes* |
| `--internal-registry <host:port>` | Plan disconnected mirror mode. | No |
| `--internal-registry-proxy <host:port>` | Plan disconnected proxy mode. | No |
| `--mcp-timeout <duration>` | MCP wait timeout in the printed commands. Default: `600s`. | No |

Provide either `--operator` or `--fbc-tag`. The registry mode flags are mutually exclusive. Auth file paths in the printed commands are placeholders; the dry-run helper does not read auth files. Supply the corresponding `--registry-auth`, `--internal-registry-auth`, or `--internal-registry-proxy-auth` flags when running `deploy-operator.sh`.

### Dry-run Examples

```bash
# Connected cluster dry run for sriov operator
./deployment-dry-run.sh --operator sriov

# Disconnected dry run with mirror mode
./deployment-dry-run.sh \
  --operator sriov,metallb \
  --internal-registry registry.example.com:5000

# Disconnected dry run with proxy mode
./deployment-dry-run.sh \
  --operator sriov,metallb \
  --internal-registry-proxy proxy.example.com:5000
```

Review the plan, then run `deploy-operator.sh` with the same operator or FBC selection and the required auth flags for the chosen mode.

---
