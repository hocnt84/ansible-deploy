#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Ansible deployment process...${NC}"

# Step 1: Clone git repository
echo -e "${YELLOW}Step 1: Cloning git repository...${NC}"

if [ -z "$GIT_REPO_URL" ]; then
    echo -e "${RED}Error: GIT_REPO_URL environment variable is not set${NC}"
    exit 1
fi

# Extract repository name from URL for directory
REPO_NAME=$(basename "$GIT_REPO_URL" .git)
WORK_DIR="/workspace/$REPO_NAME"

# Configure git credentials if provided
if [ -n "$GIT_TOKEN" ]; then
    if [ -n "$GIT_USERNAME" ]; then
        # Use username:token format
        GIT_REPO_URL_WITH_AUTH=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_USERNAME}:${GIT_TOKEN}@|")
    else
        # Use oauth2:token format (GitLab Personal Access Token)
        GIT_REPO_URL_WITH_AUTH=$(echo "$GIT_REPO_URL" | sed "s|https://|https://oauth2:${GIT_TOKEN}@|")
    fi
    GIT_REPO_URL="$GIT_REPO_URL_WITH_AUTH"
fi

# Clone or update repository
if [ -d "$WORK_DIR" ]; then
    echo -e "${YELLOW}Repository already exists, pulling latest changes...${NC}"
    cd "$WORK_DIR"
    git fetch origin
    git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
else
    echo -e "${YELLOW}Cloning repository...${NC}"
    git clone "$GIT_REPO_URL" "$WORK_DIR"
    cd "$WORK_DIR"
fi

# Checkout specific branch if provided
if [ -n "$GIT_BRANCH" ]; then
    echo -e "${YELLOW}Checking out branch: $GIT_BRANCH${NC}"
    git checkout "$GIT_BRANCH"
fi

echo -e "${GREEN}Git repository cloned/updated successfully${NC}"

# Step 2: Create inventory file from GitLab env variables
echo -e "${YELLOW}Step 2: Creating inventory file from environment variables...${NC}"

# Function to write inventory variable if exists
# Reads from UPPERCASE env var but writes to file with lowercase name
write_inventory_var() {
    local inventory_key=$1  # lowercase name for inventory file
    local env_var_name=$(echo "$inventory_key" | tr '[:lower:]' '[:upper:]')  # convert to UPPERCASE for env var
    local value="${!env_var_name}"
    if [ -n "$value" ]; then
        echo "${inventory_key}=${value}" >> "$WORK_DIR/inventory-local.ini"
    fi
}

# Create inventory file
INVENTORY_FILE="$WORK_DIR/inventory-local.ini"
rm -f "$INVENTORY_FILE"
touch "$INVENTORY_FILE"

# Support both methods: individual env vars OR full content
if [ -n "$INVENTORY_CONTENT" ] || [ -n "$INVENTORY_CONTENT_B64" ]; then
    # Method 1: Full content (backward compatible)
    if [ -n "$INVENTORY_CONTENT_B64" ]; then
        echo -e "${YELLOW}Decoding base64 inventory content...${NC}"
        echo "$INVENTORY_CONTENT_B64" | base64 -d > "$INVENTORY_FILE"
    else
        printf '%s\n' "$INVENTORY_CONTENT" > "$INVENTORY_FILE"
    fi
else
    # Method 2: Generate from individual environment variables
    echo -e "${YELLOW}Generating inventory file from individual variables...${NC}"
    
    # PostgreSQL configuration
    echo "# PostgreSQL configuration" >> "$INVENTORY_FILE"
    write_inventory_var "postgresql_namespace"
    write_inventory_var "postgresql_host"
    write_inventory_var "postgresql_username"
    write_inventory_var "postgres_password"
    write_inventory_var "postgresql_port"
    write_inventory_var "postgresql_database"
    echo "" >> "$INVENTORY_FILE"
    
    # Elasticsearch configuration
    echo "# Elasticsearch configuration" >> "$INVENTORY_FILE"
    write_inventory_var "elastic_namespace"
    write_inventory_var "elastic_host"
    write_inventory_var "elastic_username"
    write_inventory_var "elastic_password"
    write_inventory_var "elasticsearch_password_secret"
    echo "" >> "$INVENTORY_FILE"
    
    # Redis configuration
    echo "# Redis configuration" >> "$INVENTORY_FILE"
    write_inventory_var "redis_namespace"
    write_inventory_var "redis_host"
    write_inventory_var "redis_port"
    # Special handling for camelCase variables
    if [ -n "$REDIS_PASSWORD" ]; then
        echo "redisPassword=${REDIS_PASSWORD}" >> "$INVENTORY_FILE"
    fi
    if [ -n "$REDIS_ARCHITECTURE" ]; then
        echo "redisArchitecture=${REDIS_ARCHITECTURE}" >> "$INVENTORY_FILE"
    fi
    echo "" >> "$INVENTORY_FILE"
    
    # APM configuration
    echo "# APM configuration" >> "$INVENTORY_FILE"
    write_inventory_var "apm_namespace"
    write_inventory_var "apm_host"
    write_inventory_var "apm_port"
    echo "" >> "$INVENTORY_FILE"
    
    # K8S Service configuration
    echo "# K8S Service configuration" >> "$INVENTORY_FILE"
    write_inventory_var "api_gateway_host"
    write_inventory_var "identity_host"
    write_inventory_var "notification_host"
    write_inventory_var "authorization_host"
    write_inventory_var "depository_host"
    write_inventory_var "product_host"
    echo "" >> "$INVENTORY_FILE"
    
    # Authorization Migration
    echo "# Authorization Migration" >> "$INVENTORY_FILE"
    write_inventory_var "authorization_postgres_database"
    echo "" >> "$INVENTORY_FILE"
    
    # Depository Service
    echo "# Depository Service" >> "$INVENTORY_FILE"
    write_inventory_var "depository_postgres_database"
    echo "" >> "$INVENTORY_FILE"
    
    # Identity Service
    echo "# Identity Service" >> "$INVENTORY_FILE"
    write_inventory_var "identity_postgres_database"
    echo "" >> "$INVENTORY_FILE"
    
    # Image Tags
    echo "# Image Tags" >> "$INVENTORY_FILE"
    write_inventory_var "identity_image_tag"
    write_inventory_var "authorization_image_tag"
    write_inventory_var "apigateway_image_tag"
    write_inventory_var "depository_image_tag"
    write_inventory_var "notification_image_tag"
    write_inventory_var "authorization_migration_image_tag"
    write_inventory_var "cms_image_tag"
