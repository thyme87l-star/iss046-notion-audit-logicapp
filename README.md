# Notion Audit Log → Microsoft Sentinel (Logic App)

PoC deployment files for ingesting Notion Audit Logs into Microsoft Sentinel via Logic App (Consumption)

## File List
- **deploy.ps1**: PowerShell script to deploy the Logic App and resources.
- **ISS-046_deploy.bicep**: Bicep template for infrastructure deployment.
- **ISS-046_logic_app_consumption.json**: Logic App ARM template (Consumption plan).
- **ISS-046_logic_app_definition.json**: Logic App workflow definition.
- **params.json**: Parameters for the Bicep/ARM deployment.

## Usage
See the deployment guide for step-by-step instructions.