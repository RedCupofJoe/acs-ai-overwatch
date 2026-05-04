#!/usr/bin/env bash
# Cluster-specific metadata. Source this file after adjusting values for your environment.
# Example: source ./env-vars.sh

# --- Cluster shape (3×3: e.g. three failure domains × three nodes per domain, or your org’s definition) ---
export CLUSTER_NAME="${CLUSTER_NAME:-acs-ai-overwatch}"
export CLUSTER_TOPOLOGY="${CLUSTER_TOPOLOGY:-3x3}"

# --- GPU capacity (NVIDIA L4) ---
export GPU_COUNT="${GPU_COUNT:-3}"
export GPU_MODEL="${GPU_MODEL:-L4}"
export GPU_VENDOR="${GPU_VENDOR:-nvidia}"
