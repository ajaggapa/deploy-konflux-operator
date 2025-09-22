# 🚀 Konflux Telco Operator Deployment Script

> **Deploy telco operators in disconnected OpenShift clusters with confidence!**

This powerful automation script streamlines the deployment of critical telco operators (SR-IOV, MetalLB, nmstate, and PTP) in air-gapped OpenShift environments. Built for production reliability with comprehensive error handling, intelligent cleanup, and advanced monitoring capabilities.

## ✨ Features

🎯 **Smart & Reliable**
- **Intelligent cleanup** - Automatically removes existing installations for clean deployments
- **Fail-fast mirroring** - Exits immediately on image mirror failures
- **Dynamic install mode detection** - Automatically configures `AllNamespaces` vs `OwnNamespace` modes
- **Comprehensive error handling** - Robust monitoring with detailed diagnostics

🔧 **Production-Ready**  
- **Image mirroring** - Mirrors FBC and all related operator images to your internal registry
- **IDMS creation** - Automatically generates ImageDigestMirrorSet for disconnected environments
- **MCP monitoring** - Intelligently waits for MachineConfigPool updates with timeout handling
- **CSV monitoring** - Advanced subscription health monitoring with automatic issue resolution

🎪 **Developer Friendly**
- **Dry-run mode** - Preview all operations without making changes
- **Cross-operator support** - Works seamlessly across all four telco operators  
- **Detailed logging** - Color-coded output with clear success/warning/error messages
- **Flexible configuration** - Dynamic operator-specific settings

## 🎛️ Supported Operators

| Operator | Namespace | Install Mode | Description |
|----------|-----------|--------------|-------------|
| **sriov** | `openshift-sriov-network-operator` | OwnNamespace | SR-IOV Network Operator for hardware acceleration |
| **metallb** | `metallb-system` | AllNamespaces | Load balancer implementation for bare metal |
| **nmstate** | `openshift-nmstate` | OwnNamespace | Declarative network configuration |
| **ptp** | `openshift-ptp` | OwnNamespace | Precision Time Protocol for time synchronization |

## 📋 Prerequisites

- OpenShift 4.20+ cluster in disconnected environment
- `oc` CLI tool installed and configured
- `opm` CLI tool for operator catalog management
- `jq` for JSON processing
- Access to internal container registry
- Authentication files for both internal registry and quay.io

## 🚀 Quick Start

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

## 📖 Command Line Arguments

| Argument | Description | Required | Example |
|----------|-------------|----------|---------|
| `--operator` | Telco operator to deploy (`sriov`\|`metallb`\|`nmstate`\|`ptp`) | ✅ | `--operator sriov` |
| `--version` | OpenShift version (determines image tags) | ✅ | `--version 4.20` |
| `--internal-registry` | URL of your internal container registry | ✅ | `--internal-registry registry.example.com:5000` |
| `--internal-registry-auth` | Authentication file for internal registry | ✅ | `--internal-registry-auth /path/to/auth.json` |
| `--quay-auth` | Authentication file for quay.io access | ✅ | `--quay-auth /path/to/quay-auth.json` |
| `--dry-run` | Preview mode - show operations without executing | ❌ | `--dry-run` |

## 🔄 Deployment Process

The script follows a comprehensive 13-step process:

```
Step 0: 🧹 Clean up existing resources
Step 1: 📦 Mirror FBC image to local registry  
Step 2: 🔍 Extract related images using opm render
Step 3: 🚚 Mirror all related images to local registry
Step 4: 🎯 Create ImageDigestMirrorSet (IDMS)
Step 5: ⏳ Wait for MachineConfigPool updates  
Step 6: 📋 Create CatalogSource
Step 7: ✅ Verify CatalogSource readiness
Step 8: 🏗️ Create operator namespace
Step 9: 👥 Create OperatorGroup (dynamic config)
Step 10: 📝 Create Subscription
Step 11: 🔍 Monitor subscription health
Step 12: ⏱️ Wait for CSV installation
Step 13: 🎉 Final verification and status report
```

## 🎪 Dry-Run Mode Features

Dry-run mode provides complete visibility without making changes:

