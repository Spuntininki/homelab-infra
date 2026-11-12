K3_TYPE ?= k3d
CLUSTER_NAME ?= homelab
VAULT_NETWORK ?= k3-$(CLUSTER_NAME)
ifeq ($(K3_TYPE),k3d)
  K3_ARGS ?= --servers 1 --network $(VAULT_NETWORK) --port "8080:80@loadbalancer" --port "8443:443@loadbalancer"
else
  K3_ARGS ?=
endif
REPO_URL ?= git@github.com:Spuntininki/homelab-infra.git
REPO_SECRET_NAME ?= homelab-infra-repo
REPO_SSH_KEY_FILE ?= $(HOME)/.ssh/id_ed25519_argocd
ARGOCD_VERSION ?= v3.4.4


VAULT_DIR ?= docker/vault
VAULT_TOKEN_FILE ?= $(VAULT_DIR)/eso-token.txt
VAULT_ADDR ?= http://127.0.0.1:8200
VAULT_TOKEN ?= root

.PHONY: help create delete recreate bootstrap status kubeconfig access test verify clean repo-secret \
  vault-up vault-down vault-bootstrap vault-status vault-token vault-k3s-routing \
  vault-put vault-get vault-list logs backup-setup backup-check backup-vault backup-k3s \
  backup restore backup-status

help:
	@printf '%s\n' "Targets:" \
		"  make create     Create the $(K3_TYPE) cluster (k3d) or install k3s" \
		"  make access     Configure persistent remote/local k3s API access" \
		"  make kubeconfig Update kubeconfig and switch context" \
		"  make test       Run script syntax checks and unit tests" \
		"  make bootstrap  Apply the Argo CD bootstrap" \
		"  make repo-secret Register the Git repository credential" \
		"  make status     Check cluster nodes, pods across namespaces, and Argo CD applications" \
		"  make verify     Run basic cluster checks" \
		"  make logs       Stream logs for specified app/service (APP=<name> [NS=<namespace>])" \
		"  make vault-put  Store secret in Vault (APP=<app> SECRET=<name> DATA=\"KEY=VAL...\")" \
		"  make vault-get  Retrieve secret from Vault (APP=<app> SECRET=<name> [FORMAT=json|kv])" \
		"  make vault-list List secrets in Vault [PATH_ARG=<path>]" \
		"  make backup     Run unified backup across Vault and K3s [ARGS=...]" \
		"  make restore    Restore Vault state and K3s volumes/databases [ARGS=...]" \
		"  make backup-status Inspect remote inventory and backup health [ARGS=...]" \
		"  make backup-setup Install/configure rclone and generate config from Vault" \
		"  make backup-check Verify connectivity to encrypted Google Drive remote" \
		"  make backup-vault Snapshot Vault storage, upload to remote, and prune old backups" \
		"  make backup-k3s Dump K3s databases, archive PVCs, and sync to remote [ARGS=...]" \
		"  make delete     Delete the $(K3_TYPE) cluster (k3d) or uninstall k3s" \
		"  make clean      Delete the cluster and prune kubeconfig entries" \
		"  make recreate   Delete, create, and bootstrap again" \
		"" \
		"Examples:" \
		"  make create                         # Uses k3d by default" \
		"  K3_TYPE=k3s K3S_NODE_IP=1.2.3.4 make create" \
		"  SERVER=k8s.sputinik.tech REMOTE_HOST=root@187.77.241.62 make access" \
		"  make vault-put APP=myapp SECRET=db DATA=\"host=localhost port=5432\"" \
		"  make vault-get APP=myapp SECRET=db" \
		"  make logs APP=cloudflared"

create:
ifeq ($(K3_TYPE),k3s)
	@test -n "$(K3S_NODE_IP)" || { echo "K3S_NODE_IP is required for k3s. Example: K3_TYPE=k3s K3S_NODE_IP=1.2.3.4 make create" >&2; exit 1; }
