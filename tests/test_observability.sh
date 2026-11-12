#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MON_APP_FILE="${REPO_ROOT}/apps/platform/monitoring/application.yaml"
MON_KUST_FILE="${REPO_ROOT}/apps/platform/monitoring/kustomization.yaml"
LOKI_APP_FILE="${REPO_ROOT}/apps/platform/loki/application.yaml"
PROMTAIL_APP_FILE="${REPO_ROOT}/apps/platform/loki/promtail.yaml"
LOKI_KUST_FILE="${REPO_ROOT}/apps/platform/loki/kustomization.yaml"
DASHBOARD_FILE="${REPO_ROOT}/templates/app-base/dashboards/overview.json"
APP_BASE_KUST_FILE="${REPO_ROOT}/templates/app-base/kustomization.yaml"
APP_BASE_DEPLOY_FILE="${REPO_ROOT}/templates/app-base/deployment.yaml"

TESTS_RUN=0
TESTS_PASSED=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

assert_file_exists() {
  local file="$1"
  local msg="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -f "$file" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (file not found: $file)" >&2
    exit 1
  fi
}

assert_true() {
  local condition="$1"
  local msg="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$condition" == "true" || "$condition" == "True" || "$condition" == "0" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg" >&2
    exit 1
  fi
}

echo "Running tests for observability manifests, metrics, logs, and dashboard discovery..."

assert_file_exists "$MON_APP_FILE" "Monitoring Application manifest exists"
assert_file_exists "$MON_KUST_FILE" "Monitoring kustomization exists"
assert_file_exists "$LOKI_APP_FILE" "Loki Application manifest exists"
assert_file_exists "$PROMTAIL_APP_FILE" "Promtail Application manifest exists"
assert_file_exists "$LOKI_KUST_FILE" "Loki kustomization exists"
assert_file_exists "$DASHBOARD_FILE" "Overview dashboard template exists"
assert_file_exists "$APP_BASE_KUST_FILE" "App-base kustomization exists"
assert_file_exists "$APP_BASE_DEPLOY_FILE" "App-base deployment manifest exists"

PLATFORM_BUILD_OUTPUT=$(kustomize build "${REPO_ROOT}/apps/platform")
assert_true "$?" "kustomize build apps/platform succeeds"

