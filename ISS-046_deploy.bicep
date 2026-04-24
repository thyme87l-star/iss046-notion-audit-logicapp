// ISS-046 Notion Audit Log Connector — Logic Apps Deployment
// ============================================================
// Deploys: Logic App (Standard) + Key Vault + DCE + DCR + Custom Table
//
// Usage:
//   az deployment group create \
//     --resource-group <RG> \
//     --template-file ISS-046_deploy.bicep \
//     --parameters sentinelWorkspaceResourceId=<workspace-resource-id>

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name prefix for resources')
param baseName string = 'notion-audit-la'

@description('Resource ID of the existing Log Analytics workspace (Sentinel)')
param sentinelWorkspaceResourceId string

@description('Polling interval in minutes')
param pollingIntervalMinutes int = 5

@description('Management ID tag (ISS-046)')
param mgmtId string = 'ISS-046'

var tags = {
  MgmtID: mgmtId
  Project: '課題ベース対応'
  Purpose: 'Notion Audit Log Sentinel Ingestion PoC (Logic Apps)'
  CreatedBy: 'Orchestrator'
}

var uniqueSuffix = uniqueString(resourceGroup().id, baseName)
var logicAppName = '${baseName}-${uniqueSuffix}'
var storageAccountName = 'st${replace(baseName, '-', '')}${take(uniqueSuffix, 6)}'
var appServicePlanName = '${baseName}-plan-${uniqueSuffix}'
var keyVaultName = 'kv-${baseName}-${take(uniqueSuffix, 6)}'
var dceName = '${baseName}-dce-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'

// ---------- Storage Account (Logic App backend) ----------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// ---------- App Service Plan (WS1 for Logic App Standard) ----------
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {
    reserved: false
  }
}

// ---------- Logic App (Standard) ----------
resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: logicAppName
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION', value: '~18' }
        { name: 'AzureFunctionsJobHost__extensionBundle__id', value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '[1.*, 2.0.0)' }
        { name: 'APP_KIND', value: 'workflowApp' }
      ]
    }
  }
}

// ---------- Key Vault ----------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// ---------- Key Vault RBAC: Logic App → Secrets User ----------
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, logicApp.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Data Collection Endpoint ----------
resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ---------- Data Collection Rule ----------
resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: {
      'Custom-NotionAuditLog_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'EventId', type: 'string' }
          { name: 'WorkspaceId_Notion', type: 'string' }
          { name: 'ActorType', type: 'string' }
          { name: 'ActorId', type: 'string' }
          { name: 'ActorName', type: 'string' }
          { name: 'ActorEmail', type: 'string' }
          { name: 'IpAddress', type: 'string' }
          { name: 'Platform', type: 'string' }
          { name: 'EventType', type: 'string' }
          { name: 'EventCategory', type: 'string' }
          { name: 'TargetType', type: 'string' }
          { name: 'TargetId', type: 'string' }
          { name: 'TargetName', type: 'string' }
          { name: 'RawEvent', type: 'string' }
        ]
      }
    }
    dataSources: {}
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: sentinelWorkspaceResourceId
          name: 'sentinel-workspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-NotionAuditLog_CL']
        destinations: ['sentinel-workspace']
        transformKql: 'source'
        outputStream: 'Custom-NotionAuditLog_CL'
      }
    ]
  }
}

// ---------- DCR RBAC: Logic App → Monitoring Metrics Publisher ----------
resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, logicApp.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Outputs ----------
output logicAppName string = logicApp.name
output logicAppPrincipalId string = logicApp.identity.principalId
output keyVaultName string = keyVault.name
output dceEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output dcrImmutableId string = dataCollectionRule.properties.immutableId