endif
ifeq ($(K3_TYPE),k3d)
	$(K3_TYPE) cluster create $(CLUSTER_NAME) $(K3_ARGS)
else ifeq ($(K3_TYPE),k3s)
	curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server $(K3_ARGS)" sh -
endif
	$(MAKE) kubeconfig K3S_NODE_IP=$(K3S_NODE_IP)
	$(MAKE) bootstrap
	$(MAKE) vault-up
	$(MAKE) vault-k3s-routing K3S_NODE_IP=$(K3S_NODE_IP)
	$(MAKE) vault-bootstrap

access:
	@./scripts/setup-access.sh \
		--cluster-name $(CLUSTER_NAME) \
		$(if $(SERVER),--server $(SERVER),$(if $(K3S_NODE_IP),--server $(K3S_NODE_IP),)) \
		$(if $(REMOTE_HOST),--remote-host $(REMOTE_HOST),) \
		$(if $(MERGE),--merge,) \
		$(if $(OUTPUT),--output $(OUTPUT),)

kubeconfig:
ifeq ($(K3_TYPE),k3d)
	$(K3_TYPE) kubeconfig merge $(CLUSTER_NAME) --kubeconfig-switch-context
else ifeq ($(K3_TYPE),k3s)
	@./scripts/setup-access.sh \
		--cluster-name $(CLUSTER_NAME) \
		$(if $(K3S_NODE_IP),--server $(K3S_NODE_IP),) \
		$(if $(REMOTE_HOST),--remote-host $(REMOTE_HOST),) \
		$(if $(MERGE),--merge,) \
		$(if $(OUTPUT),--output $(OUTPUT),)
endif

test:
	@bash -n scripts/setup-access.sh
	@bash -n scripts/setup-tailscale.sh
	@bash -n scripts/vault.sh
	@bash -n scripts/backup-setup.sh
	@bash -n scripts/backup-vault.sh
	@bash -n scripts/backup-k3s.sh
	@bash -n scripts/backup.sh
	@bash -n scripts/restore.sh
	@bash -n docker/vault/vault-bootstrap.sh
	@bash -n tests/test_observability.sh
	@./tests/test_setup_access.sh
	@./tests/test_mimirflow_app.sh
	@./tests/test_backup_setup.sh
	@./tests/test_backup_vault.sh
	@./tests/test_backup_k3s.sh
	@./tests/test_backup_restore.sh
	@./tests/test_observability.sh


bootstrap:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
	$(MAKE) repo-secret
	kubectl apply -k bootstrap/argocd

repo-secret:
	@test -f "$(REPO_SSH_KEY_FILE)"
	@printf '%s\n' "Using $(REPO_SSH_KEY_FILE) for Argo CD repo access. The key must be dedicated and passphrase-free."
	kubectl -n argocd create secret generic $(REPO_SECRET_NAME) \
		--from-literal=url="$(REPO_URL)" \
		--from-file=sshPrivateKey="$(REPO_SSH_KEY_FILE)" \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl -n argocd label secret $(REPO_SECRET_NAME) argocd.argoproj.io/secret-type=repository --overwrite

status:
	@echo "==> Cluster Nodes"
	@kubectl get nodes
	@echo ""
	@echo "==> Pods (All Namespaces)"
	@kubectl get pods -A
	@echo ""
	@echo "==> Argo CD Applications"
	@kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL,PATH:.spec.source.path 2>/dev/null || kubectl get applications -n argocd 2>/dev/null || echo "No Argo CD applications found or CRD not ready."

