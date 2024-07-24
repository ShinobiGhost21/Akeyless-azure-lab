#!/bin/bash

# Function to check if a command is installed and install if necessary
install_if_missing() {
    local cmd=$1
    local install_cmd=$2
    if ! command -v $cmd &> /dev/null; then
        echo "Installing $cmd..."
        eval $install_cmd
    else
        echo "$cmd is already installed."
    fi
}

# Function to prompt the user for input and store it in a variable
prompt_for_input() {
    local prompt_message=$1
    local input_variable=$2
    read -p "$prompt_message: " $input_variable
    export $input_variable
}

# Install necessary tools
install_if_missing docker "sudo apt update && sudo apt -y install docker.io && sudo usermod -aG docker ${USER}"
install_if_missing docker-compose "sudo apt -y install docker-compose"
install_if_missing az "sudo apt-get update && sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg -y && curl -sL https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add - && echo 'deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main' | sudo tee /etc/apt/sources.list.d/azure-cli.list && sudo apt-get update && sudo apt-get install azure-cli -y"
install_if_missing yq "sudo apt-get update -y && sudo apt-get install -y wget && sudo wget https://github.com/mikefarah/yq/releases/download/v4.13.0/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq"
install_if_missing nc "sudo apt update && sudo apt -y install netcat"

# Prompt for inputs
prompt_for_input "Enter ADMIN_ACCESS_ID (admin access ID of your gateway): " ADMIN_ACCESS_ID
prompt_for_input "Enter SAML or OIDC access-id (create one in Akeyless console if you don't have one): " SAML_ACCESS_ID
prompt_for_input "Enter POSTGRESQL_PASSWORD: " POSTGRESQL_PASSWORD
prompt_for_input "Enter POSTGRESQL_USERNAME: " POSTGRESQL_USERNAME
prompt_for_input "Enter database target name: " DB_TARGET_NAME

# Define constants
CLI_PATH="${HOME}/.akeyless/bin"
CLI="$CLI_PATH/akeyless"
OUTPUT_FILE="docker-compose.yml"
NETWORK_NAME="akeyless-network"
GATEWAY_PORT="8000"
DOCKER_IMAGE_AKEYLESS="akeyless/base:latest-akeyless"
DOCKER_IMAGE_CUSTOM_SERVER="akeyless/custom-server"
DOCKER_IMAGE_ZTBASTION="akeyless/zero-trust-bastion:latest"
DOCKER_IMAGE_POSTGRESQL="bitnami/postgresql:latest"
DOCKER_IMAGE_GRAFANA="bitnami/grafana:latest"
ROTATION_HOUR="9"

# Install Akeyless CLI if missing
install_if_missing akeyless "mkdir -p '$CLI_PATH' && curl -o '$CLI' 'https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/production/cli-linux-$(uname -m)' && chmod +x '$CLI' && '$CLI' --init"

# Configure Akeyless CLI
"$CLI" configure --access-type azure_ad --access-id=$ADMIN_ACCESS_ID >/dev/null 2>&1

# Generate docker-compose.yml
cat << EOF > $OUTPUT_FILE
version: '3.8'
networks:
  $NETWORK_NAME:
    external: true
services:
  Akeyless-Gateway:
    image: $DOCKER_IMAGE_AKEYLESS
    container_name: akeyless-gateway
    ports:
      - "$GATEWAY_PORT:$GATEWAY_PORT"
      - "8200:8200"
      - "18888:18888"
      - "8080:8080"
      - "8081:8081"
      - "5696:5696"
    environment:
      CLUSTER_NAME: akeyless-lab
      ADMIN_ACCESS_ID: ${ADMIN_ACCESS_ID}
      ALLOWED_ACCESS_PERMISSIONS: '[ {"name": "Administrators", "access_id": "${SAML_ACCESS_ID}", "permissions": ["admin"]}]'
    networks:
      - $NETWORK_NAME
  custom-server:
    image: $DOCKER_IMAGE_CUSTOM_SERVER
    container_name: custom-server
    ports:
      - "2608:2608"
    volumes:
      - $PWD/custom_logic.sh:/custom_logic.sh
    environment:
      GW_ACCESS_ID: ${ADMIN_ACCESS_ID}
    restart: unless-stopped
    networks:
      - $NETWORK_NAME
  zero-trust-bastion:
    image: $DOCKER_IMAGE_ZTBASTION
    container_name: akeyless-lab-web-bastion
    ports:
      - "8888:8888"
    environment:
      AKEYLESS_GW_URL: https://rest.akeyless.io
      PRIVILEGED_ACCESS_ID: ${ADMIN_ACCESS_ID}
      ALLOWED_ACCESS_IDS: ${SAML_ACCESS_ID}
      CLUSTER_NAME: akeyless-lab-sra
    restart: unless-stopped
    networks:
      - $NETWORK_NAME
  postgresql:
    image: $DOCKER_IMAGE_POSTGRESQL
    container_name: postgresql
    ports:
      - "5432:5432"
    environment:
      POSTGRESQL_PASSWORD: ${POSTGRESQL_PASSWORD}
      POSTGRESQL_USERNAME: ${POSTGRESQL_USERNAME}
    networks:
      - $NETWORK_NAME
  grafana:
    image: $DOCKER_IMAGE_GRAFANA
    container_name: grafana
    ports:
      - "3000:3000"
    networks:
      - $NETWORK_NAME
EOF

echo "docker-compose.yml file has been generated at $OUTPUT_FILE."

# Kill existing docker containers
sudo docker stop $(sudo docker ps -aq) >/dev/null 2>&1
sudo docker rm $(sudo docker ps -aq) >/dev/null 2>&1

# Create docker network if it doesn't exist
sudo docker network create $NETWORK_NAME || echo "Network $NETWORK_NAME already exists."

