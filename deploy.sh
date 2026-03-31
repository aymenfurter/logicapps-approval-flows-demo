#!/usr/bin/env bash
set -euo pipefail

RG="rg-workflow-notifications"
LOCATION="westeurope"
BASE_NAME="wfnotify"
RECIPIENT="${1:?Usage: ./deploy.sh <teams-recipient-email>}"
ACR_NAME="${BASE_NAME}acr"
IMAGE_TAG="${ACR_NAME}.azurecr.io/demo-app:latest"

echo "==> Creating resource group..."
az group create --name "$RG" --location "$LOCATION" -o none

echo "==> Ensuring ACR exists..."
az acr show --name "$ACR_NAME" -o none 2>/dev/null || \
  az acr create --name "$ACR_NAME" --resource-group "$RG" --sku Basic --admin-enabled true -o none

echo "==> Building and pushing container image (linux/amd64)..."
az acr build --registry "$ACR_NAME" --image demo-app:latest --platform linux/amd64 ./app

echo "==> Deploying infrastructure..."
az deployment group create \
  --resource-group "$RG" \
  --template-file infra/main.bicep \
  --parameters baseName="$BASE_NAME" teamsRecipient="$RECIPIENT" containerImage="$IMAGE_TAG" \
  --query "properties.outputs" -o json

APP_URL=$(az deployment group show --resource-group "$RG" --name main \
  --query "properties.outputs.appUrl.value" -o tsv)

echo ""
echo "============================================"
echo "Deployment complete!"
echo "App URL: $APP_URL"
echo ""
echo "IMPORTANT: Authorize the Teams connection:"
CONN_ID=$(az resource show --resource-group "$RG" --resource-type "Microsoft.Web/connections" --name "${BASE_NAME}-teams" --query id -o tsv)
echo "https://portal.azure.com/#@/resource${CONN_ID}/edit"
echo ""
echo "After authorizing, open $APP_URL to test."
echo "============================================"