logs:
	@test -n "$(APP)" || test -n "$(ARGS)" || { \
		echo "Usage: make logs APP=<app_or_deployment> [NS=<namespace>] [TAIL=100]" >&2; \
		echo "Example: make logs APP=cloudflared" >&2; \
		echo "         make logs APP=argocd-server NS=argocd" >&2; \
		exit 1; \
	}
	@APP_TARGET="$${APP:-$${ARGS}}"; \
	NS_TARGET="$${NS:-$${APP_TARGET}}"; \
	TAIL_COUNT="$${TAIL:-100}"; \
	if kubectl get pods -n "$${NS_TARGET}" -l app="$${APP_TARGET}" --no-headers 2>/dev/null | grep -q .; then \
		kubectl logs -f -n "$${NS_TARGET}" -l app="$${APP_TARGET}" --all-containers=true --tail="$${TAIL_COUNT}" --prefix=true; \
	elif kubectl get pods -n "$${NS_TARGET}" -l app.kubernetes.io/name="$${APP_TARGET}" --no-headers 2>/dev/null | grep -q .; then \
		kubectl logs -f -n "$${NS_TARGET}" -l app.kubernetes.io/name="$${APP_TARGET}" --all-containers=true --tail="$${TAIL_COUNT}" --prefix=true; \
	elif kubectl get deployment "$${APP_TARGET}" -n "$${NS_TARGET}" >/dev/null 2>&1; then \
		kubectl logs -f deployment/"$${APP_TARGET}" -n "$${NS_TARGET}" --all-containers=true --tail="$${TAIL_COUNT}"; \
	elif [ "$${APP_TARGET}" = "vault" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "vault"; then \
		docker logs -f vault --tail="$${TAIL_COUNT}"; \
	else \
		kubectl logs -f "$${APP_TARGET}" -n "$${NS_TARGET}" --tail="$${TAIL_COUNT}"; \
	fi

verify:
	@echo "==> Kubernetes context"
	@kubectl config current-context
	@echo ""
	@echo "==> Nodes"
	@kubectl get nodes
	@echo ""
	@echo "==> Core platform workloads"
	@kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server
	@kubectl get pods -n cert-manager
	@kubectl get pods -n external-secrets
	@kubectl get pods -n cloudflared
	@echo ""
	@echo "==> Argo CD applications"
	@kubectl get applications -n argocd
	@echo ""
	@echo "==> Vault integration"
	@kubectl get clustersecretstore vault-backend
	@echo ""
	@echo "==> Ingresses"
	@kubectl get ingress -A

delete:
ifeq ($(K3_TYPE),k3d)
	$(K3_TYPE) cluster delete $(CLUSTER_NAME)
else ifeq ($(K3_TYPE),k3s)
	/usr/local/bin/k3s-uninstall.sh
endif
	kubectl config delete-context $(K3_TYPE)-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	kubectl config delete-cluster $(K3_TYPE)-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	kubectl config delete-user $(K3_TYPE)-$(CLUSTER_NAME) >/dev/null 2>&1 || true

recreate: delete create

# HashiCorp Vault (runs in Docker, outside the k3d cluster)
vault-up:
	@docker network inspect $(VAULT_NETWORK) >/dev/null 2>&1 || docker network create $(VAULT_NETWORK)
	docker compose -f $(VAULT_DIR)/docker-compose.yaml up -d

# On k3s, pods cannot reach the Vault Docker container by hostname. Create a Service + Endpoints
# in the external-secrets namespace so the External Secrets Operator can resolve 'vault:8200'.
vault-k3s-routing:
ifeq ($(K3_TYPE),k3s)
	@test -n "$(K3S_NODE_IP)" || { echo "K3S_NODE_IP is required for k3s Vault routing." >&2; exit 1; }
	@kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
	@printf '%s\n' \
		"apiVersion: v1" \
		"kind: Endpoints" \
		"metadata:" \
		"  name: vault" \
		"  namespace: external-secrets" \
		"subsets:" \
		"  - addresses:" \
		"      - ip: $(K3S_NODE_IP)" \
		"    ports:" \
		"      - port: 8200" \
		"---" \
		"apiVersion: v1" \
		"kind: Service" \
		"metadata:" \
		"  name: vault" \
		"  namespace: external-secrets" \
		"spec:" \
		"  ports:" \
		"    - port: 8200" \
		| kubectl apply -f -
endif

vault-down:
	docker compose -f $(VAULT_DIR)/docker-compose.yaml down

vault-bootstrap:
	VAULT_ADDR="$(VAULT_ADDR)" VAULT_TOKEN="$(VAULT_TOKEN)" ./$(VAULT_DIR)/vault-bootstrap.sh
	$(MAKE) vault-inject-token

vault-status:
	@if [ -n "$$(docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "vault")" ]; then \
		docker exec -e VAULT_ADDR="$(VAULT_ADDR)" vault vault status || true; \
	elif command -v vault >/dev/null 2>&1; then \
		VAULT_ADDR="$(VAULT_ADDR)" vault status || true; \
	else \
		curl -s "$(VAULT_ADDR)/v1/sys/health" | jq . 2>/dev/null || curl -s "$(VAULT_ADDR)/v1/sys/health" || true; \
	fi
vault-token:
	@test -f $(VAULT_TOKEN_FILE) && cat $(VAULT_TOKEN_FILE) || { echo "Token file not found. Run 'make vault-bootstrap' first." >&2; exit 0; }

vault-inject-token:
	@test -f $(VAULT_TOKEN_FILE) || { echo "Token file not found. Run 'make vault-bootstrap' first." >&2; exit 1; }
	kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic vault-token \
		-n external-secrets \
		--from-literal=token="$$(cat $(VAULT_TOKEN_FILE))" \
		--dry-run=client -o yaml | kubectl apply -f -

vault-put:
	@test -n "$(APP)" && test -n "$(SECRET)" && test -n "$(DATA)" || test -n "$(ARGS)" || { \
		echo "Usage: make vault-put APP=<app> SECRET=<secret_name> DATA=\"KEY=VAL...\"" >&2; \
		echo "   or: make vault-put ARGS=\"<app> <secret_name> KEY=VAL...\"" >&2; \
		exit 1; \
	}
	@if [ -n "$(ARGS)" ]; then \
		./scripts/vault.sh put $(ARGS); \
	else \
		./scripts/vault.sh put $(APP) $(SECRET) $(DATA); \
	fi

vault-get:
	@test -n "$(APP)" && test -n "$(SECRET)" || test -n "$(ARGS)" || { \
		echo "Usage: make vault-get APP=<app> SECRET=<secret_name> [FORMAT=json|kv]" >&2; \
		echo "   or: make vault-get ARGS=\"<app> <secret_name>\"" >&2; \
		exit 1; \
	}
	@if [ -n "$(ARGS)" ]; then \
		./scripts/vault.sh get $(ARGS); \
	else \
		./scripts/vault.sh get $(APP) $(SECRET) $(if $(FORMAT),--format $(FORMAT),); \
	fi

vault-list:
	@./scripts/vault.sh list $(PATH_ARG)$(ARGS)

backup-setup:
	@./scripts/backup-setup.sh

backup-check:
	@./scripts/backup-setup.sh check

backup-vault:
	@./scripts/backup-vault.sh $(if $(REMOTE),--remote $(REMOTE),) $(if $(DEST),--dest $(DEST),) $(if $(DRY_RUN),--dry-run,) $(ARGS)

backup-k3s:
	@./scripts/backup-k3s.sh $(ARGS)

backup:
	@./scripts/backup.sh $(if $(REMOTE),--remote $(REMOTE),) $(if $(DRY_RUN),--dry-run,) $(ARGS)

restore:
	@./scripts/restore.sh $(if $(REMOTE),--remote $(REMOTE),) $(if $(TARGET_DIR),--target-dir $(TARGET_DIR),) $(if $(DRY_RUN),--dry-run,) $(ARGS)

backup-status:
	@./scripts/backup.sh status $(if $(REMOTE),--remote $(REMOTE),) $(ARGS)