# Run docker-compose up -d
sudo docker-compose up -d
echo "Docker containers are being started in detached mode."

# Wait for the containers to be up and running
echo "Waiting for the containers to be up and running..."
services=$(yq e '.services | keys' $OUTPUT_FILE | sed 's/- //g')
for service in $services; do
    echo "Checking service: $service"
    while ! [ "$(docker-compose ps -q $service)" ] || ! [ "$(docker inspect -f '{{.State.Running}}' $(docker-compose ps -q $service))" == "true" ]; do
        echo "Waiting for $service to start..."
        sleep 5
    done
    echo "$service is up and running"
done

# Update /etc/hosts with container IPs and hostnames
for service in $services; do
    container_name=$(docker inspect --format '{{ .Name }}' $(docker-compose ps -q "$service") | sed 's/^\///')
    container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name")
    sudo sed -i "/$container_name/d" /etc/hosts
    echo "$container_ip $container_name" | sudo tee -a /etc/hosts > /dev/null
done

# Set environment variables for hostnames
export DB_HOST=$(docker inspect --format '{{ .Name }}' $(docker-compose ps -q postgresql) | sed 's/^\///')
export GRAFANA_HOST=$(docker inspect --format '{{ .Name }}' $(docker-compose ps -q grafana) | sed 's/^\///')
export CUSTOM_SERVER_HOST=$(docker inspect --format '{{ .Name }}' $(docker-compose ps -q custom-server) | sed 's/^\///')
export AKEYLESS_GATEWAY_HOST=$(docker inspect --format '{{ .Name }}' $(docker-compose ps -q Akeyless-Gateway) | sed 's/^\///')

# Check if akeyless-gateway is up
while ! nc -zv $AKEYLESS_GATEWAY_HOST $GATEWAY_PORT; do
    echo "Waiting for akeyless-gateway to be up on port $GATEWAY_PORT..."
    sleep 10
done

# Target cleanup
akeyless target delete --name "/Sandbox/1 - Databases/${DB_TARGET_NAME}"

# Configure DB Target
akeyless target create db \
--name "/Sandbox/1 - Databases/${DB_TARGET_NAME}" \
--db-type postgres \
--pwd $POSTGRESQL_PASSWORD  \
--host $DB_HOST \
--port 5432 \
--user-name $POSTGRESQL_USERNAME \
--db-name postgres

# Rotate default DB password
akeyless rotated-secret create postgresql \
--name "/Sandbox/3 - Rotated/1 - Databases/${DB_TARGET_NAME}-rotate" \
--gateway-url "http://${AKEYLESS_GATEWAY_HOST}:${GATEWAY_PORT}" \
--target-name "/Sandbox/1 - Databases/${DB_TARGET_NAME}" \
--authentication-credentials use-target-creds \
--password-length 16 \
--rotator-type target \
--auto-rotate true \
--rotation-interval 1 \
--rotation-hour $ROTATION_HOUR

# Define the SQL statements for creating Super users and Read_Only
read -r -d '' POSTGRESQL_STATEMENTS_SU <<'EOF'
CREATE ROLE "{{name}}" WITH SUPERUSER CREATEDB CREATEROLE LOGIN ENCRYPTED PASSWORD '{{password}}';
EOF

read -r -d '' POSTGRESQL_REVOKE_STATEMENT_SU <<'EOF'
REASSIGN OWNED BY "{{name}}" TO {{userHost}};
DROP OWNED BY "{{name}}";
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}';
DROP USER "{{name}}";
EOF

read -r -d '' POSTGRESQL_STATEMENTS_RO <<'EOF'
CREATE USER "{{name}}" WITH PASSWORD '{{password}}';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";
GRANT CONNECT ON DATABASE postgres TO "{{name}}";
GRANT USAGE ON SCHEMA public TO "{{name}}";
EOF

read -r -d '' POSTGRESQL_REVOKE_STATEMENT_RO <<'EOF'
REASSIGN OWNED BY "{{name}}" TO {{userHost}};
DROP OWNED BY "{{name}}";
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}';
DROP USER "{{name}}";
EOF

# Function to create a dynamic secret
create_dynamic_secret() {
    local secret_name=$1
    local db_target_name=$2
    local statements=$3
    local revoke_statement=$4

    akeyless dynamic-secret create postgresql \
    --name "/Sandbox/4 - Dynamic/${db_target_name}-${secret_name}-dynamic" \
    --target-name "/Sandbox/1 - Databases/${db_target_name}" \
    --gateway-url "http://${AKEYLESS_GATEWAY_HOST}:${GATEWAY_PORT}" \
    --postgresql-statements "$statements" \
    --postgresql-revoke-statement "$revoke_statement" \
    --password-length 16
}

# Create Super User DB Dynamic Secret
create_dynamic_secret "su" "${DB_TARGET_NAME}" "$POSTGRESQL_STATEMENTS_SU" "$POSTGRESQL_REVOKE_STATEMENT_SU"

# Create Read_only DB Dynamic Secret
create_dynamic_secret "ro" "${DB_TARGET_NAME}" "$POSTGRESQL_STATEMENTS_RO" "$POSTGRESQL_REVOKE_STATEMENT_RO"


# Create dynamic secrets for roles
for role in "${!SQL_STATEMENTS[@]}"; do
    create_dynamic_secret "$role" "${SQL_STATEMENTS[$role]}" "${REVOKE_STATEMENTS[$role]}"
done
# Print the hostnames for the user
echo "PostgreSQL Hostname: $DB_HOST"
echo "Grafana Hostname: $GRAFANA_HOST"
echo "Custom Server Hostname: $CUSTOM_SERVER_HOST"
echo "Akeyless Gateway Hostname: $AKEYLESS_GATEWAY_HOST"
