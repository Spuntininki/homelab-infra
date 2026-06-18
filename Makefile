CLUSTER_NAME ?= homelab
K3D_ARGS ?= --servers 1 --agents 1 --port "8080:80@loadbalancer" --port "8443:443@loadbalancer"

.PHONY: help create delete recreate bootstrap status kubeconfig verify clean

help:
	@printf '%s\n' "Targets:" \
		"  make create     Create the k3d cluster" \
		"  make kubeconfig Update kubeconfig and switch context" \
		"  make bootstrap  Apply the Argo CD bootstrap" \
		"  make status     Show Argo CD applications" \
		"  make verify     Run basic cluster checks" \
		"  make delete     Delete the k3d cluster" \
		"  make clean      Delete the cluster and prune kubeconfig entries" \
		"  make recreate   Delete, create, and bootstrap again"

create:
	k3d cluster create $(CLUSTER_NAME) $(K3D_ARGS)
	$(MAKE) kubeconfig
	$(MAKE) bootstrap

kubeconfig:
	k3d kubeconfig merge $(CLUSTER_NAME) --kubeconfig-switch-context

bootstrap:
	kubectl apply --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
	kubectl apply -k bootstrap/argocd

status:
	kubectl get nodes
	kubectl get pods -n default
	kubectl get applications -n default

delete:
	k3d cluster delete $(CLUSTER_NAME)
	kubectl config delete-context k3d-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	kubectl config delete-cluster k3d-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	kubectl config delete-user k3d-$(CLUSTER_NAME) >/dev/null 2>&1 || true
	
recreate: delete create bootstrap
