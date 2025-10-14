FROM fedora:39

LABEL maintainer="Konflux Operator Deployment Tool"
LABEL description="Container image for deploying Konflux-built operators on OpenShift clusters"
LABEL version="2.0"

# Install required dependencies
RUN dnf install -y \
    jq \
    curl \
    tar \
    gzip \
    bash \
    && dnf clean all

# Install OpenShift CLI (oc) - supports multiple architectures
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi && \
    if [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    if [ "$ARCH" = "amd64" ]; then \
        OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz"; \
    else \
        OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux-${ARCH}.tar.gz"; \
    fi && \
    curl -sL -o /tmp/oc.tar.gz "$OC_URL" && \
    tar -xzf /tmp/oc.tar.gz -C /usr/local/bin && \
    rm -f /tmp/oc.tar.gz && \
    chmod +x /usr/local/bin/oc /usr/local/bin/kubectl

# Install Operator Package Manager (opm) - use GitHub releases for all architectures
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi && \
    if [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    OPM_VERSION=$(curl -s https://api.github.com/repos/operator-framework/operator-registry/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/') && \
    curl -sL "https://github.com/operator-framework/operator-registry/releases/download/${OPM_VERSION}/linux-${ARCH}-opm" -o /usr/local/bin/opm && \
    chmod +x /usr/local/bin/opm

# Install podman
RUN dnf install -y podman && \
    dnf clean all

# Create directory for the script
WORKDIR /opt/deploy-operator

# Copy the deployment script and README
COPY deploy-operator.sh /opt/deploy-operator/deploy-operator.sh
COPY readme.md /opt/deploy-operator/readme.md

# Make the script executable
RUN chmod +x /opt/deploy-operator/deploy-operator.sh

# Create a directory for mounting auth files
RUN mkdir -p /opt/auth

# Set environment variable to help users know where to mount auth files
ENV AUTH_DIR=/opt/auth

# Add a helpful message
RUN echo '#!/bin/bash' > /usr/local/bin/help && \
    echo 'cat << EOF' >> /usr/local/bin/help && \
    echo "" >> /usr/local/bin/help && \
    echo "==================================================================" >> /usr/local/bin/help && \
    echo "Konflux Operator Deployment Tool" >> /usr/local/bin/help && \
    echo "==================================================================" >> /usr/local/bin/help && \
    echo "" >> /usr/local/bin/help && \
    echo "Usage:" >> /usr/local/bin/help && \
    echo "" >> /usr/local/bin/help && \
    echo "Connected Cluster:" >> /usr/local/bin/help && \
    echo "  podman run -it --rm \\" >> /usr/local/bin/help && \
    echo "    -v ~/.kube:/root/.kube:ro \\" >> /usr/local/bin/help && \
    echo "    -v /path/to/auth:/opt/auth:ro \\" >> /usr/local/bin/help && \
    echo "    <image-name> \\" >> /usr/local/bin/help && \
    echo "    --operator sriov \\" >> /usr/local/bin/help && \
    echo "    --quay-auth /opt/auth/quay-auth.json" >> /usr/local/bin/help && \
    echo "" >> /usr/local/bin/help && \
    echo "Disconnected Cluster:" >> /usr/local/bin/help && \
    echo "  podman run -it --rm \\" >> /usr/local/bin/help && \
    echo "    -v ~/.kube:/root/.kube:ro \\" >> /usr/local/bin/help && \
    echo "    -v /path/to/auth:/opt/auth:ro \\" >> /usr/local/bin/help && \
    echo "    <image-name> \\" >> /usr/local/bin/help && \
    echo "    --operator sriov \\" >> /usr/local/bin/help && \
    echo "    --internal-registry registry.local:5000 \\" >> /usr/local/bin/help && \
    echo "    --internal-registry-auth /opt/auth/internal-auth.json \\" >> /usr/local/bin/help && \
    echo "    --quay-auth /opt/auth/quay-auth.json" >> /usr/local/bin/help && \
    echo "" >> /usr/local/bin/help && \
    echo "Supported Operators:" >> /usr/local/bin/help && \
    echo "  sriov, metallb, nmstate, ptp, pfstatus" >> /usr/local/bin/help && \
    echo "" >> /usr/local/bin/help && \
    echo "For more information, see: /opt/deploy-operator/readme.md" >> /usr/local/bin/help && \
    echo "" >> /usr/local/bin/help && \
    echo "==================================================================" >> /usr/local/bin/help && \
    echo "EOF" >> /usr/local/bin/help && \
    chmod +x /usr/local/bin/help

# Set the entrypoint to the deployment script
ENTRYPOINT ["/opt/deploy-operator/deploy-operator.sh"]

# Default command shows help if no arguments provided
CMD ["--help"]

