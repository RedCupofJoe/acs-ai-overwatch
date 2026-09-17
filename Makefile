.PHONY: cluster-values cluster-admin-pre-gitops platform-prep cleanup-poc-repo helm-template helm-template-discovery check-prereqs

# Check OpenShift cluster prerequisites (oc login required).
check-prereqs:
	@chmod +x scripts/check-prereqs.sh
	@./scripts/check-prereqs.sh

# Cluster-admin bootstrap before Argo CD (namespaces, ConfigMap, GitOps RBAC, discovery SA).
cluster-admin-pre-gitops:
	@chmod +x scripts/cluster-admin/*.sh
	@./scripts/cluster-admin/install-pre-gitops.sh

# AWS GPU MachineSet + NFD instance (vendored workshop configs/). Does not apply ClusterPolicy or DSC.
platform-prep:
	@chmod +x scripts/cluster-admin/*.sh
	@./scripts/cluster-admin/05-apply-platform-prep.sh

# Discover cluster.appsDomain, routes, and git remote from current oc login.
cluster-values:
	@chmod +x scripts/discover-cluster-values.sh
	@./scripts/discover-cluster-values.sh

# Reset GitOps overlays and remove local cluster-specific files (repo only; does not touch the cluster).
cleanup-poc-repo:
	@chmod +x scripts/cleanup-poc-repo.sh
	@./scripts/cleanup-poc-repo.sh

# Render main chart (optional values-cluster.yaml from make cluster-values).
helm-template:
	helm template acs-ai-overwatch gitops/helm/acs-ai-overwatch \
		-f gitops/helm/acs-ai-overwatch/values.yaml \
		-f gitops/helm/acs-ai-overwatch/values-poc.yaml \
		$(if $(wildcard gitops/helm/acs-ai-overwatch/values-cluster.yaml),-f gitops/helm/acs-ai-overwatch/values-cluster.yaml,)

helm-template-discovery:
	helm template discovery gitops/helm/acs-ai-overwatch-cluster-discovery
