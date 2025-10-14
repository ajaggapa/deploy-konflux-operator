# Konflux Operator Deployment Container - Usage Guide

This container image packages the `deploy-operator.sh` script along with all required dependencies (`oc`, `opm`, `jq`, `podman`) for deploying Konflux-built operators on OpenShift clusters.

---

## Quick Start

### 1. Build the Image

```bash
# Use the provided build script
chmod +x build-image.sh
./build-image.sh

# Or build manually
podman build -t deploy-konflux-operator:latest .
```

### 2. Run the Container

The container requires access to:
- **Kubernetes config** (`~/.kube/config`) - for cluster authentication
- **Authentication files** - for registry access

---

## Usage Examples

### Connected Cluster - Deploy SR-IOV Operator

```bash
podman run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  deploy-konflux-operator:latest \
  --operator sriov \
  --quay-auth /opt/auth/quay-auth.json
```

### Connected Cluster - Deploy MetalLB Operator

```bash
podman run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  deploy-konflux-operator:latest \
  --operator metallb \
  --quay-auth /opt/auth/quay-auth.json
```

### Disconnected Cluster - Deploy SR-IOV Operator

```bash
podman run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  deploy-konflux-operator:latest \
  --operator sriov \
  --internal-registry registry.internal.example.com:5000 \
  --internal-registry-auth /opt/auth/internal-auth.json \
  --quay-auth /opt/auth/quay-auth.json
```

### Custom Operator with FBC Tag

```bash
podman run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  deploy-konflux-operator:latest \
  --fbc-tag ocp__4.17__custom-rhel9-operator \
  --quay-auth /opt/auth/quay-auth.json
```

---

## Volume Mounts

The container requires the following volume mounts:

| Host Path | Container Path | Description | Mode |
|-----------|----------------|-------------|------|
| `~/.kube` | `/root/.kube` | Kubernetes config for cluster access | `:ro` (read-only) |
| `/path/to/auth` | `/opt/auth` | Directory containing auth JSON files | `:ro` (read-only) |

**Note:** Mount paths can be adjusted based on your local setup.

---

## Preparation

### 1. Prepare Authentication Files

#### Quay.io Authentication

```bash
# Create quay auth file
podman login quay.io --authfile=~/auth/quay-auth.json

# Or create manually
cat > ~/auth/quay-auth.json <<EOF
{
  "auths": {
    "quay.io": {
      "auth": "base64EncodedUsername:Password=="
    }
  }
}
EOF
```

#### Internal Registry Authentication (for disconnected mode)

```bash
# Create internal registry auth file
podman login registry.internal:5000 --authfile=~/auth/internal-auth.json

# Or create manually
cat > ~/auth/internal-auth.json <<EOF
{
  "auths": {
    "registry.internal.example.com:5000": {
      "auth": "base64EncodedUsername:Password=="
    }
  }
}
EOF
```

### 2. Configure Kubernetes Access

Ensure your `~/.kube/config` file has valid credentials for your OpenShift cluster:

```bash
# Test cluster access
oc cluster-info

# Or login to your cluster
oc login https://api.cluster.example.com:6443 --token=<token>
```

---

## Container Options

### Running with Custom Kubeconfig Path

```bash
podman run -it --rm \
  -v /custom/path/kubeconfig:/root/.kube/config:ro \
  -v ~/auth:/opt/auth:ro \
  deploy-konflux-operator:latest \
  --operator sriov \
  --quay-auth /opt/auth/quay-auth.json
```

### Running with Podman-in-Podman (for image mirroring in disconnected mode)

```bash
podman run -it --rm \
  --privileged \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  -v /var/lib/containers:/var/lib/containers:rw \
  deploy-konflux-operator:latest \
  --operator sriov \
  --internal-registry registry.internal:5000 \
  --internal-registry-auth /opt/auth/internal-auth.json \
  --quay-auth /opt/auth/quay-auth.json
```

**Note:** The `--privileged` flag and container storage mount may be needed for disconnected mode operations that require image mirroring.

---

## Supported Operators

The container supports the following predefined operators:

| Operator | CLI Argument | Description |
|----------|--------------|-------------|
| SR-IOV Network | `--operator sriov` | Single Root I/O Virtualization |
| MetalLB | `--operator metallb` | Bare metal load balancer |
| NMState | `--operator nmstate` | Network management state |
| PTP | `--operator ptp` | Precision Time Protocol |
| PF Status Relay | `--operator pfstatus` | Physical Function status relay |

---

## Advanced Usage

### Building and Pushing to Quay.io

```bash
# Build the image
podman build -t deploy-konflux-operator:latest .

# Tag for your registry
podman tag deploy-konflux-operator:latest quay.io/<your-username>/deploy-konflux-operator:latest

# Login to quay.io
podman login quay.io

# Push the image
podman push quay.io/<your-username>/deploy-konflux-operator:latest
```

### Using the Image from a Registry

Once pushed to a registry, users can run it directly:

```bash
podman run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  quay.io/<your-username>/deploy-konflux-operator:latest \
  --operator sriov \
  --quay-auth /opt/auth/quay-auth.json
```

