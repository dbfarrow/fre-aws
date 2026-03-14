# fre-aws — self-contained toolbox for managing the Claude Code AWS environment.
# Contains: terraform, aws-cli v2, SSM session-manager-plugin, bats, scripts.
#
# Nothing sensitive is baked in. AWS credentials and config are mounted at runtime.

FROM debian:bookworm-slim

# ---------------------------------------------------------------------------
# Versions (update these to pick up new releases)
# ---------------------------------------------------------------------------
ARG TERRAFORM_VERSION=1.9.8
ARG AWSCLI_VERSION=2.22.0
ARG SSM_PLUGIN_VERSION=1.2.650.0

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    jq \
    git \
    ca-certificates \
    gnupg \
    bash \
    bats \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
      -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && terraform version

# ---------------------------------------------------------------------------
# AWS CLI v2
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" \
      -o /tmp/awscli.zip \
    && unzip /tmp/awscli.zip -d /tmp/awscli-install \
    && /tmp/awscli-install/aws/install \
    && rm -rf /tmp/awscli.zip /tmp/awscli-install \
    && aws --version

# ---------------------------------------------------------------------------
# SSM Session Manager plugin (required for connect.sh)
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
      -o /tmp/session-manager-plugin.deb \
    && dpkg -i /tmp/session-manager-plugin.deb \
    && rm /tmp/session-manager-plugin.deb \
    && session-manager-plugin --version

# ---------------------------------------------------------------------------
# Project scripts
# ---------------------------------------------------------------------------
WORKDIR /workspace
COPY scripts/ /workspace/scripts/
COPY terraform/ /workspace/terraform/
COPY tests/ /workspace/tests/
RUN chmod +x /workspace/scripts/*.sh

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
# Default: drop into bash so the container is useful interactively.
# run.sh overrides this with the specific script to execute.
CMD ["/bin/bash"]
