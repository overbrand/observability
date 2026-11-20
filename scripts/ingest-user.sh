#!/usr/bin/env bash
# Creates the ingest credential of one agent (one per machine or cluster).
#
#   scripts/ingest-user.sh eventez-vps
#
# Prints the password (for the agent's INGEST_PASSWORD, or BNS's
# observabilityIngestPassword) and the htpasswd entry to append to the
# central stack's INGEST_USERS (comma-separated). Revoking an agent =
# removing its entry and redeploying the central stack.
set -euo pipefail
name="${1:?usage: scripts/ingest-user.sh <agent-name>}"
[[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "name: lowercase letters, digits and dashes only" >&2; exit 1; }
password="$(openssl rand -hex 24)"
entry="$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$name" "$password" | tr -d '\n')"
cat <<OUT
Agent ${name}
  INGEST_USER=${name}
  INGEST_PASSWORD=${password}

Central stack: append this entry to INGEST_USERS (comma-separated, keep the
single quotes in the env file so the \$ signs stay literal):
  ${entry}
OUT
