#!/bin/sh
# Writes /alertmanager/alertmanager.yml from the environment, then starts
# Alertmanager. Every alert carries a `project` label; each project in
# $PROJECTS gets its own Telegram chat and e-mail address
# (TELEGRAM_CHAT_<PROJECT>, EMAIL_<PROJECT>), falling back to the ops ones.
# Anything without a known project goes to ops.
set -eu

out=/alertmanager/alertmanager.yml
upper() { echo "$1" | tr 'a-z-' 'A-Z_'; }
var() { eval "printf '%s' \"\${$1:-}\""; }

receiver() { # name chat email
	cat <<YAML
  - name: $1
    telegram_configs:
      - bot_token: '$TELEGRAM_BOT_TOKEN'
        chat_id: $2
        parse_mode: HTML
        message: '{{ template "overbrand.telegram" . }}'
        send_resolved: true
    email_configs:
      - to: '$3'
        headers:
          Subject: '{{ template "overbrand.subject" . }}'
        html: '{{ template "overbrand.email" . }}'
        send_resolved: true
YAML
}

{
	cat <<YAML
global:
  smtp_smarthost: '$SMTP_SMARTHOST'
  smtp_from: '$SMTP_FROM'
  smtp_auth_username: '${SMTP_USERNAME:-}'
  smtp_auth_password: '${SMTP_PASSWORD:-}'
  smtp_require_tls: true

templates:
  - /etc/alertmanager/templates/*.tmpl

route:
  receiver: ops
  group_by: [alertname, project, env, service]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    # Always firing: proves the whole chain works. Sent to an external
    # dead man's switch (HEARTBEAT_URL) that alerts when it stops arriving.
    - matchers: ['alertname="Watchdog"']
      receiver: heartbeat
      group_wait: 0s
      group_interval: 1m
      repeat_interval: 1m
YAML
	for p in ${PROJECTS:-}; do
		cat <<YAML
    - matchers: ['project="$p"']
      receiver: $p
YAML
	done

	cat <<YAML

inhibit_rules:
  # A whole agent silent: do not also page for everything it reported.
  - source_matchers: ['alertname="AgentSilent"']
    target_matchers: ['severity=~"warning|critical"']
    equal: [project, env]
  # A critical alert hides the warning version of the same thing.
  - source_matchers: ['severity="critical"']
    target_matchers: ['severity="warning"']
    equal: [alertname, project, env, service, instance]

receivers:
YAML
	receiver ops "$TELEGRAM_CHAT_OPS" "$EMAIL_OPS"
	for p in ${PROJECTS:-}; do
		P=$(upper "$p")
		chat=$(var "TELEGRAM_CHAT_$P"); email=$(var "EMAIL_$P")
		receiver "$p" "${chat:-$TELEGRAM_CHAT_OPS}" "${email:-$EMAIL_OPS}"
	done
	if [ -n "${HEARTBEAT_URL:-}" ]; then
		cat <<YAML
  - name: heartbeat
    webhook_configs:
      - url: '$HEARTBEAT_URL'
        send_resolved: false
YAML
	else
		echo "  - name: heartbeat"
	fi
} > "$out"

exec /bin/alertmanager \
	--config.file="$out" \
	--storage.path=/alertmanager \
	--web.external-url="https://${GRAFANA_DOMAIN:-localhost}/alerting/list" \
	--web.route-prefix=/
