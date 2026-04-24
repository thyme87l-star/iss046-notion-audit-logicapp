// ISS-046 Notion Audit Log Connector — Infrastructure Deployment (Consumption)
// ============================================================
// Deploys: DCE + DCR + Custom Table
// Logic App (Consumption) は ISS-046_logic_app_consumption.json で別途デプロイ
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

@description('Management ID tag (ISS-046)')
param mgmtId string = 'ISS-046'

var tags = {
  MgmtID: mgmtId
  Project: '課題ベース対応'
  Purpose: 'Notion Audit Log Sentinel Ingestion PoC (Logic Apps Consumption)'
  CreatedBy: 'Orchestrator'
}

var uniqueSuffix = uniqueString(resourceGroup().id, baseName)
var dceName = '${baseName}-dce-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'

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

// ---------- Outputs ----------
output dceEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output dcrImmutableId string = dataCollectionRule.properties.immutableId
output dcrResourceId string = dataCollectionRule.id
