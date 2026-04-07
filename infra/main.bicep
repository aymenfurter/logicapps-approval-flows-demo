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
var feedbackLaName = '${baseName}-feedback'
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

// --- Info Logic App (fire-and-forget info cards with extra detail fields) ---
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
                department: { type: 'string' }
                estimatedCost: { type: 'string' }
                comments: { type: 'string' }
                correlationId: { type: 'string' }
              }
            }
          }
          correlation: {
            clientTrackingId: '@triggerBody()?[\'correlationId\']'
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
              messageBody: '@{concat(\'{"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[{"type":"Container","style":"good","items":[{"type":"TextBlock","text":"Item Created","weight":"Bolder","size":"Medium","color":"Good"},{"type":"TextBlock","text":"A new item has been created.","wrap":true,"isSubtle":true}]},{"type":"FactSet","facts":[{"title":"Item","value":"\', triggerBody()?[\'itemName\'], \'"},{"title":"Type","value":"\', triggerBody()?[\'itemType\'], \'"},{"title":"By","value":"\', triggerBody()?[\'submittedBy\'], \'"},{"title":"Stage","value":"\', triggerBody()?[\'currentStage\'], \'"},{"title":"Department","value":"\', triggerBody()?[\'department\'], \'"},{"title":"Est. Cost","value":"\', triggerBody()?[\'estimatedCost\'], \'"},{"title":"Comments","value":"\', triggerBody()?[\'comments\'], \'"}]},{"type":"TextBlock","text":"Correlation: \', triggerBody()?[\'correlationId\'], \'","isSubtle":true,"size":"Small","wrap":true}]}\')}'
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

// --- Review Logic App (webhook wait: card with Action.Submit, suspends until user responds) ---
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
                department: { type: 'string' }
                estimatedCost: { type: 'string' }
                comments: { type: 'string' }
                correlationId: { type: 'string' }
              }
            }
          }
          correlation: {
            clientTrackingId: '@triggerBody()?[\'correlationId\']'
          }
        }
      }
      actions: {
        Respond: {
          type: 'Response'
          inputs: { statusCode: 202, body: { status: 'sent' } }
          runAfter: {}
        }
        Send_review_card: {
          type: 'ApiConnectionWebhook'
          inputs: {
            host: { connection: { name: '@parameters(\'$connections\')[\'teams\'][\'connectionId\']' } }
            body: {
              body: {
                recipient: { to: '@parameters(\'teamsRecipient\')' }
                messageBody: '@{concat(\'{"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[{"type":"Container","style":"emphasis","items":[{"type":"TextBlock","text":"Review Requested","weight":"Bolder","size":"Medium","color":"Attention"},{"type":"TextBlock","text":"An item requires your review.","wrap":true,"isSubtle":true}]},{"type":"FactSet","facts":[{"title":"Item","value":"\', triggerBody()?[\'itemName\'], \'"},{"title":"Type","value":"\', triggerBody()?[\'itemType\'], \'"},{"title":"Stage","value":"\', triggerBody()?[\'currentStage\'], \'"},{"title":"By","value":"\', triggerBody()?[\'submittedBy\'], \'"},{"title":"Priority","value":"\', triggerBody()?[\'priority\'], \'"},{"title":"Department","value":"\', triggerBody()?[\'department\'], \'"},{"title":"Est. Cost","value":"\', triggerBody()?[\'estimatedCost\'], \'"},{"title":"Comments","value":"\', triggerBody()?[\'comments\'], \'"}]},{"type":"TextBlock","text":"Correlation: \', triggerBody()?[\'correlationId\'], \'","isSubtle":true,"size":"Small","wrap":true}],"actions":[{"type":"Action.Submit","title":"Approve","data":{"action":"approve"}},{"type":"Action.Submit","title":"Reject","data":{"action":"reject"}}]}\')}'
                shouldUpdateCard: true
                updateMessage: 'Your decision has been recorded. Thank you!'
              }
            }
            path: '/flowbot/actions/flowcontinuation/recipienttypes/user'
          }
          limit: {
            timeout: 'P7D'
          }
          runAfter: { Respond: ['Succeeded'] }
        }
        Check_if_approved: {
          type: 'If'
          expression: {
            and: [
              {
                equals: [
                  '@body(\'Send_review_card\')?[\'data\']?[\'action\']'
                  'approve'
                ]
              }
            ]
          }
          actions: {
            Post_approval_provisioning: {
              type: 'Compose'
              inputs: {
                step: 'post-approval-provisioning'
                itemId: '@triggerBody()?[\'itemId\']'
                correlationId: '@triggerBody()?[\'correlationId\']'
                provisionedAt: '@utcNow()'
                note: 'Resources provisioned after approval (simulated)'
              }
              runAfter: {}
            }
            Send_confirmation: {
              type: 'ApiConnection'
              inputs: {
                host: { connection: { name: '@parameters(\'$connections\')[\'teams\'][\'connectionId\']' } }
                method: 'post'
                path: '/flowbot/actions/adaptivecard/recipienttypes/user'
                body: {
                  recipient: { to: '@parameters(\'teamsRecipient\')' }
                  messageBody: '@{concat(\'{"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[{"type":"Container","style":"good","items":[{"type":"TextBlock","text":"Provisioning Complete","weight":"Bolder","size":"Medium","color":"Good"},{"type":"TextBlock","text":"Post-approval provisioning has been completed by the Logic App.","wrap":true,"isSubtle":true}]},{"type":"FactSet","facts":[{"title":"Item","value":"\', triggerBody()?[\'itemId\'], \'"},{"title":"Action","value":"Approved"},{"title":"Provisioned At","value":"\', utcNow(), \'"}]},{"type":"TextBlock","text":"Correlation: \', triggerBody()?[\'correlationId\'], \'","isSubtle":true,"size":"Small","wrap":true}]}\')}'
                }
              }
              runAfter: { Post_approval_provisioning: ['Succeeded'] }
            }
            Notify_app_approved: {
              type: 'Http'
              inputs: {
                method: 'POST'
                uri: '@{concat(parameters(\'callbackHost\'), \'/callback/review\')}'
                body: {
                  action: 'approve'
                  itemId: '@triggerBody()?[\'itemId\']'
                  itemName: '@triggerBody()?[\'itemName\']'
                  correlationId: '@triggerBody()?[\'correlationId\']'
                  provisioned: true
                  provisionedAt: '@utcNow()'
                }
                headers: {
                  'Content-Type': 'application/json'
                  'x-ms-client-tracking-id': '@triggerBody()?[\'correlationId\']'
                }
              }
              runAfter: { Send_confirmation: ['Succeeded'] }
            }
          }
          else: {
            actions: {
              Notify_app_rejected: {
                type: 'Http'
                inputs: {
                  method: 'POST'
                  uri: '@{concat(parameters(\'callbackHost\'), \'/callback/review\')}'
                  body: {
                    action: 'reject'
                    itemId: '@triggerBody()?[\'itemId\']'
                    itemName: '@triggerBody()?[\'itemName\']'
                    correlationId: '@triggerBody()?[\'correlationId\']'
                    provisioned: false
                  }
                  headers: {
                    'Content-Type': 'application/json'
                    'x-ms-client-tracking-id': '@triggerBody()?[\'correlationId\']'
                  }
                }
                runAfter: {}
              }
            }
          }
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

// --- Feedback Logic App (inline text input in Teams card, waits for response, calls back to app) ---
resource feedbackLa 'Microsoft.Logic/workflows@2019-05-01' = {
  name: feedbackLaName
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
                correlationId: { type: 'string' }
              }
            }
          }
          correlation: {
            clientTrackingId: '@triggerBody()?[\'correlationId\']'
          }
        }
      }
      actions: {
        Respond: {
          type: 'Response'
          inputs: { statusCode: 202, body: { status: 'sent' } }
          runAfter: {}
        }
        Send_feedback_card: {
          type: 'ApiConnectionWebhook'
          inputs: {
            host: { connection: { name: '@parameters(\'$connections\')[\'teams\'][\'connectionId\']' } }
            body: {
              body: {
                recipient: { to: '@parameters(\'teamsRecipient\')' }
                messageBody: '@{concat(\'{"type":"AdaptiveCard","$schema":"http://adaptivecards.io/schemas/adaptive-card.json","version":"1.4","body":[{"type":"Container","style":"accent","items":[{"type":"TextBlock","text":"Feedback Requested","weight":"Bolder","size":"Medium","color":"Accent"},{"type":"TextBlock","text":"Your feedback is needed on the following item.","wrap":true,"isSubtle":true}]},{"type":"FactSet","facts":[{"title":"Item","value":"\', triggerBody()?[\'itemName\'], \'"},{"title":"Type","value":"\', triggerBody()?[\'itemType\'], \'"},{"title":"Requested by","value":"\', triggerBody()?[\'submittedBy\'], \'"}]},{"type":"TextBlock","text":"Correlation: \', triggerBody()?[\'correlationId\'], \'","isSubtle":true,"size":"Small","wrap":true},{"type":"Input.Text","id":"feedback","placeholder":"Type your feedback here...","isMultiline":true}],"actions":[{"type":"Action.Submit","title":"Submit Feedback"}]}\')}'
                shouldUpdateCard: true
                updateMessage: 'Thank you! Your feedback has been submitted.'
              }
            }
            path: '/flowbot/actions/flowcontinuation/recipienttypes/user'
          }
          runAfter: { Respond: ['Succeeded'] }
        }
        Notify_app: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '@{concat(parameters(\'callbackHost\'), \'/callback/feedback\')}'
            body: {
              itemId: '@triggerBody()?[\'itemId\']'
              itemName: '@triggerBody()?[\'itemName\']'
              correlationId: '@triggerBody()?[\'correlationId\']'
              feedback: '@body(\'Send_feedback_card\')?[\'data\']?[\'feedback\']'
            }
            headers: {
              'Content-Type': 'application/json'
              'x-ms-client-tracking-id': '@triggerBody()?[\'correlationId\']'
            }
          }
          runAfter: { Send_feedback_card: ['Succeeded'] }
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
  identity: {
    type: 'SystemAssigned'
  }
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
            { name: 'FEEDBACK_LOGIC_APP_URL', value: listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', feedbackLa.name, 'manual'), '2019-05-01').value }
            { name: 'AZURE_SUBSCRIPTION_ID', value: subscription().subscriptionId }
            { name: 'AZURE_RESOURCE_GROUP', value: resourceGroup().name }
            { name: 'INFO_LA_NAME', value: infoLaName }
            { name: 'REVIEW_LA_NAME', value: reviewLaName }
            { name: 'FEEDBACK_LA_NAME', value: feedbackLaName }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// Grant the Container App managed identity Reader access to view Logic App runs
resource acaReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, acaApp.id, 'Reader')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: acaApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// After ACA is created, update Logic Apps that need the real callback host
module updateCallbacks 'update-callback.bicep' = {
  name: 'update-callbacks'
  params: {
    reviewLaName: reviewLaName
    feedbackLaName: feedbackLaName
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
