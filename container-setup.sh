#!/bin/bash

# Function to check if a command is installed
is_installed() {
    command -v $1 >/dev/null 2>&1
}

# Function to prompt the user for input and store it in a variable
prompt_for_input() {
    local prompt_message=$1
    local input_variable=$2
    read -p "$prompt_message: " $input_variable
    export $input_variable
}

# Prompt for ADMIN_ACCESS_ID early
prompt_for_input "Enter ADMIN_ACCESS_ID, this is the admin access id of your gateway.  create an Azure AD Auth method in console if you don't have one" ADMIN_ACCESS_ID

# Define OS_MACHINE and CLI paths
OS_MACHINE="$(uname -s)_$(uname -m)"
CLI_PATH="${HOME}/.akeyless/bin"
CLI="$CLI_PATH/akeyless"

# Function to download and install Akeyless CLI if not present
download_and_install_akeyless() {
    mkdir -p "$CLI_PATH"
    case $OS_MACHINE in
        "Linux_x86_64")
            URL="https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/production/cli-linux-amd64"
            curl -o "$CLI" "$URL" >/dev/null 2>&1
            ;;
        "Linux_aarch64")
            URL="https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/production/cli-linux-arm64"
            curl -o "$CLI" "$URL" >/dev/null 2>&1
            ;;
        "Darwin_x86_64"|"Darwin_arm64")
            if ! command -v akeyless &> /dev/null; then
                brew install akeyless >/dev/null 2>&1
            fi
            ;;
    esac
    chmod +x "$CLI" >/dev/null 2>&1
    "$CLI" --init >/dev/null 2>&1
}

# Check if Akeyless CLI exists and download if not
if [ ! -f "$CLI" ] || ! command -v akeyless &> /dev/null; then
    download_and_install_akeyless
    profile_file="${HOME}/.$(basename $SHELL)rc"
    grep -q "$CLI_PATH" "$profile_file" || echo "export PATH=\$PATH:$CLI_PATH" >> "$profile_file"
fi

source /home/azureuser/.bashrc

# Configure CLI profile
"$CLI" configure --access-type azure_ad --access-id=$ADMIN_ACCESS_ID >/dev/null 2>&1

# Update and install Docker if not installed
if ! is_installed docker; then
    sudo apt update
    sudo apt -y install docker.io
    sudo usermod -aG docker ${USER}
else
    echo "Docker is already installed."
fi

# Update and install Docker Compose if not installed
if ! is_installed docker-compose; then
    sudo apt -y install docker-compose
else
    echo "Docker Compose is already installed."
fi

source /home/azureuser/.bashrc

# Check if Azure CLI is installed
if ! is_installed az; then
    echo "Azure CLI not found. Installing..."
    sudo apt-get update
    sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg -y
    curl -sL https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
    AZ_REPO=$(lsb_release -cs)
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
    sudo apt-get update
    sudo apt-get install azure-cli -y
else
    echo "Azure CLI is already installed."
fi

# Log in to Azure
#echo "Logging in to Azure..."
#az login --use-device-code

# Get the Tenant ID
echo "Fetching Tenant ID..."
TENANT_ID=$(az account show --query tenantId --output tsv)

# Display the Tenant ID
echo "Your Azure Tenant ID is: $TENANT_ID"

# Prompt for Docker Hub login
echo "Please log in to Docker Hub:"
sudo docker login

# Prompt the user for additional values
prompt_for_input "Enter SAML or OIDC access-id.  Create one in akeyless console if you don't have one" SAML_ACCESS_ID
prompt_for_input "Enter POSTGRESQL_PASSWORD" POSTGRESQL_PASSWORD
prompt_for_input "Enter POSTGRESQL_USERNAME" POSTGRESQL_USERNAME

# Define the path to save the docker-compose.yml file
output_file="docker-compose.yml"

# Create the docker-compose.yml file using a heredoc
cat << EOF > $output_file
services:
  Akeyless-Gateway:
    ports:
      - 8000:8000
      - 8200:8200
      - 18888:18888
      - 8080:8080
      - 8081:8081
      - 5696:5696
    container_name: akeyless-gateway
    environment:
      - CLUSTER_NAME=akeyless-lab
      - ADMIN_ACCESS_ID=$ADMIN_ACCESS_ID
      - 'ALLOWED_ACCESS_PERMISSIONS=[ {"name": "Administrators",
        "access_id": "$SAML_ACCESS_ID", "permissions": ["admin"]}]'
    image: akeyless/base:latest-akeyless
  Custom-Server:
    ports:
      - 2608:2608
    volumes:
      - \$PWD/custom_logic.sh:/custom_logic.sh
    environment:
      - GW_ACCESS_ID=$ADMIN_ACCESS_ID
    restart: unless-stopped
    container_name: custom-server
    image: akeyless/custom-server
  zero-trust-bastion:
    container_name: akeyless-lab-web-bastion
    ports:
      - 8888:8888
    environment:
      - AKEYLESS_GW_URL=https://rest.akeyless.io
      - PRIVILEGED_ACCESS_ID=$ADMIN_ACCESS_ID
      - ALLOWED_ACCESS_IDS=$SAML_ACCESS_ID
      - CLUSTER_NAME=akeyless-lab-sra
    restart: unless-stopped
    image: akeyless/zero-trust-bastion:latest
#  ZTWA-Dispatcher:
#    image: akeyless/zero-trust-web-dispatcher
#    ports:
#      - 9000:9000
#      - 19414:19414
#    volumes:
#      - \$PWD/shared:/etc/shared
#    environment:
#      - CLUSTER_NAME=akeyless-lab-sra
#      - SERVICE_DNS=worker
#      - AKEYLESS_GW_URL=https://rest.akeyless.io
#      - PRIVILEGED_ACCESS_ID=$ADMIN_ACCESS_ID
#      - ALLOWED_ACCESS_IDS=[$SAML_ACCESS_ID]
#      - ALLOW_INTERNAL_AUTH=false
#      - DISABLE_SECURE_COOKIE=true
#      - WEB_PROXY_TYPE=http
  postgresql:
    ports:
      - 5432:5432
    environment:
      - POSTGRESQL_PASSWORD=$POSTGRESQL_PASSWORD
      - POSTGRESQL_USERNAME=$POSTGRESQL_USERNAME
    container_name: postgresql
    image: bitnami/postgresql:latest
  grafana:
    container_name: grafana
    ports:
      - 3000:3000
    image: bitnami/grafana:latest
EOF

echo "docker-compose.yml file has been generated at $output_file."

# Run docker-compose up -d
sudo docker-compose up -d

echo "Docker containers are being started in detached mode."

# Wait for the containers to be up and running
echo "Waiting for the containers to be up and running..."
sleep 30

# Find the IP addresses of the containers
DB_HOST=$(sudo docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' postgresql)
GRAFANA_HOST=$(sudo docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' grafana)
CUSTOM_SERVER_HOST=$(sudo docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' custom-server)

# Export the IP addresses as environment variables
export DB_HOST
export GRAFANA_HOST
export CUSTOM_SERVER_HOST

# Print the IP addresses for the user
echo "PostgreSQL IP Address: $DB_HOST"
echo "Grafana IP Address: $GRAFANA_HOST"
echo "Custom Server IP Address: $CUSTOM_SERVER_HOST"
