FROM williamyeh/ansible:alpine3

LABEL maintainer="hocnt84@gmail.com"

RUN apk update && apk add --no-cache \
    bash \
    git \
    openssh-client \
    python3 \
    py3-pip \
    py3-cryptography \
    curl \
    jq \
    gcc \
    musl-dev \
    python3-dev \
    libffi-dev \
    openssl-dev \
    && pip3 install --upgrade pip \
    && pip3 install --no-cache-dir \
        "ansible>=2.9" \
        ansible-lint \
        requests \
        openshift \
        kubernetes \
    && curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
    && apk del gcc musl-dev python3-dev libffi-dev openssl-dev

# Install Ansible collections
RUN ansible-galaxy collection install kubernetes.core || \
    ansible-galaxy collection install community.kubernetes || \
    echo "Warning: Could not install kubernetes collection"

# Create working directory
WORKDIR /workspace

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
