#!/bin/bash
#
# A wrapper for docker-compose that loads secrets from AWS
# and then executes the docker compose command.
#
# NOTE: Base configuration is now loaded automatically by docker-compose from the .env file.
#
# Usage: ./aws-compose.sh [docker-compose arguments]
# Example: ./aws-compose.sh up -d

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd ..

# --- Step 1: Load secrets from AWS Secrets Manager ---
echo "🔐 Loading secrets from AWS Secrets Manager..."

# Configuration
export REGION="us-east-1"
export DB_SECRET_ID="prod/agn/mastodon-db"
export SMTP_SECRET_ID="prod/agn/mastodon-smtp"
export APP_SECRET_ID="prod/agn/mastodon-app"

# Fetch and Export Database Secrets
DB_SECRETS_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ID" --region "$REGION" --query SecretString --output text)
export DB_USER=$(echo "$DB_SECRETS_JSON" | jq -r .username)
export DB_PASS=$(echo "$DB_SECRETS_JSON" | jq -r .password)
export POSTGRES_USER=$DB_USER
export POSTGRES_PASSWORD=$DB_PASS

# Fetch and Export SMTP Secrets
SMTP_SECRETS_JSON=$(aws secretsmanager get-secret-value --secret-id "$SMTP_SECRET_ID" --region "$REGION" --query SecretString --output text)
export SMTP_LOGIN=$(echo "$SMTP_SECRETS_JSON" | jq -r .username)
export SMTP_PASSWORD=$(echo "$SMTP_SECRETS_JSON" | jq -r .password)

# Fetch and Export Application Secrets
APP_SECRETS_JSON=$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_ID" --region "$REGION" --query SecretString --output text)
export SECRET_KEY_BASE=$(echo "$APP_SECRETS_JSON" | jq -r .secret_key_base)
export VAPID_PRIVATE_KEY=$(echo "$APP_SECRETS_JSON" | jq -r .vapid_private_key)
export VAPID_PUBLIC_KEY=$(echo "$APP_SECRETS_JSON" | jq -r .vapid_public_key)
export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(echo "$APP_SECRETS_JSON" | jq -r .active_record_encryption_deterministic_key)
export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(echo "$APP_SECRETS_JSON" | jq -r .active_record_encryption_key_derivation_salt)
export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(echo "$APP_SECRETS_JSON" | jq -r .active_record_encryption_primary_key)

# --- Step 2: Execute docker-compose ---
echo "🚀 Executing: docker compose $@"
docker compose "$@"