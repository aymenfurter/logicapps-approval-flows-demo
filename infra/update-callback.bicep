// Re-deploys the review Logic App with the real ACA callback host.
// This is needed because there is a circular dependency:
// ACA needs the Logic App trigger URL, and the Logic App needs the ACA FQDN.
targetScope = 'resourceGroup'

param logicAppName string
param location string
param teamsRecipient string
param teamsConnectionId string
param teamsConnectionApiId string
param callbackHost string

resource reviewLa 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': { defaultValue: {}, type: 'Object' }
        teamsRecipient: { defaultValue: teamsRecipient, type: 'String' }
        callbackHost: { defaultValue: callbackHost, type: 'String' }
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
          teams: { connectionId: teamsConnectionId, connectionName: 'teams', id: teamsConnectionApiId }
        }
      }
    }
  }
}
