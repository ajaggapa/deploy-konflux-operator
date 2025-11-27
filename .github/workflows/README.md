# GitHub Actions Workflows

This directory contains GitHub Actions workflows for testing the `deploy-operator.sh` script.

## Workflows

### 1. `test-validation.yml`
**Purpose**: Fast validation checks that run on every PR
- Validates bash syntax
- Runs shellcheck (static analysis)
- Runs basic validation tests
- **Runtime**: ~2-5 minutes
- **No cluster required**

### 2. `test-crc.yml`
**Purpose**: Full integration tests on OpenShift CRC cluster
- Sets up OpenShift CRC cluster
- Tests actual operator deployments
- Tests various script scenarios
- **Runtime**: ~30-60 minutes
- **Requires**: CRC pull secret in GitHub secrets

## Setup

### For CRC Testing

1. **Get CRC Pull Secret**:
   - Go to https://console.redhat.com/openshift/downloads
   - Download your pull secret
   - Copy the JSON content

2. **Add to GitHub Secrets**:
   - Go to your repository → Settings → Secrets and variables → Actions
   - Click "New repository secret"
   - Name: `CRC_PULL_SECRET`
   - Value: Paste your pull secret JSON content
   - Click "Add secret"

3. **Optional: Configure CRC Resources**:
   - Edit `.github/workflows/test-crc.yml`
   - Adjust memory, CPUs, disk-size in the "Setup CRC" step:
     ```yaml
     crc config set memory 16384
     crc config set cpus 8
     crc config set disk-size 100
     ```

## Running Tests Locally

### Quick Validation Tests
```bash
# Run basic validation
./test-script.sh

# Check syntax
bash -n deploy-operator.sh

# Run shellcheck (if installed)
shellcheck deploy-operator.sh
```

### Full CRC Testing Locally

1. **Install CRC**:
   ```bash
   # Download and install CRC
   wget https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/crc/latest/crc-linux-amd64.tar.xz
   tar -xJf crc-linux-amd64.tar.xz
   sudo mv crc-linux-*/crc /usr/local/bin/
   ```

2. **Setup and Start CRC**:
   ```bash
   crc setup
   crc start --pull-secret-file ~/pull-secret.txt
   eval $(crc oc-env)
   ```

3. **Run Tests**:
   ```bash
   # Test with dry-run
   ./deploy-operator.sh --operator sriov --dry-run
   
   # Test actual deployment (requires quay-auth)
   ./deploy-operator.sh --operator sriov --quay-auth /path/to/quay-auth.json
   ```

## Workflow Triggers

- **Pull Requests**: Both workflows run automatically
- **Push to main**: Both workflows run automatically
- **Manual trigger**: Use "Run workflow" button in GitHub Actions tab

## Cost Considerations

- **test-validation.yml**: Free (runs on GitHub-hosted runners)
- **test-crc.yml**: Free (runs on GitHub-hosted runners, but takes longer)

## Troubleshooting

### CRC Fails to Start
- Check that `CRC_PULL_SECRET` is set correctly in GitHub secrets
- Verify the pull secret is valid JSON
- Check GitHub Actions logs for specific errors

### Tests Timeout
- Increase timeout in workflow file: `timeout-minutes: 60`
- Reduce CRC resource requirements
- Run fewer test scenarios

### Cluster Not Ready
- CRC can take 10-20 minutes to fully start
- Check logs: `crc logs`
- Verify cluster operators are available: `oc get clusteroperators`

## Alternative Testing Options

### 1. Kind (Kubernetes in Docker)
- Lighter weight than CRC
- Faster startup
- Doesn't support all OpenShift features

### 2. Minikube
- Similar to Kind
- Good for basic Kubernetes testing
- Not OpenShift-specific

### 3. OpenShift Local (CRC Alternative)
- Official Red Hat solution
- Same as CRC but with different branding

### 4. Remote OpenShift Cluster
- Use a shared test cluster
- Faster than spinning up CRC
- Requires cluster access credentials

