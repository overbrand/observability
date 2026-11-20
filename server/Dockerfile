# The configuration of each service, baked into its image (build context: the
# repository root). Dokploy re-clones the repository on every deploy and runs
# `docker compose up --build`: a bind mount would keep pointing at the deleted
# copy in any container that is not recreated, an image always has the
# current files.

FROM grafana/grafana:11.3.1 AS grafana
COPY server/grafana/provisioning /etc/grafana/provisioning
# Not under /var/lib/grafana: that is the data volume, which would hide them.
COPY grafana/dashboards /etc/grafana/dashboards

FROM prom/prometheus:v2.55.1 AS prometheus
COPY server/prometheus/prometheus.yml /etc/prometheus/prometheus.yml
COPY grafana/alerts/prometheus /etc/prometheus/rules
COPY uptime /etc/prometheus/uptime

FROM grafana/loki:3.3.2 AS loki
COPY server/loki/loki.yml /etc/loki/loki.yml
# Single tenant ("fake" while auth is off): its rules live in that folder.
COPY grafana/alerts/loki /etc/loki/rules/fake

FROM prom/alertmanager:v0.27.0 AS alertmanager
COPY server/alertmanager/render.sh /etc/alertmanager/render.sh
COPY server/alertmanager/templates /etc/alertmanager/templates

FROM prom/blackbox-exporter:v0.25.0 AS blackbox
COPY server/blackbox/blackbox.yml /etc/blackbox/blackbox.yml
