.PHONY: cluster-values helm-template

# Discover cluster.appsDomain, routes, and git remote from current oc login.
cluster-values:
	@chmod +x scripts/discover-cluster-values.sh
	@./scripts/discover-cluster-values.sh

# Render chart with all value layers (requires values-cluster.yaml — run make cluster-values first).
helm-template:
	helm template acs-ai-overwatch gitops/helm/acs-ai-overwatch \
		-f gitops/helm/acs-ai-overwatch/values.yaml \
		-f gitops/helm/acs-ai-overwatch/values-poc.yaml \
		-f gitops/helm/acs-ai-overwatch/values-cluster.yaml
