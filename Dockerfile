# fre-aws — self-contained toolbox for managing the Claude Code AWS environment.
# Contains: terraform, aws-cli v2, SSM session-manager-plugin, bats, scripts.
#
# Supports both linux/amd64 (Intel Mac, CI) and linux/arm64 (Apple Silicon).
# Nothing sensitive is baked in. AWS credentials and config are mounted at runtime.

FROM debian:bookworm-slim

# ---------------------------------------------------------------------------
# Versions (update these to pick up new releases)
# ---------------------------------------------------------------------------
ARG TERRAFORM_VERSION=1.9.8
ARG AWSCLI_VERSION=2.22.0

# TARGETARCH is set automatically by Docker BuildKit:
#   amd64  — Intel/AMD (Intel Mac, most CI runners)
#   arm64  — Apple Silicon (M1/M2/M3 Mac)
ARG TARGETARCH

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    zip \
    jq \
    git \
    ca-certificates \
    gnupg \
    bash \
    bats \
    openssh-client \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Terraform
# Hashicorp uses "amd64" / "arm64" in their filenames.
# ---------------------------------------------------------------------------
RUN TF_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip" \
      -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip terraform -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && terraform version

# ---------------------------------------------------------------------------
# AWS CLI v2
# AWS uses "x86_64" / "aarch64" in their filenames.
# ---------------------------------------------------------------------------
RUN AWS_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" \
      -o /tmp/awscli.zip \
    && unzip /tmp/awscli.zip -d /tmp/awscli-install \
    && /tmp/awscli-install/aws/install \
    && rm -rf /tmp/awscli.zip /tmp/awscli-install \
    && aws --version

# ---------------------------------------------------------------------------
# SSM Session Manager plugin (required for connect.sh)
# AWS uses "ubuntu_64bit" / "ubuntu_arm64" in their path.
# ---------------------------------------------------------------------------
RUN SSM_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "ubuntu_arm64" || echo "ubuntu_64bit") \
    && curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${SSM_ARCH}/session-manager-plugin.deb" \
      -o /tmp/session-manager-plugin.deb \
    && dpkg -i /tmp/session-manager-plugin.deb \
    && rm /tmp/session-manager-plugin.deb \
    && session-manager-plugin --version

# ---------------------------------------------------------------------------
# Project scripts
# ---------------------------------------------------------------------------
WORKDIR /workspace
COPY scripts/ /workspace/scripts/
RUN chmod +x /workspace/scripts/*.sh

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
# Default: drop into bash so the container is useful interactively.
# run.sh overrides this with the specific script to execute.
CMD ["/bin/bash"]