```bash
# Preview all operations
./deploy-konflux-operator.sh --dry-run [other-args]
```

**What dry-run shows:**
- 📋 All YAML files that would be created
- 🔧 All `oc` commands that would be executed  
- 🚚 All image mirroring operations
- ⚙️ Complete deployment plan with real data

**What dry-run does NOT do:**
- ❌ Apply any resources to the cluster
- ❌ Mirror any images
- ❌ Modify cluster state

*Note: `opm render` still executes to populate YAMLs with real data*

## 🛠️ Advanced Features

### Intelligent Install Mode Detection
The script automatically detects the correct install mode:
- **AllNamespaces**: Creates OperatorGroup with empty spec `{}`
- **OwnNamespace**: Creates OperatorGroup with `targetNamespaces: [operator-namespace]`
- **SingleNamespace**: Same as OwnNamespace

### MCP Timeout Handling
Smart MachineConfigPool monitoring:
- Waits up to 1 minute for MCP updates to start
- If updates start, waits up to 10 minutes for completion  
- If no updates needed, gracefully continues
- Includes 10-minute stabilization period

### Comprehensive Error Handling
- **Image mirror failures**: Script exits immediately with clear error messages
- **Subscription issues**: Automatic problematic catalog source removal
- **CSV failures**: Detailed diagnostics and troubleshooting information
- **Network timeouts**: Graceful handling with retry logic

## 📊 Sample Output

### Successful Deployment
```
🎉 Sriov Operator installation completed successfully!

Current CSV status:
NAME                                    DISPLAY               VERSION               PHASE
sriov-network-operator.v4.20.0-xxx     SR-IOV Network Operator   4.20.0-xxx       Succeeded

Current operator pods:
NAME                                          READY   STATUS    RESTARTS   AGE
sriov-network-config-daemon-abc12            3/3     Running   0          2m
sriov-network-operator-123def-xyz99          1/1     Running   0          3m
```

### Dry-Run Preview
```
=== DRY-RUN MODE ENABLED ===
No resources will be created on the cluster. Only showing what would be done.

[DRY-RUN YAML] ImageDigestMirrorSet that would be applied
------- File: /tmp/sriov_idms.yaml -------
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: sriov-quay-idms
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:5000/redhat-user-workloads/ocp-art-tenant/art-images-share
    source: registry.redhat.io/openshift4/ose-sriov-network-rhel9-operator
[...]

[DRY-RUN COMMAND] oc apply -f "/tmp/sriov_idms.yaml"
[DRY-RUN COMMAND] oc image mirror -a="/path/to/auth.json" [...]
```

## 🔧 Troubleshooting

### Common Issues

**Q: Script fails with "image mirror failed"**  
A: Check your authentication files and network connectivity to quay.io and your internal registry.

**Q: MachineConfigPool updates never complete**  
A: This is normal for some IDMS configurations. The script will timeout gracefully and continue.

**Q: Subscription stuck in "Installing" state**  
A: The script includes advanced monitoring that will automatically detect and resolve common issues.

**Q: "OwnNamespace InstallModeType not supported" error**  
A: This has been fixed! The script now correctly detects install modes from the operator bundle.

### Verification Commands
```bash
# Check operator status
oc get csv -n <operator-namespace>
oc get pods -n <operator-namespace>
oc get subscription -n <operator-namespace>

# Check IDMS status  
oc get imagedigestmirrorset
oc get mcp

# Check logs
oc logs -n <operator-namespace> -l app.kubernetes.io/name=<operator-name>
```

## 🤝 Contributing

This script has been battle-tested across multiple OpenShift environments and telco operators. It includes comprehensive error handling, intelligent automation, and production-ready reliability features.

### Key Design Principles
- **Fail-fast**: Exit immediately on critical errors
- **Idempotent**: Safe to run multiple times  
- **Transparent**: Clear logging and dry-run capabilities
- **Robust**: Handles edge cases and network issues gracefully

## 📄 License

This script is provided as-is for telco operator deployments in disconnected OpenShift environments.

---

**Ready to deploy your telco operators?** 🚀  
Start with a dry-run to see exactly what the script will do, then execute for a seamless deployment experience!
