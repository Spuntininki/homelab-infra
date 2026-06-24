K3_TYPE ?= k3d
CLUSTER_NAME ?= homelab
VAULT_NETWORK ?= k3-$(CLUSTER_NAME)
K3_ARGS ?= --servers 1 --network $(VAULT_NETWORK) --port "8080:80@loadbalancer" --port "8443:443@loadbalancer"
REPO_URL ?= git@github.com:Spuntininki/homelab-infra.git
REPO_SECRET_NAME ?= homelab-infra-repo
REPO_SSH_KEY_FILE ?= $(HOME)/.ssh/id_ed25519_argocd
ARGOCD_VERSION ?= v3.4.4


VAULT_DIR ?= docker/vault
VAULT_TOKEN_FILE ?= $(VAULT_DIR)/eso-token.txt

.PHONY: help create delete recreate bootstrap status kubeconfig verify clean repo-secret \
  vault-up vault-down vault-bootstrap vault-status vault-token

help:
	@printf '%s\n' "Targets:" \
		"  make create     Create the $(K3_TYPE) cluster" \
		"  make kubeconfig Update kubeconfig and switch context" \
		"  make bootstrap  Apply the Argo CD bootstrap" \
		"  make repo-secret Register the Git repository credential" \
		"  make status     Show Argo CD applications" \
		"  make verify     Run basic cluster checks" \
		"  make delete     Delete the $(K3_TYPE) cluster" \
		"  make clean      Delete the cluster and prune kubeconfig entries" \
		"  make recreate   Delete, create, and bootstrap again"

create:
	$(K3_TYPE) cluster create $(CLUSTER_NAME) $(K3_ARGS)
	$(MAKE) kubeconfig
	$(MAKE) bootstrap
	$(MAKE) vault-up
	$(MAKE) vault-bootstrap

kubeconfig:
	$(K3_TYPE) kubeconfig merge $(CLUSTER_NAME) --kubeconfig-switch-context

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

delete:
	$(K3_TYPE) cluster delete $(CLUSTER_NAME)
	kubectl config delete-context $(K3_TYPE)-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	kubectl config delete-cluster $(K3_TYPE)-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	kubectl config delete-user $(K3_TYPE)-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	
recreate: delete create

# HashiCorp Vault (runs in Docker, outside the k3d cluster)
vault-up:
	@docker network inspect $(VAULT_NETWORK) >/dev/null 2>&1 || { echo "Network $(VAULT_NETWORK) not found. Create the cluster first with 'make create'." >&2; exit 1; }
	docker compose -f $(VAULT_DIR)/docker-compose.yaml up -d

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