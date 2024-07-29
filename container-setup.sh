#!/bin/bash

env_file="env.vars"

source env.vars

# Define constants
LAB_ID=$RESOURCE_GROUP
CLI_PATH="${HOME}/.akeyless/bin"
CLI="$CLI_PATH/akeyless"
CLI_PROFILE="--profile email"
OUTPUT_FILE="docker-compose.yml"
NETWORK_NAME="akeyless-network"
GATEWAY_PORT="8000"
DOCKER_IMAGE_AKEYLESS="akeyless/base:latest-akeyless"
DOCKER_IMAGE_CUSTOM_SERVER="akeyless/custom-server"
DOCKER_IMAGE_ZTBASTION="akeyless/zero-trust-bastion:latest"
DOCKER_IMAGE_POSTGRESQL="bitnami/postgresql:latest"
DOCKER_IMAGE_GRAFANA="bitnami/grafana:latest"
ROTATION_HOUR="9"

# Function to check if a command is installed and install if necessary
install_if_missing() {
    local cmd=$1
    local install_cmd=$2
    if ! command -v $cmd &> /dev/null; then
        echo "Installing $cmd..."
        eval $install_cmd &> /dev/null
        if command -v $cmd &> /dev/null; then
            echo "$cmd has been installed."
        else
            echo "Failed to install $cmd."
            exit 1
        fi
    else
        echo "$cmd is already installed."
    fi
}

# Function to load environment variables from a file
load_env_variables() {
  if [ -f "$env_file" ]; then
    export $(grep -v '^#' "$env_file" | xargs)
  fi
}

# Function to prompt for input and store in environment variables and file
prompt_for_input() {
  local prompt_message=$1
  local var_name=$2
  if [ -z "${!var_name}" ]; then
    read -p "$prompt_message " input_value
    export $var_name="$input_value"
    echo "$var_name=$input_value" >> "$env_file"
  else
    echo "$var_name is already set to ${!var_name}"
  fi
}

# Load existing environment variables from the env_file
load_env_variables

# Perform an initial update to ensure the package list is up-to-date
sudo apt-get update -y &> /dev/null

# Install necessary tools
install_if_missing docker "sudo apt-get install -y docker.io && sudo usermod -aG docker ${USER}"
install_if_missing docker-compose "sudo apt-get install -y docker-compose"
install_if_missing az "sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg && curl -sL https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add - &> /dev/null && echo 'deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main' | sudo tee /etc/apt/sources.list.d/azure-cli.list &> /dev/null && sudo apt-get update -y &> /dev/null && sudo apt-get install -y azure-cli"
install_if_missing yq "sudo apt-get install -y wget && sudo wget https://github.com/mikefarah/yq/releases/download/v4.13.0/yq_linux_amd64 -O /usr/bin/yq &> /dev/null && sudo chmod +x /usr/bin/yq"
install_if_missing nc "sudo apt-get install -y netcat"
install_if_missing jq "sudo apt-get install -y jq"

# Install Akeyless CLI if missing
install_if_missing akeyless "mkdir -p '$CLI_PATH' && curl -o akeyless https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/production/cli-linux-amd64' && chmod +x akeyless  && akeyless --init"

# confirm user wants to continue configuring the Docker containers
read -p "All necessary tools are installed. Do you want to continue configuring the Docker containers? (y/n): " continue_config

if [[ "$continue_config" != "y" ]]; then
    echo "Aborting configuration."
    exit 1
fi

prompt_for_input "Enter your email:" admin_email
read -s -p "Enter your password: " admin_password; echo
prompt_for_input "Enter POSTGRESQL_PASSWORD: " POSTGRESQL_PASSWORD
prompt_for_input "Enter POSTGRESQL_USERNAME: " POSTGRESQL_USERNAME
prompt_for_input "Enter database target name: " DB_TARGET_NAME

"$CLI" configure --profile email --access-type password --admin-email "$admin_email" --admin-password "$admin_password" >/dev/null 2>&1

output=$("$CLI" create-auth-method-azure-ad --name "/$LAB_ID-azure-auth" --bound-tenant-id "$TENANT_ID" $CLI_PROFILE)
auth_methods_output=$("$CLI" list-auth-methods $CLI_PROFILE)
EMAIL_ACCESS_ID=$(echo "$auth_methods_output" | jq -r '.auth_methods[] | select(.access_info.rules_type == "email_pass") | .access_info.access_id_alias')
SAML_ACCESS_ID=$(echo "$auth_methods_output" | jq -r '.auth_methods[] | select(.access_info.rules_type == "saml2") | .auth_method_access_id')
ADMIN_ACCESS_ID=$(echo "$auth_methods_output" | jq -r '.auth_methods[] | select(.access_info.rules_type == "azure_ad") | .auth_method_access_id')
# Debugging outputs to check if the variables are set
echo "ADMIN_ACCESS_ID: $ADMIN_ACCESS_ID"
echo "EMAIL_ACCESS_ID: $EMAIL_ACCESS_ID"
echo "SAML_ACCESS_ID: $SAML_ACCESS_ID"

"$CLI" configure --access-type azure_ad --access-id $ADMIN_ACCESS_ID