PLATFORM_CHECK=$(python3 -c "
import sys, yaml
docs = list(yaml.safe_load_all('''${PLATFORM_BUILD_OUTPUT}'''))
names = {d.get('metadata', {}).get('name') for d in docs if d}
has_mon = 'monitoring' in names
has_loki = 'loki' in names
has_promtail = 'promtail' in names
print(f'{has_mon}|{has_loki}|{has_promtail}')
")

IFS='|' read -r HAS_MON HAS_LOKI HAS_PROMTAIL <<< "$PLATFORM_CHECK"
assert_eq "True" "$HAS_MON" "apps/platform generates monitoring Application"
assert_eq "True" "$HAS_LOKI" "apps/platform generates loki Application"
assert_eq "True" "$HAS_PROMTAIL" "apps/platform generates promtail Application"

MON_PARSED=$(python3 -c "
import yaml

with open('${MON_APP_FILE}') as f:
    app = yaml.safe_load(f)

chart = app['spec']['source']['chart']
repo_url = app['spec']['source']['repoURL']
target_ns = app['spec']['destination']['namespace']

values = yaml.safe_load(app['spec']['source']['helm']['values'])
release_name = app['spec']['source']['helm']['releaseName']

ing = values['grafana']['ingress']
ing_enabled = ing.get('enabled')
ing_host = ing.get('hosts', [None])[0]
ing_tls_secret = ing.get('tls', [{}])[0].get('secretName')
ing_entrypoint = ing.get('annotations', {}).get('traefik.ingress.kubernetes.io/router.entrypoints')

sidecar_dash = values['grafana']['sidecar']['dashboards']
sidecar_enabled = sidecar_dash.get('enabled')
sidecar_label = sidecar_dash.get('label')
sidecar_val = str(sidecar_dash.get('labelValue'))
sidecar_ns = sidecar_dash.get('searchNamespace')

grafana_persist_enabled = values['grafana']['persistence'].get('enabled')
grafana_storage_class = values['grafana']['persistence'].get('storageClassName')

prom_storage_class = values['prometheus']['prometheusSpec']['storageSpec']['volumeClaimTemplate']['spec'].get('storageClassName')
prom_retention = values['prometheus']['prometheusSpec'].get('retention')
prom_retention_size = values['prometheus']['prometheusSpec'].get('retentionSize')
am_config_secret = values.get('alertmanager', {}).get('alertmanagerSpec', {}).get('configSecret')

loki_ds = next((ds for ds in values['grafana'].get('additionalDataSources', []) if ds.get('name') == 'Loki'), {})
loki_ds_type = loki_ds.get('type')
loki_ds_url = loki_ds.get('url')

print(f'{chart}|{repo_url}|{target_ns}|{release_name}|{ing_enabled}|{ing_host}|{ing_tls_secret}|{ing_entrypoint}|{sidecar_enabled}|{sidecar_label}|{sidecar_val}|{sidecar_ns}|{grafana_persist_enabled}|{grafana_storage_class}|{prom_storage_class}|{prom_retention}|{prom_retention_size}|{am_config_secret}|{loki_ds_type}|{loki_ds_url}')
")

IFS='|' read -r \
  MON_CHART MON_REPO MON_NS MON_RELEASE \
  MON_ING_ENABLED MON_ING_HOST MON_ING_TLS MON_ING_ENTRYPOINT \
  MON_SC_ENABLED MON_SC_LABEL MON_SC_VAL MON_SC_NS \
  MON_GRAFANA_PERSIST MON_GRAFANA_SC MON_PROM_SC MON_PROM_RETENTION MON_PROM_RETENTION_SIZE MON_AM_CONFIG_SECRET \
  MON_LOKI_DS_TYPE MON_LOKI_DS_URL <<< "$MON_PARSED"

assert_eq "kube-prometheus-stack" "$MON_CHART" "Monitoring chart is kube-prometheus-stack"
assert_eq "https://prometheus-community.github.io/helm-charts" "$MON_REPO" "Monitoring repo URL matches official helm repository"
assert_eq "monitoring" "$MON_NS" "Monitoring destination namespace is monitoring"
assert_eq "monitoring" "$MON_RELEASE" "Monitoring release name is monitoring"
assert_eq "True" "$MON_ING_ENABLED" "Grafana ingress is enabled"
assert_eq "grafana.sputinik.tech" "$MON_ING_HOST" "Grafana ingress host is grafana.sputinik.tech"
assert_eq "grafana-server-tls" "$MON_ING_TLS" "Grafana TLS secret is grafana-server-tls"
assert_eq "websecure" "$MON_ING_ENTRYPOINT" "Grafana ingress uses websecure entrypoint"
assert_eq "True" "$MON_SC_ENABLED" "Grafana sidecar dashboard discovery is enabled"
assert_eq "grafana_dashboard" "$MON_SC_LABEL" "Grafana sidecar dashboard label is grafana_dashboard"
assert_eq "1" "$MON_SC_VAL" "Grafana sidecar dashboard label value is 1"
assert_eq "ALL" "$MON_SC_NS" "Grafana sidecar dashboard searchNamespace is ALL"
assert_eq "True" "$MON_GRAFANA_PERSIST" "Grafana persistence is enabled"
assert_eq "local-path" "$MON_GRAFANA_SC" "Grafana persistence storageClassName is local-path"
assert_eq "local-path" "$MON_PROM_SC" "Prometheus storageClassName is local-path"
assert_eq "15d" "$MON_PROM_RETENTION" "Prometheus retention is 15d"
assert_eq "20GiB" "$MON_PROM_RETENTION_SIZE" "Prometheus retentionSize is 20GiB"
assert_eq "alertmanager-telegram-config" "$MON_AM_CONFIG_SECRET" "Alertmanager configSecret is alertmanager-telegram-config"
assert_eq "loki" "$MON_LOKI_DS_TYPE" "Grafana Loki datasource type is loki"
assert_eq "http://loki.loki.svc:3100" "$MON_LOKI_DS_URL" "Grafana Loki datasource connects to http://loki.loki.svc:3100"

MON_ES_FILE="${REPO_ROOT}/apps/platform/monitoring/external-secret.yaml"
assert_file_exists "$MON_ES_FILE" "Monitoring ExternalSecret file exists"

MON_ES_PARSED=$(python3 - "${MON_ES_FILE}" << 'EOF'
import sys
import yaml

with open(sys.argv[1]) as f:
    es = yaml.safe_load(f)

store_name = es['spec']['secretStoreRef']['name']
target_name = es['spec']['target']['name']
vault_key_bot = next(d['remoteRef']['key'] for d in es['spec']['data'] if d['secretKey'] == 'bot_token')
vault_prop_bot = next(d['remoteRef']['property'] for d in es['spec']['data'] if d['secretKey'] == 'bot_token')
vault_key_chat = next(d['remoteRef']['key'] for d in es['spec']['data'] if d['secretKey'] == 'chat_id')
vault_prop_chat = next(d['remoteRef']['property'] for d in es['spec']['data'] if d['secretKey'] == 'chat_id')
template_yaml = es['spec']['target']['template']['data']['alertmanager.yaml']

has_telegram_receiver = "telegram_configs:" in template_yaml
has_watchdog_null = 'alertname = "Watchdog"' in template_yaml and "receiver: 'null'" in template_yaml

print(f'{store_name}|{target_name}|{vault_key_bot}|{vault_prop_bot}|{vault_key_chat}|{vault_prop_chat}|{has_telegram_receiver}|{has_watchdog_null}')
EOF
)

IFS='|' read -r \
  ES_STORE ES_TARGET ES_VK_BOT ES_VP_BOT ES_VK_CHAT ES_VP_CHAT ES_HAS_TG ES_HAS_WATCHDOG <<< "$MON_ES_PARSED"

assert_eq "vault-backend" "$ES_STORE" "ExternalSecret references vault-backend ClusterSecretStore"
assert_eq "alertmanager-telegram-config" "$ES_TARGET" "ExternalSecret target secret is alertmanager-telegram-config"
assert_eq "secret/monitoring/telegram" "$ES_VK_BOT" "Bot token Vault key is secret/monitoring/telegram"
assert_eq "bot_token" "$ES_VP_BOT" "Bot token Vault property is bot_token"
assert_eq "secret/monitoring/telegram" "$ES_VK_CHAT" "Chat ID Vault key is secret/monitoring/telegram"
assert_eq "chat_id" "$ES_VP_CHAT" "Chat ID Vault property is chat_id"
assert_eq "True" "$ES_HAS_TG" "Alertmanager template includes telegram_configs"
assert_eq "True" "$ES_HAS_WATCHDOG" "Alertmanager template suppresses Watchdog to null"

LOKI_PROMTAIL_PARSED=$(python3 -c "
import yaml

with open('${LOKI_APP_FILE}') as f:
    loki_app = yaml.safe_load(f)

loki_chart = loki_app['spec']['source']['chart']
loki_repo = loki_app['spec']['source']['repoURL']
loki_ns = loki_app['spec']['destination']['namespace']

loki_val = yaml.safe_load(loki_app['spec']['source']['helm']['values'])
deploy_mode = loki_val.get('deploymentMode')
retention_enabled = loki_val.get('loki', {}).get('compactor', {}).get('retention_enabled')
retention_period = loki_val.get('loki', {}).get('limits_config', {}).get('retention_period')
loki_persist_enabled = loki_val.get('singleBinary', {}).get('persistence', {}).get('enabled')
loki_storage_class = loki_val.get('singleBinary', {}).get('persistence', {}).get('storageClass')

with open('${PROMTAIL_APP_FILE}') as f:
    prom_app = yaml.safe_load(f)

prom_chart = prom_app['spec']['source']['chart']
prom_repo = prom_app['spec']['source']['repoURL']
prom_ns = prom_app['spec']['destination']['namespace']

prom_val = yaml.safe_load(prom_app['spec']['source']['helm']['values'])
prom_client_url = prom_val.get('config', {}).get('clients', [{}])[0].get('url')

print(f'{loki_chart}|{loki_repo}|{loki_ns}|{deploy_mode}|{retention_enabled}|{retention_period}|{loki_persist_enabled}|{loki_storage_class}|{prom_chart}|{prom_repo}|{prom_ns}|{prom_client_url}')
")

IFS='|' read -r \
  LOKI_CHART LOKI_REPO LOKI_NS LOKI_DEPLOY_MODE \
  LOKI_RETENTION_ENABLED LOKI_RETENTION_PERIOD \
  LOKI_PERSIST_ENABLED LOKI_STORAGE_CLASS \
  PROM_CHART PROM_REPO PROM_NS PROM_CLIENT_URL <<< "$LOKI_PROMTAIL_PARSED"

assert_eq "loki" "$LOKI_CHART" "Loki chart is loki"
assert_eq "https://grafana.github.io/helm-charts" "$LOKI_REPO" "Loki repo URL matches official helm repository"
assert_eq "loki" "$LOKI_NS" "Loki destination namespace is loki"
assert_eq "SingleBinary" "$LOKI_DEPLOY_MODE" "Loki deploymentMode is SingleBinary"
assert_eq "True" "$LOKI_RETENTION_ENABLED" "Loki compactor retention is enabled"
assert_eq "168h" "$LOKI_RETENTION_PERIOD" "Loki retention period is 168h (7 days)"
assert_eq "True" "$LOKI_PERSIST_ENABLED" "Loki persistence is enabled"
assert_eq "local-path" "$LOKI_STORAGE_CLASS" "Loki storageClass is local-path"
assert_eq "promtail" "$PROM_CHART" "Promtail chart is promtail"
assert_eq "https://grafana.github.io/helm-charts" "$PROM_REPO" "Promtail repo URL matches official helm repository"
assert_eq "loki" "$PROM_NS" "Promtail destination namespace is loki"
assert_eq "http://loki.loki.svc:3100/loki/api/v1/push" "$PROM_CLIENT_URL" "Promtail client push URL is Loki gateway endpoint"

DASHBOARD_PARSED=$(python3 -c "
import json

with open('${DASHBOARD_FILE}') as f:
    dash = json.load(f)

uid = dash.get('uid')
title = dash.get('title')
panels_count = len(dash.get('panels', []))
has_panels = panels_count > 0

print(f'{uid}|{title}|{has_panels}|{panels_count}')
")

IFS='|' read -r DASH_UID DASH_TITLE DASH_HAS_PANELS DASH_PANELS_COUNT <<< "$DASHBOARD_PARSED"

assert_eq "app-template-overview" "$DASH_UID" "Dashboard UID is app-template-overview"
assert_eq "Application Overview" "$DASH_TITLE" "Dashboard title is Application Overview"
assert_eq "True" "$DASH_HAS_PANELS" "Dashboard contains configured visualization panels"

APP_BASE_BUILD_OUTPUT=$(kustomize build "${REPO_ROOT}/templates/app-base")
assert_true "$?" "kustomize build templates/app-base succeeds"

APP_BASE_PARSED=$(python3 -c "
import yaml

docs = list(yaml.safe_load_all('''${APP_BASE_BUILD_OUTPUT}'''))
cm = next((d for d in docs if d and d.get('kind') == 'ConfigMap'), {})
cm_label = cm.get('metadata', {}).get('labels', {}).get('grafana_dashboard')
cm_data_keys = list(cm.get('data', {}).keys())
has_overview_json = 'overview.json' in cm_data_keys

deploy = next((d for d in docs if d and d.get('kind') == 'Deployment'), {})
ann = deploy.get('spec', {}).get('template', {}).get('metadata', {}).get('annotations', {})
scrape = ann.get('prometheus.io/scrape')
port = ann.get('prometheus.io/port')
path = ann.get('prometheus.io/path')

print(f'{cm_label}|{has_overview_json}|{scrape}|{port}|{path}')
")

IFS='|' read -r CM_LABEL CM_HAS_OVERVIEW DEPLOY_SCRAPE DEPLOY_PORT DEPLOY_PATH <<< "$APP_BASE_PARSED"

assert_eq "1" "$CM_LABEL" "Generated ConfigMap has label grafana_dashboard: '1'"
assert_eq "True" "$CM_HAS_OVERVIEW" "Generated ConfigMap contains overview.json"
assert_eq "true" "$DEPLOY_SCRAPE" "Deployment metadata annotation prometheus.io/scrape is 'true'"
assert_eq "8080" "$DEPLOY_PORT" "Deployment metadata annotation prometheus.io/port is '8080'"
assert_eq "/metrics" "$DEPLOY_PATH" "Deployment metadata annotation prometheus.io/path is '/metrics'"

echo "All ${TESTS_PASSED}/${TESTS_RUN} observability verification tests passed successfully."
