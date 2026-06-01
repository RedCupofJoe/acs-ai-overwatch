.PHONY: cluster-values cluster-admin-pre-gitops helm-template helm-template-discovery

# Cluster-admin bootstrap before Argo CD (namespaces, ConfigMap, GitOps RBAC, discovery SA).
cluster-admin-pre-gitops:
	@chmod +x scripts/cluster-admin/*.sh
	@./scripts/cluster-admin/install-pre-gitops.sh

# Discover cluster.appsDomain, routes, and git remote from current oc login.
cluster-values:
	@chmod +x scripts/discover-cluster-values.sh
	@./scripts/discover-cluster-values.sh

# Render main chart (optional values-cluster.yaml from make cluster-values).
helm-template:
	helm template acs-ai-overwatch gitops/helm/acs-ai-overwatch \
		-f gitops/helm/acs-ai-overwatch/values.yaml \
		-f gitops/helm/acs-ai-overwatch/values-poc.yaml \
		$(if $(wildcard gitops/helm/acs-ai-overwatch/values-cluster.yaml),-f gitops/helm/acs-ai-overwatch/values-cluster.yaml,)

helm-template-discovery:
	helm template discovery gitops/helm/acs-ai-overwatch-cluster-discovery
