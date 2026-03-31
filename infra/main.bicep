targetScope = 'resourceGroup'

@description('Base name for all resources')
param baseName string = 'wfnotify'

@description('Azure region')
param location string = resourceGroup().location

@description('Teams recipient email')
param teamsRecipient string

@description('Container image (set by deploy script)')
param containerImage string

var acrName = replace('${baseName}acr', '-', '')
var acaEnvName = '${baseName}-env'
var acaAppName = '${baseName}-app'
var infoLaName = '${baseName}-info'
var reviewLaName = '${baseName}-review'
var teamsConnName = '${baseName}-teams'

// --- Container Registry ---
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: true }
}

// --- Container Apps Environment ---
resource acaEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: acaEnvName
  location: location
  properties: {}
}

// --- Teams API Connection ---
resource teamsConn 'Microsoft.Web/connections@2016-06-01' = {
  name: teamsConnName
  location: location
  properties: {
    displayName: 'Teams Notifications'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams')
    }
  }
}

// --- Info Logic App (fire-and-forget info cards) ---
resource infoLa 'Microsoft.Logic/workflows@2019-05-01' = {
  name: infoLaName
  location: location
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': { defaultValue: {}, type: 'Object' }
        teamsRecipient: { defaultValue: teamsRecipient, type: 'String' }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                eventType: { type: 'string' }
                itemId: { type: 'string' }
                itemName: { type: 'string' }
                itemType: { type: 'string' }
                submittedBy: { type: 'string' }
                currentStage: { type: 'string' }
              }
            }
          }
        }
      }
      actions: {
        Send_card: {
          type: 'ApiConnection'
          inputs: {
            host: { connection: { name: '@parameters(\'$connections\')[\'teams\'][\'connectionId\']' } }
            method: 'post'
            path: '/flowbot/actions/adaptivecard/recipienttypes/user'
            body: {
              recipient: { to: '@parameters(\'teamsRecipient\')' }
              messageBody: '@{concat(\'{"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[{"type":"Container","style":"good","items":[{"type":"TextBlock","text":"Item Created","weight":"Bolder","size":"Medium","color":"Good"},{"type":"TextBlock","text":"A new item has been created.","wrap":true,"isSubtle":true}]},{"type":"FactSet","facts":[{"title":"Item","value":"\', triggerBody()?[\'itemName\'], \'"},{"title":"Type","value":"\', triggerBody()?[\'itemType\'], \'"},{"title":"By","value":"\', triggerBody()?[\'submittedBy\'], \'"},{"title":"Stage","value":"\', triggerBody()?[\'currentStage\'], \'"}]}]}\')}'
            }
          }
          runAfter: {}
        }
        Respond: {
          type: 'Response'
          inputs: { statusCode: 202, body: { status: 'sent' } }
          runAfter: { Send_card: ['Succeeded'] }
        }
      }
    }
    parameters: {
      '$connections': {
        value: {
          teams: { connectionId: teamsConn.id, connectionName: 'teams', id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams') }
        }
      }
    }
  }
}

// --- Review Logic App (approval card with callback URL to ACA) ---
resource reviewLa 'Microsoft.Logic/workflows@2019-05-01' = {
  name: reviewLaName
  location: location
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': { defaultValue: {}, type: 'Object' }
        teamsRecipient: { defaultValue: teamsRecipient, type: 'String' }
        callbackHost: { defaultValue: 'https://placeholder', type: 'String' }
      }
      triggers: {
        manual: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                itemId: { type: 'string' }
                itemName: { type: 'string' }
                itemType: { type: 'string' }
                submittedBy: { type: 'string' }
                currentStage: { type: 'string' }
                priority: { type: 'string' }
              }
            }
          }
        }
      }
      actions: {
        Send_review_card: {
          type: 'ApiConnection'
          inputs: {
            host: { connection: { name: '@parameters(\'$connections\')[\'teams\'][\'connectionId\']' } }
            method: 'post'
            path: '/flowbot/actions/adaptivecard/recipienttypes/user'
            body: {
              recipient: { to: '@parameters(\'teamsRecipient\')' }
              messageBody: '@{concat(\'{"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[{"type":"Container","style":"emphasis","items":[{"type":"TextBlock","text":"Review Requested","weight":"Bolder","size":"Medium","color":"Attention"},{"type":"TextBlock","text":"An item requires your review.","wrap":true,"isSubtle":true}]},{"type":"FactSet","facts":[{"title":"Item","value":"\', triggerBody()?[\'itemName\'], \'"},{"title":"Type","value":"\', triggerBody()?[\'itemType\'], \'"},{"title":"Stage","value":"\', triggerBody()?[\'currentStage\'], \'"},{"title":"By","value":"\', triggerBody()?[\'submittedBy\'], \'"},{"title":"Priority","value":"\', triggerBody()?[\'priority\'], \'"}]}],"actions":[{"type":"Action.OpenUrl","title":"Approve","url":"\', parameters(\'callbackHost\'), \'/callback?action=approve&itemId=\', triggerBody()?[\'itemId\'], \'"},{"type":"Action.OpenUrl","title":"Reject","url":"\', parameters(\'callbackHost\'), \'/callback?action=reject&itemId=\', triggerBody()?[\'itemId\'], \'"}]}\')}'
            }
          }
          runAfter: {}
        }
        Respond: {
          type: 'Response'
          inputs: { statusCode: 202, body: { status: 'sent' } }
          runAfter: { Send_review_card: ['Succeeded'] }
        }
      }
    }
    parameters: {
      '$connections': {
        value: {
          teams: { connectionId: teamsConn.id, connectionName: 'teams', id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams') }
        }
      }
    }
  }
}

// --- Container App ---
resource acaApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: acaAppName
  location: location
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'app'
          image: containerImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'INFO_LOGIC_APP_URL', value: listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', infoLa.name, 'manual'), '2019-05-01').value }
            { name: 'REVIEW_LOGIC_APP_URL', value: listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', reviewLa.name, 'manual'), '2019-05-01').value }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// After ACA is created, update the review Logic App with the real callback host
module updateReviewLa 'update-callback.bicep' = {
  name: 'update-review-la-callback'
  params: {
    logicAppName: reviewLaName
    location: location
    teamsRecipient: teamsRecipient
    teamsConnectionId: teamsConn.id
    teamsConnectionApiId: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'teams')
    callbackHost: 'https://${acaApp.properties.configuration.ingress.fqdn}'
  }
}

output appUrl string = 'https://${acaApp.properties.configuration.ingress.fqdn}'
output teamsConnectionStatus string = 'Deployed - authorize Teams connection in Azure Portal'
output acrLoginServer string = acr.properties.loginServer
