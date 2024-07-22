# Akeyless-azure-lab
A docker based Akeyless lab in Azure

## Pre-requsite
register for a free Akeyless account: console.akeyless.io
Active Azure AD subscription:  you will need this to create VM

SAML / OIDC auth method:  you'll use this for login to the UI and CLI access. -->  https://docs.akeyless.io/docs/saml

Azure AD auth method:  you'll use this auth method to authenticate the akeyless gateway in your Azure VM to your account --> https://docs.akeyless.io/docs/azure-ad

Access roles:  Authorize both the Azure AD auth method and your SAML to access items and targets in your account --> https://docs.akeyless.io/docs/rbac | https://tutorials.akeyless.io/docs/role-based-access-control-with-api-key-authentication

Linux or MacOS


## Steps
have your azure login info ready
have your Akeyless SAML and gateawy access-ids ready
Close the repo locally and run the azure install script
