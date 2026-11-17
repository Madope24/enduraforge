#!/usr/bin/env bash
# Runs on the GitHub runner (deploy and rollback workflows). Copies the server files to ~/$STACK over SSH,
# optionally backs up the database, logs in to GHCR for the pull, and runs deploy.sh there.
#   Needed env: SSH_HOST SSH_USER SSH_KEY STACK API_IMAGE POSTGRES_PASSWORD JWT_SECRET APP_PORT
#   Optional:   SSH_PORT (22) BACKUP_FIRST REGISTRATION_MODE REGISTRY_USER REGISTRY_TOKEN
set -euo pipefail
: "${SSH_HOST:?}" "${SSH_USER:?}" "${SSH_KEY:?}" "${STACK:?}" "${API_IMAGE:?}" "${POSTGRES_PASSWORD:?}" "${JWT_SECRET:?}" "${APP_PORT:?}"
cd "$(dirname "$0")"

KEY=$(mktemp)
trap 'rm -f "$KEY"' EXIT
printf '%s\n' "$SSH_KEY" | tr -d '\r' > "$KEY"
chmod 600 "$KEY"
SSH_OPTS=(-i "$KEY" -p "${SSH_PORT:-22}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15)
TARGET="$SSH_USER@$SSH_HOST"

# single-quote a value for the remote sh
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

echo "Copying server files to ~/$STACK"
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p ~/$STACK"
tar cf - docker-compose.yml deploy.sh backup.sh | ssh "${SSH_OPTS[@]}" "$TARGET" "cd ~/$STACK && tar xf - && chmod +x deploy.sh backup.sh"

if [ -n "${REGISTRY_TOKEN:-}" ]; then
  printf '%s' "$REGISTRY_TOKEN" | ssh "${SSH_OPTS[@]}" "$TARGET" "docker login ghcr.io -u $(q "${REGISTRY_USER:-github}") --password-stdin" >/dev/null
fi

if [ -n "${BACKUP_FIRST:-}" ]; then
  echo "Backing up the $STACK database"
  ssh "${SSH_OPTS[@]}" "$TARGET" "cd ~/$STACK && if docker compose -p $STACK ps --status running db 2>/dev/null | grep -q db; then STACK=$STACK ./backup.sh && ls -1t backups | head -1; else echo 'no running database yet, skipping backup'; fi"
fi

ENV_LINES="STACK=$(q "$STACK") API_IMAGE=$(q "$API_IMAGE") POSTGRES_PASSWORD=$(q "$POSTGRES_PASSWORD") JWT_SECRET=$(q "$JWT_SECRET") APP_PORT=$(q "$APP_PORT") REGISTRATION_MODE=$(q "${REGISTRATION_MODE:-first-only}")"
status=0
# secrets go over stdin, never on the remote command line
printf 'export %s\n' "$ENV_LINES" | ssh "${SSH_OPTS[@]}" "$TARGET" "cd ~/$STACK && umask 077 && cat > .deploy.env && set -a && . ./.deploy.env && rm -f .deploy.env && set +a && sh ./deploy.sh" || status=$?

if [ -n "${REGISTRY_TOKEN:-}" ]; then
  ssh "${SSH_OPTS[@]}" "$TARGET" "docker logout ghcr.io" >/dev/null 2>&1 || true
fi
exit $status
