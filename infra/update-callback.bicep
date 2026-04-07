// Re-deploys the Review and Feedback Logic Apps with the real ACA callback host.
// This is needed because there is a circular dependency:
// ACA needs the Logic App trigger URLs, and the Logic Apps need the ACA FQDN.
// Both Review and Feedback use the webhook wait pattern (ApiConnectionWebhook)
// and call back to the ACA when the user responds.
targetScope = 'resourceGroup'

param reviewLaName string
param feedbackLaName string
param location string
param teamsRecipient string
param teamsConnectionId string
param teamsConnectionApiId string
param callbackHost string

// --- Review Logic App (re-deploy with webhook wait pattern and real callback host) ---
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
          teams: { connectionId: teamsConnectionId, connectionName: 'teams', id: teamsConnectionApiId }
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
          teams: { connectionId: teamsConnectionId, connectionName: 'teams', id: teamsConnectionApiId }
        }
      }
    }
  }
}