# Confirm all variables are populated
if [[ -z "$ADMIN_ACCESS_ID" || -z "$EMAIL_ACCESS_ID" || -z "$SAML_ACCESS_ID" ]]; then
    echo "One or more required environment variables are empty. Exiting."
    exit 1
fi

# Configure RBAC #NOTE EMAIL Profile is not secure.  Do not use this for production, replace with cloud-id or UID
CAPABILITIES=('create' 'read' 'update' 'delete' 'list')
capabilities_args=$(printf " --capability %s" "${CAPABILITIES[@]}")

ROLE_NAME="${LAB_ID}-role"
"$CLI" create-role --name "$ROLE_NAME" $CLI_PROFILE
"$CLI" set-role-rule --role-name "$ROLE_NAME" --path "/$LAB_ID/*" --rule-type role-rule $capabilities_args $CLI_PROFILE
"$CLI" set-role-rule --role-name "$ROLE_NAME" --path "/$LAB_ID/*" --rule-type target-rule $capabilities_args $CLI_PROFILE
"$CLI" set-role-rule --role-name "$ROLE_NAME" --path "/$LAB_ID/*" --rule-type auth-method-rule $capabilities_args $CLI_PROFILE
"$CLI" set-role-rule --role-name "$ROLE_NAME" --path "/$LAB_ID/*" --rule-type item-rule $capabilities_args $CLI_PROFILE
"$CLI" assoc-role-am --role-name "$ROLE_NAME" --am-name "/$LAB_ID-azure-auth" $CLI_PROFILE

