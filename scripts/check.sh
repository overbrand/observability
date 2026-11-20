#!/usr/bin/env bash
# Validates every config with the tool that will run it. Needs only Docker.
#
#   scripts/check.sh
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

PROM_IMAGE=prom/prometheus:v2.55.1
AM_IMAGE=prom/alertmanager:v0.27.0
LOKI_IMAGE=grafana/loki:3.3.2
ALLOY_IMAGE=grafana/alloy:v1.21.3

echo "── Prometheus rules"
rules=()
for f in grafana/alerts/prometheus/*.yml; do rules+=("/rules/$(basename "$f")"); done
docker run --rm --entrypoint promtool -v "$root/grafana/alerts/prometheus:/rules:ro" \
	"$PROM_IMAGE" check rules "${rules[@]}"

echo "── Prometheus config"
docker run --rm --entrypoint promtool \
	-v "$root/server/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
	-v "$root/grafana/alerts/prometheus:/etc/prometheus/rules:ro" \
	-v "$root/uptime:/etc/prometheus/uptime:ro" \
	"$PROM_IMAGE" check config /etc/prometheus/prometheus.yml

echo "── Alertmanager (rendered with test values)"
docker run --rm --entrypoint /bin/sh -v "$root/server/alertmanager:/etc/alertmanager:ro" \
	-e TELEGRAM_BOT_TOKEN=000:test -e TELEGRAM_CHAT_OPS=-1 -e EMAIL_OPS=ops@example.com \
	-e SMTP_SMARTHOST=smtp.example.com:587 -e SMTP_FROM=alerts@example.com -e PROJECTS="bns eventez" \
	-e TELEGRAM_CHAT_BNS=-2 -e HEARTBEAT_URL=https://hc-ping.com/test \
	"$AM_IMAGE" -c 'sed "s|^exec /bin/alertmanager|amtool check-config \$out; exit; #|" /etc/alertmanager/render.sh > /tmp/r.sh && sh /tmp/r.sh'

echo "── Loki config"
docker run --rm -e LOGS_RETENTION=336h -v "$root/server/loki/loki.yml:/etc/loki/loki.yml:ro" \
	"$LOKI_IMAGE" -config.file=/etc/loki/loki.yml -config.expand-env=true -verify-config
echo "OK"

echo "── Alloy (docker agent) syntax"
docker run --rm -v "$root/agents/alloy-docker/config.alloy:/c.alloy:ro" "$ALLOY_IMAGE" fmt /c.alloy >/dev/null
echo "OK"

echo "── Compose files"
envfile="$(mktemp)"
trap 'rm -f "$envfile"' EXIT
sed 's/=$/=x/' server/.env.example > "$envfile"
docker compose --env-file "$envfile" -f server/docker-compose.yml config -q
PROJECT=x ENV=x HOST_NAME=x INGEST_USER=x INGEST_PASSWORD=x \
	docker compose -f agents/alloy-docker/docker-compose.yml config -q
echo "OK"

echo "── Dashboards are valid JSON"
for f in grafana/dashboards/*/*.json; do
	python3 -m json.tool "$f" >/dev/null 2>&1 || { echo "invalid JSON: $f"; exit 1; }
done
echo "OK"

echo "✓ all configs valid"
