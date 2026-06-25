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

.PHONY: help create delete recreate bootstrap status kubeconfig verify clean repo-secret \
  vault-up vault-down vault-bootstrap vault-status vault-token vault-k3s-routing

help:
	@printf '%s\n' "Targets:" \
		"  make create     Create the $(K3_TYPE) cluster (k3d) or install k3s" \
		"  make kubeconfig Update kubeconfig and switch context" \
		"  make bootstrap  Apply the Argo CD bootstrap" \
		"  make repo-secret Register the Git repository credential" \
		"  make status     Show Argo CD applications" \
		"  make verify     Run basic cluster checks" \
		"  make delete     Delete the $(K3_TYPE) cluster (k3d) or uninstall k3s" \
		"  make clean      Delete the cluster and prune kubeconfig entries" \
		"  make recreate   Delete, create, and bootstrap again" \
		"" \
		"Examples:" \
		"  make create                         # Uses k3d by default" \
		"  K3_TYPE=k3s K3S_NODE_IP=1.2.3.4 make create"

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

kubeconfig:
ifeq ($(K3_TYPE),k3d)
	$(K3_TYPE) kubeconfig merge $(CLUSTER_NAME) --kubeconfig-switch-context
else ifeq ($(K3_TYPE),k3s)
	@test -n "$(K3S_NODE_IP)" || { echo "K3S_NODE_IP is required for k3s kubeconfig. Example: K3S_NODE_IP=1.2.3.4 make kubeconfig" >&2; exit 1; }
	mkdir -p $(HOME)/.kube
	sudo cp /etc/rancher/k3s/k3s.yaml $(HOME)/.kube/config-k3s-$(CLUSTER_NAME)
	sudo chown $(USER):$(USER) $(HOME)/.kube/config-k3s-$(CLUSTER_NAME)
	sed -i 's/127\.0\.0\.1/$(K3S_NODE_IP)/g' $(HOME)/.kube/config-k3s-$(CLUSTER_NAME)
	cp $(HOME)/.kube/config-k3s-$(CLUSTER_NAME) $(HOME)/.kube/config
	chmod 600 $(HOME)/.kube/config
	@echo "Kubeconfig saved to $(HOME)/.kube/config"
endif

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
	kubectl get nodes
	kubectl get pods -n argocd
	kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL,PATH:.spec.source.path

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
	./$(VAULT_DIR)/vault-bootstrap.sh
	$(MAKE) vault-inject-token

vault-status:
	@docker exec -e VAULT_ADDR=http://127.0.0.1:8200 vault vault status || true
vault-token:
	@test -f $(VAULT_TOKEN_FILE) && cat $(VAULT_TOKEN_FILE) || { echo "Token file not found. Run 'make vault-bootstrap' first." >&2; exit 0; }

vault-inject-token:
	@test -f $(VAULT_TOKEN_FILE) || { echo "Token file not found. Run 'make vault-bootstrap' first." >&2; exit 1; }
	kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic vault-token \
		-n external-secrets \
		--from-literal=token="$$(cat $(VAULT_TOKEN_FILE))" \
		--dry-run=client -o yaml | kubectl apply -f -