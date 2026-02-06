#!/usr/bin/env bash
# Shared utility functions for registry-mirror scripts

# Compute target image path from source image reference.
# Flattens the path to just image:tag under TARGET_REGISTRY/TARGET_NAMESPACE.
#
# Examples:
#   gcr.io/google-containers/pause:3.9  -> REGISTRY/NAMESPACE/pause:3.9
#   registry.k8s.io/kube-apiserver:v1.28.0 -> REGISTRY/NAMESPACE/kube-apiserver:v1.28.0
#   nginx:latest -> REGISTRY/NAMESPACE/nginx:latest
#   library/nginx:latest -> REGISTRY/NAMESPACE/nginx:latest
compute_target_image() {
  local source="$1"
  local target_registry="$2"
  local target_namespace="$3"

  # Extract just the last path component (image:tag)
  local image_name
  image_name="${source##*/}"

  echo "${target_registry}/${target_namespace}/${image_name}"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}
