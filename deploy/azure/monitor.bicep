// Minimal monitoring for one Barkpark instance on Azure Container Apps.
//
// Three alerts send mail to one action group:
//   1. https://<host>/readyz fails twice in a row, checked by an Application
//      Insights standard availability test.
//   2. An execution of the backup job fails.
//   3. The app's container restarts several times in a short window.
//
// The module creates no Log Analytics workspace. It takes the workspace and
// the app from main.bicep by resource id. Application Insights stores its
// availability results in that workspace. The backup job must exist before
// this module runs, or the deployment fails on the missing job.
//
// main.bicep calls it after the app:
//
//   param alertEmail string = ''
//   param backupJobName string = ''
//   module monitor 'monitor.bicep' = if (!empty(alertEmail) && !restoreMode) {
//     name: 'monitor-${nameSuffix}'
//     params: {
//       location: location
//       nameSuffix: nameSuffix
//       logAnalyticsWorkspaceId: logs.id
//       containerAppId: app.id
//       publicHost: host
//       backupJobName: backupJobName
//       alertEmail: alertEmail
//     }
//   }
//
// Log retention belongs to the workspace in main.bicep: add
// `param logRetentionDays int = 30` and set `retentionInDays: logRetentionDays`,
// keeping `workspaceCapping: { dailyQuotaGb: 1 }`.

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Resource id of the Log Analytics workspace main.bicep created.')
param logAnalyticsWorkspaceId string

@description('Resource id of the Barkpark container app.')
param containerAppId string

@description('Public host name of the app, without https://. The test requests https://<host>/readyz.')
param publicHost string

@description('Name of the Container Apps job that runs backups, in this resource group. Leave empty when there is no backup job yet; then no backup alert is created.')
param backupJobName string = ''

@description('Address that receives the alert mail.')
param alertEmail string

@description('Seconds between availability checks. 300 alerts after about 10 minutes down; 900 costs a third as much and alerts after about 30 minutes.')
@allowed([300, 900])
param availabilityFrequencySeconds int = 300

@description('Availability test location. One location keeps the cost at one execution per check. emea-gb-db3-azr is North Europe, the closest to Norway East.')
param availabilityLocation string = 'emea-gb-db3-azr'

@description('Restarts within restartWindow that count as repeated.')
param restartThreshold int = 3

// The metric's description says cumulative, but a test showed one sample of 1
// per restart, so the window total is the number of restarts in the window.
@description('Window for the restart alert.')
@allowed(['PT15M', 'PT30M', 'PT1H'])
param restartWindow string = 'PT30M'

param nameSuffix string = uniqueString(resourceGroup().id)

var url = 'https://${publicHost}/readyz'
var testName = 'readyz-${nameSuffix}'
// Two checks fit in a window of twice the frequency. Azure allows PT10M and
// PT30M, which matches 300 and 900.
var availabilityWindow = availabilityFrequencySeconds == 300 ? 'PT10M' : 'PT30M'
var availabilityEvaluation = availabilityFrequencySeconds == 300 ? 'PT5M' : 'PT15M'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-barkpark-${nameSuffix}'
  location: 'global'
  properties: {
    groupShortName: 'barkpark'
    enabled: true
    emailReceivers: [
      {
        name: 'operator'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ── /readyz availability ────────────────────────────────────────────────────

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-barkpark-${nameSuffix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'
  }
}

resource readyzTest 'Microsoft.Insights/webtests@2022-06-15' = {
  name: testName
  location: location
  // Azure links a test to its Application Insights resource by this tag.
  tags: {
    'hidden-link:${insights.id}': 'Resource'
  }
  properties: {
    SyntheticMonitorId: testName
    Name: 'Barkpark /readyz'
    Kind: 'standard'
    Enabled: true
    Frequency: availabilityFrequencySeconds
    Timeout: 30
    // A failed check is retried twice within 20 seconds before it counts.
    RetryEnabled: true
    Locations: [
      { Id: availabilityLocation }
    ]
    Request: {
      RequestUrl: url
      HttpVerb: 'GET'
      ParseDependentRequests: false
    }
    ValidationRules: {
      ExpectedHttpStatusCode: 200
      SSLCheck: true
      SSLCertRemainingLifetimeCheck: 7
    }
  }
}

resource readyzAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-barkpark-readyz-${nameSuffix}'
  location: 'global'
  properties: {
    description: 'Two checks in a row of ${url} failed.'
    severity: 1
    enabled: true
    scopes: [insights.id]
    evaluationFrequency: availabilityEvaluation
    windowSize: availabilityWindow
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'TwoFailedChecks'
          metricNamespace: 'microsoft.insights/components'
          metricName: 'availabilityResults/count'
          dimensions: [
            { name: 'availabilityResult/name', operator: 'Include', values: [readyzTest.properties.Name] }
            { name: 'availabilityResult/success', operator: 'Include', values: ['0'] }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 2
          timeAggregation: 'Count'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// ── Backup job ──────────────────────────────────────────────────────────────

resource backupJob 'Microsoft.App/jobs@2024-03-01' existing = if (!empty(backupJobName)) {
  name: empty(backupJobName) ? 'none' : backupJobName
}

resource backupAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(backupJobName)) {
  name: 'alert-barkpark-backup-${nameSuffix}'
  location: 'global'
  properties: {
    description: 'An execution of the backup job ${backupJobName} failed.'
    severity: 1
    enabled: true
    scopes: [backupJob.id]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    // Fires once per failure. With autoMitigate false Azure would mail again
    // at every evaluation while the failure is inside the window.
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'FailedExecution'
          metricNamespace: 'Microsoft.App/jobs'
          metricName: 'Executions'
          dimensions: [
            { name: 'state', operator: 'Include', values: ['Failed'] }
          ]
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

// ── Restarts ────────────────────────────────────────────────────────────────

resource restartAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-barkpark-restarts-${nameSuffix}'
  location: 'global'
  properties: {
    description: 'The app restarted ${restartThreshold} times or more within ${restartWindow}.'
    severity: 2
    enabled: true
    scopes: [containerAppId]
    evaluationFrequency: 'PT5M'
    windowSize: restartWindow
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'RepeatedRestarts'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'RestartCount'
          operator: 'GreaterThanOrEqual'
          threshold: restartThreshold
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      { actionGroupId: actionGroup.id }
    ]
  }
}

output actionGroupId string = actionGroup.id
output availabilityTestId string = readyzTest.id
