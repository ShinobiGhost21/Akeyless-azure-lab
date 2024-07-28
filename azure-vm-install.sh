#!/bin/bash

# Prompt user for LAB ID
read -p "Enter a friendly name for this lab (e.g., akeyless-lab): " LAB_ID

# Define variables
RESOURCE_GROUP="$LAB_ID"
ADMIN_USERNAME="azureuser"
LOCATION="eastus"
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
TENANT_ID=$(az account show --query tenantId --output tsv)
VNET_NAME="$RESOURCE_GROUP-vnet"
SUBNET_NAME="$RESOURCE_GROUP-subnet"
PUBLIC_IP_NAME="$RESOURCE_GROUP-ip"
NSG_NAME="$RESOURCE_GROUP-nsg"
NIC_NAME="$RESOURCE_GROUP-nic"
VM_NAME="$RESOURCE_GROUP-vm"
IP_CONFIG_NAME="ipconfig1"
IMAGE="Ubuntu2204"
VM_SIZE="Standard_D4s_v3"

# Function to delete resource if it exists
delete_resource() {
  if az "$1" show --name "$2" --resource-group "$3" &>/dev/null; then
    echo "Deleting $1 $2..."
    az "$1" delete --name "$2" --resource-group "$3" --no-wait
  else
    echo "$1 $2 does not exist."
  fi
}

# Check if Azure CLI is installed and install if necessary
command -v az &>/dev/null || {
  echo "Azure CLI is not installed. Installing Azure CLI..."
  [[ "$OSTYPE" == "linux-gnu"* ]] && curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  [[ "$OSTYPE" == "darwin"* ]] && brew update && brew install azure-cli
  command -v az &>/dev/null || { echo "Unsupported OS. Please install Azure CLI manually."; exit 1; }
}

# Check if Azure is already logged in, if not, login
az account show &>/dev/null || az login || { echo "Azure login failed."; exit 1; }

# Deallocate and delete the VM
echo "Deallocating and deleting the VM..."
az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --no-wait
az vm delete --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --yes --no-wait

# Disassociate the public IP address from the NIC
echo "Disassociating public IP address from $NIC_NAME..."
az network nic ip-config update --resource-group "$RESOURCE_GROUP" --nic-name "$NIC_NAME" --name "$IP_CONFIG_NAME" --remove publicIpAddress

# Wait for VM deletion to complete
echo "Waiting for VM deletion to complete..."
while az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &>/dev/null; do
  echo "VM is still being deleted. Waiting for 30 seconds..."
  sleep 30
done
echo "VM deletion completed."

# Delete resources
delete_resource "network nic" "$NIC_NAME" "$RESOURCE_GROUP"
delete_resource "network public-ip" "$PUBLIC_IP_NAME" "$RESOURCE_GROUP"
delete_resource "network nsg" "$NSG_NAME" "$RESOURCE_GROUP"
delete_resource "network vnet" "$VNET_NAME" "$RESOURCE_GROUP"

# Prompt user for confirmation
read -p "VM deletion is complete. Do you want to continue with the installation? (y/n): " response
[[ "${response,,}" != "y" && "${response,,}" != "yes" ]] && { echo "Installation aborted."; exit 0; }

# Create resources
echo "Creating resource group..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

echo "Creating virtual network and subnet..."
az network vnet create --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" --subnet-name "$SUBNET_NAME"

echo "Creating public IP address with DNS name..."
az network public-ip create --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" --dns-name "$LAB_ID"

echo "Creating network security group..."
az network nsg create --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME"

echo "Creating network interface..."
az network nic create --resource-group "$RESOURCE_GROUP" --name "$NIC_NAME" --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" --network-security-group "$NSG_NAME" --public-ip-address "$PUBLIC_IP_NAME"

echo "Creating the VM..."
az vm create --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --nics "$NIC_NAME" --image "$IMAGE" --size "$VM_SIZE" --admin-username "$ADMIN_USERNAME" --generate-ssh-keys

# Enable Managed Identity for the VM
echo "Enabling Managed Identity for the VM..."
az vm identity assign --resource-group $RESOURCE_GROUP --name $VM_NAME

# Get the principal ID of the Managed Identity
PRINCIPAL_ID=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query identity.principalId --output tsv)

# Assign the Reader role to the Managed Identity
echo "Assigning Reader role to the Managed Identity..."
az role assignment create --assignee $PRINCIPAL_ID --role Reader --scope /subscriptions/$SUBSCRIPTION_ID

echo "Creating inbound firewall rules..."
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name Akeyless-gateway --protocol Tcp --priority 1001 --destination-port-range 8000 8002 8080 8081 18888 22 8888 9000 19414 2608 --access Allow --direction Inbound

echo "Script execution completed."

# Display the FQDN for SSH access and other important information
FQDN="$LAB_ID.$LOCATION.cloudapp.azure.com"
RESOURCE_ID=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query id --output tsv)

echo "Azure Subscription ID: $SUBSCRIPTION_ID"
echo "Azure Tenant ID: $TENANT_ID"
echo "Resource ID: $RESOURCE_ID"
echo

# Save environment variables to a file
cat <<EOF > env.vars
export RESOURCE_GROUP="$LAB_ID"
export ADMIN_USERNAME="$ADMIN_USERNAME"
export LOCATION="$LOCATION"
export SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export TENANT_ID="$TENANT_ID"
export VNET_NAME="$VNET_NAME"
export SUBNET_NAME="$SUBNET_NAME"
export PUBLIC_IP_NAME="$PUBLIC_IP_NAME"
export NSG_NAME="$NSG_NAME"
export NIC_NAME="$NIC_NAME"
export VM_NAME="$VM_NAME"
export IP_CONFIG_NAME="$IP_CONFIG_NAME"
export IMAGE="$IMAGE"
export VM_SIZE="$VM_SIZE"
export FQDN="$FQDN"
EOF

sleep 10
# Transfer the second script to the VM
echo copy these files to the new VM
echo "source env.vars"
echo "scp ./container-setup.sh $ADMIN_USERNAME@$FQDN:/home/$ADMIN_USERNAME/"
echo "scp ./env_vars.sh $ADMIN_USERNAME@$FQDN:/home/$ADMIN_USERNAME/"
echo
echo "SSH into your VM using the following command:"
echo "ssh $ADMIN_USERNAME@$FQDN"