### Running with Docker Instead of Podman

The image is compatible with Docker:

```bash
docker run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  deploy-konflux-operator:latest \
  --operator sriov \
  --quay-auth /opt/auth/quay-auth.json
```

---

## Environment Variables

You can customize the build process using environment variables:

```bash
# Custom image name
export IMAGE_NAME=my-operator-deployer
export IMAGE_TAG=v1.0.0
./build-image.sh

# This will create: my-operator-deployer:v1.0.0
```

---

## Troubleshooting

### Error: "Cannot connect to cluster"

**Cause:** The container cannot access your Kubernetes cluster.

**Solution:**
- Ensure `~/.kube/config` is mounted correctly
- Verify cluster connectivity from your host: `oc cluster-info`
- Check if cluster certificates are valid

### Error: "Quay auth file not found"

**Cause:** The authentication file is not mounted or path is incorrect.

**Solution:**
- Verify the host path contains the auth file
- Check the mount path in the container matches the `--quay-auth` argument
- Example: If mounted to `/opt/auth`, use `--quay-auth /opt/auth/quay-auth.json`

### Error: "Failed to auth quay.io"

**Cause:** Invalid credentials in the auth file.

**Solution:**
- Regenerate the auth file: `podman login quay.io --authfile=~/auth/quay-auth.json`
- Verify JSON format: `jq . ~/auth/quay-auth.json`

### Permission Issues with Podman Storage

**Cause:** Container needs privileged access for image mirroring in disconnected mode.

**Solution:**
```bash
podman run -it --rm \
  --privileged \
  -v ~/.kube:/root/.kube:ro \
  -v ~/auth:/opt/auth:ro \
  -v /var/lib/containers:/var/lib/containers:rw \
  deploy-konflux-operator:latest \
  --operator sriov \
  --internal-registry registry.internal:5000 \
  --internal-registry-auth /opt/auth/internal-auth.json \
  --quay-auth /opt/auth/quay-auth.json
```

---

## Testing the Image

### Test Basic Functionality

```bash
# Test that the image was built correctly
podman run --rm deploy-konflux-operator:latest --help
```

### Test with Connected Cluster

```bash
# Create test auth file
mkdir -p ~/test-auth
podman login quay.io --authfile=~/test-auth/quay-auth.json

# Run deployment
podman run -it --rm \
  -v ~/.kube:/root/.kube:ro \
  -v ~/test-auth:/opt/auth:ro \
  deploy-konflux-operator:latest \
  --operator metallb \
  --quay-auth /opt/auth/quay-auth.json
```

---

## Security Considerations

1. **Read-Only Mounts**: Use `:ro` flag for kubeconfig and auth files to prevent accidental modifications
2. **Privileged Mode**: Only use `--privileged` when necessary (disconnected mode with image mirroring)
3. **Sensitive Data**: Auth files contain credentials - ensure proper file permissions on host
4. **Image Scanning**: Scan the image for vulnerabilities before deployment:
   ```bash
   podman scan deploy-konflux-operator:latest
   ```

---

## Multi-Architecture Support

The Dockerfile supports both `amd64` and `arm64` architectures. To build multi-arch images:

```bash
# Build for multiple architectures
podman build --platform linux/amd64,linux/arm64 -t deploy-konflux-operator:latest .

# Or build manifest list
podman manifest create deploy-konflux-operator:latest
podman build --platform linux/amd64 --manifest deploy-konflux-operator:latest .
podman build --platform linux/arm64 --manifest deploy-konflux-operator:latest .
podman manifest push deploy-konflux-operator:latest quay.io/<your-username>/deploy-konflux-operator:latest
```

---

## CI/CD Integration

### Example GitHub Actions Workflow

```yaml
name: Build and Push Operator Deployment Image

on:
  push:
    branches: [ main ]
    tags: [ 'v*' ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build Image
        run: |
          podman build -t deploy-konflux-operator:${{ github.sha }} .
      
      - name: Push to Quay.io
        run: |
          echo "${{ secrets.QUAY_TOKEN }}" | podman login -u "${{ secrets.QUAY_USERNAME }}" --password-stdin quay.io
          podman tag deploy-konflux-operator:${{ github.sha }} quay.io/${{ secrets.QUAY_USERNAME }}/deploy-konflux-operator:latest
          podman push quay.io/${{ secrets.QUAY_USERNAME }}/deploy-konflux-operator:latest
```

---

## Additional Resources

- **Script Documentation**: See `readme.md` in the repository
- **OpenShift Documentation**: https://docs.openshift.com/
- **Podman Documentation**: https://podman.io/
- **Container Best Practices**: https://docs.docker.com/develop/dev-best-practices/

---

## Support

For issues or questions:
1. Check the main `readme.md` for script-specific documentation
2. Review troubleshooting section above
3. Verify all prerequisites are installed in the container
4. Test the script directly (outside container) to isolate issues

---

**Container Version**: 2.0  
**Base Image**: UBI9 (Universal Base Image)  
**Supported Platforms**: linux/amd64, linux/arm64

