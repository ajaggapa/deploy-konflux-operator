# 🚀 Konflux Telco Operator Deployment Script

> **Deploy telco operators in disconnected OpenShift clusters!**

This automation script streamlines the deployment of critical telco operators (SR-IOV, MetalLB, nmstate, and PTP) in disconnected OpenShift environments. 

## 🎛️ Supported Operators

- **sriov**
- **metallb** 
- **nmstate**
- **ptp**

## 📋 Prerequisites

- OpenShift 4.20+ cluster in disconnected environment
- `oc` CLI tool installed and configured
- `opm` CLI tool for operator catalog management
- `jq` for JSON processing
- Access to internal container registry
- Authentication files for both internal registry and quay.io
- Administrative privileges on OpenShift cluster

## 🚀 Quick Start

## 📖 Command Line Arguments
####  Currently auth file for both internal registry and quay should be the same. Separate files option will be made feasible later 



| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `--operator` | Telco operator to deploy (`sriov`\|`metallb`\|`nmstate`\|`ptp`) | ✅ | `--operator sriov` |
| `--version` | OpenShift version (determines image tags) | ✅ | `--version 4.20` |
| `--internal-registry` | URL of your internal container registry | ✅ | `--internal-registry registry.example.com:5000` |
| `--internal-registry-auth` | Authentication file for internal registry | ✅ | `--internal-registry-auth /path/to/auth.json` |
| `--quay-auth` | Authentication file for quay.io access | ✅ | `--quay-auth /path/to/quay-auth.json` |
| `--dry-run` | Preview mode - show operations without executing | ❌ | `--dry-run` |

### Basic Deployment
```bash
KUBECONFIG=/path/to/kubeconfig \
./deploy-konflux-operator.sh \
  --operator sriov \
  --version 4.20 \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json
```

### Dry-Run Mode (Preview Only)
```bash
KUBECONFIG=/path/to/kubeconfig \
./deploy-konflux-operator.sh \
  --operator metallb \
  --version 4.20 \
  --internal-registry registry.example.com:5000 \
  --internal-registry-auth /path/to/internal-auth.json \
  --quay-auth /path/to/quay-auth.json \
  --dry-run
```

## 🎯 Usage Examples

### Deploy SR-IOV Operator
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-konflux-operator.sh \
  --operator sriov \
  --version 4.20 \
  --internal-registry registry.hlxcl1.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --quay-auth /home/kni/combined-secret.json
```

### Deploy MetalLB with Dry-Run
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-konflux-operator.sh \
  --operator metallb \
  --version 4.20 \
  --internal-registry registry.hlxcl1.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --quay-auth /home/kni/combined-secret.json \
  --dry-run
```

### Deploy nmstate Operator  
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-konflux-operator.sh \
  --operator nmstate \
  --version 4.20 \
  --internal-registry registry.hlxcl1.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --quay-auth /home/kni/combined-secret.json
```

### Deploy PTP Operator
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-konflux-operator.sh \
  --operator ptp \
  --version 4.20 \
  --internal-registry registry.hlxcl1.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --quay-auth /home/kni/combined-secret.json
```



## 🔄 Deployment Process

The script follows a streamlined 11-step process:

```
Step 0: 🧹 Clean up existing resources
Step 1: 📦 Mirror FBC image to internal registry  
Step 2: 🔍 Extract operator metadata (images, channel, install mode)
Step 3: 🚚 Mirror all related images to internal registry
Step 4: 🎯 Create ImageDigestMirrorSet (IDMS)
Step 5: ⏳ Wait for MachineConfigPool updates (with oc wait)
Step 6: 📋 Create CatalogSource
Step 7: ✅ Verify CatalogSource readiness
Step 8: 🏗️ Create operator namespace
Step 9: 👥 Create OperatorGroup
Step 10: 📝 Create Subscription
Step 11: ⏱️ Wait for CSV installation and final verification
```

## 🎪 Dry-Run Mode Features

Dry-run mode provides complete visibility without making changes:

```bash
# Preview all operations
./deploy-konflux-operator.sh --dry-run [other-args]
```

**What dry-run shows:**
- 📋 All YAML files with **highlighted borders** for easy identification
- 🔧 All `oc` commands with **clear borders** and descriptions
- 🚚 All image mirroring operations
- 📊 **Operator metadata**: channel, install mode, image counts
- ⚙️ Complete deployment plan with real data

- 🎨 **Bordered YAML content** - Easy to copy and distinguish from logs
- 🎯 **Bordered command display** - Clear command separation
- 📈 **Progress indicators** - Shows exactly what would be executed
- 🔍 **Metadata visibility** - Channel and install mode detection results

**What dry-run does NOT do:**
- ❌ Apply any resources to the cluster
- ❌ Mirror any images
- ❌ Modify cluster state

*Note: `opm render` still executes to populate YAMLs with real operator metadata*

