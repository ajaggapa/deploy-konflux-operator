#!/bin/bash

set -euo pipefail

# Image configuration
IMAGE_NAME="${IMAGE_NAME:-deploy-konflux-operator}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE_FULL="${IMAGE_NAME}:${IMAGE_TAG}"

echo "=========================================="
echo "Building Konflux Operator Deployment Image"
echo "=========================================="
echo "Image: ${IMAGE_FULL}"
echo ""

# Build the image
echo "Building image..."
podman build -t "${IMAGE_FULL}" .

if [ $? -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "✅ Image built successfully!"
    echo "=========================================="
    echo "Image: ${IMAGE_FULL}"
    echo ""
    echo "To test the image:"
    echo "  podman run --rm ${IMAGE_FULL} --help"
    echo ""
    echo "Example usage (connected cluster):"
    echo "  podman run -it --rm \\"
    echo "    -v ~/.kube:/root/.kube:ro \\"
    echo "    -v /path/to/auth:/opt/auth:ro \\"
    echo "    ${IMAGE_FULL} \\"
    echo "    --operator sriov \\"
    echo "    --quay-auth /opt/auth/quay-auth.json"
    echo ""
    echo "To push to a registry:"
    echo "  podman tag ${IMAGE_FULL} quay.io/<your-username>/${IMAGE_NAME}:${IMAGE_TAG}"
    echo "  podman push quay.io/<your-username>/${IMAGE_NAME}:${IMAGE_TAG}"
    echo ""
else
    echo ""
    echo "❌ Image build failed!"
    exit 1
fi