# Fetch the changelog
changelog=$(curl -s https://changelog.akeyless.io)

# Extract the last 5 versions
versions=$(echo "$changelog" | grep -Eo '^[ ]*[0-9]+\.[0-9]+\.[0-9]+' | head -n 5)

# Convert the versions into an array
version_array=($versions)

# Check if there are any versions found
if [ ${#version_array[@]} -eq 0 ]; then
    echo "No versions found."
    exit 1
fi

# Display the menu and allow the user to select a version
echo "Select a version:"
select version in "${version_array[@]}"; do
    if [[ -n $version ]]; then
        export GW_VERSION=$version
        echo "installing GW Version:  $GW_VERSION"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

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
      VERSION: $GW_VERSION
      CLUSTER_NAME: akeyless-lab
      CLUSTER_URL: "http://${FQDN}:${GATEWAY_PORT}"
      ADMIN_ACCESS_ID: "$ADMIN_ACCESS_ID"
#     ALLOWED_ACCESS_PERMISSIONS: '[ {"name": "Administrators", "access_id": "${EMAIL_ACCESS_ID}", "permissions": ["admin"]}]'
      ALLOWED_ACCESS_PERMISSIONS: '[{"name":"SAML_ADMIN","access_id":"${SAML_ACCESS_ID}","permissions":["admin"]},{"name":"GW_ADMIN","access_id":"${ADMIN_ACCESS_ID}","permissions":["admin"]},{"name":"EMAIL_ADMIN","access_id":"${EMAIL_ACCESS_ID}","permissions":["admin"]}]'
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
      GW_ACCESS_ID: "$ADMIN_ACCESS_ID"
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
      PRIVILEGED_ACCESS_ID: "$ADMIN_ACCESS_ID"
      ALLOWED_ACCESS_IDS: "$EMAIL_ACCESS_ID"
    restart: unless-stopped
    networks:
      - $NETWORK_NAME
  postgresql:
    image: $DOCKER_IMAGE_POSTGRESQL
    container_name: postgresql
    ports:
      - "5432:5432"
    environment:
      POSTGRESQL_PASSWORD: "$POSTGRESQL_PASSWORD"
      POSTGRESQL_USERNAME: "$POSTGRESQL_USERNAME"
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
    while ! [ "$(sudo docker-compose ps -q $service)" ] || ! [ "$(sudo docker inspect -f '{{.State.Running}}' $(sudo docker-compose ps -q $service))" == "true" ]; do
        echo "Waiting for $service to start..."
        sleep 5
    done
    echo "$service is up and running"
done

# Update /etc/hosts with container IPs and hostnames
for service in $services; do
    container_name=$(sudo docker inspect --format '{{ .Name }}' $(sudo docker-compose ps -q "$service") | sed 's/^\///')
    container_ip=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name")
    sudo sed -i "/$container_name/d" /etc/hosts
    echo "$container_ip $container_name" | sudo tee -a /etc/hosts > /dev/null
done

# Set environment variables for hostnames
export DB_HOST=$(sudo docker inspect --format '{{ .Name }}' $(sudo docker-compose ps -q postgresql) | sed 's/^\///')
export GRAFANA_HOST=$(sudo docker inspect --format '{{ .Name }}' $(sudo docker-compose ps -q grafana) | sed 's/^\///')
export CUSTOM_SERVER_HOST=$(sudo docker inspect --format '{{ .Name }}' $(sudo docker-compose ps -q custom-server) | sed 's/^\///')
export AKEYLESS_GATEWAY_HOST=$(sudo docker inspect --format '{{ .Name }}' $(sudo docker-compose ps -q Akeyless-Gateway) | sed 's/^\///')

# Check if akeyless-gateway is up
while ! nc -zv $AKEYLESS_GATEWAY_HOST $GATEWAY_PORT; do
    echo "Waiting for akeyless-gateway to be up on port $GATEWAY_PORT..."
    sleep 10
done

# Target cleanup
akeyless target delete --name "/$LAB_ID/Databases/${DB_TARGET_NAME}"
akeyless create-db-target --name "/$LAB_ID/Databases/${DB_TARGET_NAME}" --db-type postgres --pwd $POSTGRESQL_PASSWORD --host $DB_HOST --port 5432 --user-name $POSTGRESQL_USERNAME --db-name postgres
akeyless create-secret --name "/$LAB_ID/Static/dummy" --value MyStaticSecret
akeyless create-dfc-key -n "/$LAB_ID/Encryption/MyAES128GCMKey" -a AES128GCM
akeyless create-classic-key --name "/$LAB_ID/Encryption/Classickey" --alg RSA2048
# Attempt to create the DFC key
akeyless create-dfc-key --name "/$LAB_ID/Encryption/MyRSAKey" --alg RSA2048

create_status=$?

# If the DFC key didn't exist and was created, then create the SSH cert issuer
if [ $create_status -ne 0 ]; then
    akeyless create-ssh-cert-issuer --name "/$LAB_ID/SSH/SSH-ISSUER" --signer-key-name "/$LAB_ID/Encryption/MyRSAKey" --allowed-users 'ubuntu,root' --ttl 300 > /dev/null 2>&1
fi

akeyless rotated-secret create postgresql \
--name "/$LAB_ID/Rotated/${DB_TARGET_NAME}-rotate" \
--gateway-url "http://${AKEYLESS_GATEWAY_HOST}:${GATEWAY_PORT}" \
--target-name "/$LAB_ID/Databases/${DB_TARGET_NAME}" \
--authentication-credentials use-target-creds \
--password-length 16 \
--rotator-type target \
--auto-rotate true \
--rotation-interval 1 \
--rotation-hour $ROTATION_HOUR

# Define the SQL statements for creating and revoking Super users
POSTGRESQL_STATEMENTS_SU=$(cat <<EOF
CREATE ROLE "{{name}}" WITH SUPERUSER CREATEDB CREATEROLE LOGIN ENCRYPTED PASSWORD '{{password}}';
EOF
)

POSTGRESQL_REVOKE_STATEMENT_SU=$(cat <<EOF
REASSIGN OWNED BY "{{name}}" TO {{userHost}};
DROP OWNED BY "{{name}}";
select pg_terminate_backend(pid) from pg_stat_activity where usename = '{{name}}';
DROP USER "{{name}}";
EOF
)

# Define the SQL statements for creating and revoking Read_Only
POSTGRESQL_STATEMENTS_RO=$(cat <<EOF
CREATE USER "{{name}}" WITH PASSWORD '{{password}}';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "{{name}}";
GRANT CONNECT ON DATABASE postgres TO "{{name}}";
GRANT USAGE ON SCHEMA public TO "{{name}}";
EOF
)

POSTGRESQL_REVOKE_STATEMENT_RO=$(cat <<EOF
REASSIGN OWNED BY "{{name}}" TO {{userHost}};
DROP OWNED BY "{{name}}";
select pg_terminate_backend(pid) from pg_stat_activity where usename = '{{name}}';
DROP USER "{{name}}";
EOF
)

# Create Super User DB Dynamic Secret
akeyless dynamic-secret create postgresql \
--name "/$LAB_ID/Dynamic/${DB_TARGET_NAME}-su-dynamic" \
--target-name "/$LAB_ID/Databases/${DB_TARGET_NAME}" \
--gateway-url "http://${AKEYLESS_GATEWAY_HOST}:${GATEWAY_PORT}" \
--postgresql-statements "$POSTGRESQL_STATEMENTS_SU" \
--postgresql-revoke-statement "$POSTGRESQL_REVOKE_STATEMENT_SU" \
--password-length 16

# Create Read_only DB Dynamic Secret
akeyless dynamic-secret create postgresql \
--name "/$LAB_ID/Dynamic/${DB_TARGET_NAME}-ro-dynamic" \
--target-name "/$LAB_ID/Databases/${DB_TARGET_NAME}" \
--gateway-url "http://${AKEYLESS_GATEWAY_HOST}:${GATEWAY_PORT}" \
--postgresql-statements "$POSTGRESQL_STATEMENTS_RO" \
--postgresql-revoke-statement "$POSTGRESQL_REVOKE_STATEMENT_RO" \
--password-length 16

# Print the hostnames for the user
echo "PostgreSQL Hostname: $DB_HOST"
echo "Grafana Hostname: $GRAFANA_HOST"
echo "Custom Server Hostname: $CUSTOM_SERVER_HOST"
echo "Akeyless Gateway Hostname: $AKEYLESS_GATEWAY_HOST"
echo
echo "Please run 'source $PROFILE_FILE' to update your PATH in the current terminal session."
