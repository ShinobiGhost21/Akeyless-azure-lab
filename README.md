# Akeyless-azure-lab
A docker based Akeyless lab in Azure

## Pre-requsite
* register for a free Akeyless account: console.akeyless.io
* Active Azure AD subscription:  you will need this to create VM

## Nice-to-have
* SAML / OIDC auth method:  you'll use this for login to the UI and CLI access. -->  https://docs.akeyless.io/docs/saml
* Azure AD auth method:  you'll use this auth method to authenticate the akeyless gateway in your Azure VM to your account --> https://docs.akeyless.io/docs/azure-ad
* Access roles:  Authorize both the Azure AD auth method and your SAML to access items and targets in your account --> https://docs.akeyless.io/docs/rbac | https://tutorials.akeyless.io/docs/role-based-access-control-with-api-key-authentication
* Linux or MacOS


## Steps
* have your azure login info ready
* have your Akeyless SAML and gateawy access-ids ready
* Close the repo locally and run the azure install script

## Outcomes
* Creates an Azure VM with managed identity
* Creates Azure AD auth method:  you'll use this auth method to authenticate the akeyless gateway in your Azure VM to your account --> https://docs.akeyless.io/docs/azure-ad
* Creates Docker Containers: akeyless-gateway, Postgresql, Grafana, and custom-server.
* Custom-server will be used for creating dynamic / rotated secret objects for custom and non-supported applications e.g. Grafana
* Configures Akeyelss components: Gateway, Auth Methods, Access-Roles, Gateway Permissions
* Creates Secret items: Static, Encryption, Rotated, Dynamic-Read-only, and Dynamic-Super-User


## To Do
* SSH Cert issuer for Certificate based SSH access
* Linux container to use as SSH Target
* Custom Producer for Grafana web server
* Gateway metrics
* Gateway Migration
* Universal Secrets Connector (Azure Key Vault, Hashi, AWS, GCP, K8s)
* Azure DevOps integration