fi

echo -e "${GREEN}Inventory file created at $INVENTORY_FILE${NC}"

# Step 3: Setup kubeconfig from GitLab env
echo -e "${YELLOW}Step 3: Setting up kubeconfig...${NC}"

if [ -z "$KUBECONFIG_CONTENT" ] && [ -z "$KUBECONFIG_CONTENT_B64" ] && [ -z "$KUBECONFIG_FILE" ]; then
    echo -e "${RED}Error: KUBECONFIG_CONTENT, KUBECONFIG_CONTENT_B64, or KUBECONFIG_FILE environment variable must be set${NC}"
    exit 1
fi

# Create .kube directory if it doesn't exist
mkdir -p ~/.kube

# Write kubeconfig content to file (support multiple methods)
if [ -n "$KUBECONFIG_FILE" ]; then
    # Use file path (when GitLab Variable type is "File")
    echo -e "${YELLOW}Copying kubeconfig from file: $KUBECONFIG_FILE${NC}"
    cp "$KUBECONFIG_FILE" ~/.kube/config
elif [ -n "$KUBECONFIG_CONTENT_B64" ]; then
    # Decode base64 content
    echo -e "${YELLOW}Decoding base64 kubeconfig content...${NC}"
    echo "$KUBECONFIG_CONTENT_B64" | base64 -d > ~/.kube/config
else
    # Use plain text content
    printf '%s\n' "$KUBECONFIG_CONTENT" > ~/.kube/config
fi

chmod 600 ~/.kube/config

echo -e "${GREEN}Kubeconfig file created at ~/.kube/config${NC}"

# Verify kubectl/helm can access cluster
if command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}Verifying kubectl connection...${NC}"
    kubectl cluster-info || echo -e "${YELLOW}Warning: Could not verify kubectl connection${NC}"
fi

# Step 4: Run ansible-playbook with tags from GitLab env
echo -e "${YELLOW}Step 4: Running ansible-playbook...${NC}"

if [ ! -f "$WORK_DIR/playbook.yaml" ]; then
    echo -e "${RED}Error: playbook.yaml not found in repository${NC}"
    exit 1
fi

# Prepare ansible-playbook command with required variables
# Override playbook hardcoded variables for container environment
KUBECONFIG_FILE_PATH=~/.kube/config
K8S_NAMESPACE="${K8S_NAMESPACE:-dev}"

ANSIBLE_CMD="ansible-playbook playbook.yaml -i inventory-local.ini"

# Override playbook variables (kubeconfig_path and helm_root are hardcoded in playbook)
ANSIBLE_EXTRA_VARS_OVERRIDE="kubeconfig_path=$KUBECONFIG_FILE_PATH helm_root=$WORK_DIR k8s_namespace=$K8S_NAMESPACE"

# Add tags if provided
if [ -n "$ANSIBLE_TAGS" ]; then
    ANSIBLE_CMD="$ANSIBLE_CMD --tags $ANSIBLE_TAGS"
    echo -e "${GREEN}Using tags: $ANSIBLE_TAGS${NC}"
else
    echo -e "${YELLOW}Warning: ANSIBLE_TAGS not set, running playbook without tags${NC}"
fi

# Read inventory variables and add to extra-vars
# Ansible doesn't automatically load variables from ini inventory files in playbooks
INVENTORY_VARS=""
if [ -f "$WORK_DIR/inventory-local.ini" ]; then
    # Extract variables from inventory file (skip comments and empty lines)
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -n "$key" && -n "$value" ]] && INVENTORY_VARS="$INVENTORY_VARS $key=$value"
    done < "$WORK_DIR/inventory-local.ini"
fi

# Combine extra vars (override + inventory vars + user provided)
if [ -n "$ANSIBLE_EXTRA_VARS" ]; then
    ANSIBLE_CMD="$ANSIBLE_CMD --extra-vars \"$ANSIBLE_EXTRA_VARS_OVERRIDE$INVENTORY_VARS $ANSIBLE_EXTRA_VARS\""
else
    ANSIBLE_CMD="$ANSIBLE_CMD --extra-vars \"$ANSIBLE_EXTRA_VARS_OVERRIDE$INVENTORY_VARS\""
fi

echo -e "${GREEN}Playbook variables:${NC}"
echo -e "  - kubeconfig_path: $KUBECONFIG_FILE_PATH"
echo -e "  - helm_root: $WORK_DIR"
echo -e "  - k8s_namespace: $K8S_NAMESPACE"

# Change to work directory and run ansible-playbook
cd "$WORK_DIR"
echo -e "${GREEN}Executing: $ANSIBLE_CMD${NC}"
echo ""

# Execute the command
eval $ANSIBLE_CMD

echo ""
echo -e "${GREEN}Ansible deployment completed successfully!${NC}"

