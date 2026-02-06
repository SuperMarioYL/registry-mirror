#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Arguments
TARGET_REGISTRY="${1:?TARGET_REGISTRY is required}"
TARGET_NAMESPACE="${2:?TARGET_NAMESPACE is required}"
TARGET_USER="${3:?TARGET_REGISTRY_USER is required}"
TARGET_PASSWORD="${4:?TARGET_REGISTRY_PASSWORD is required}"
MULTI_ARCH="${5:-false}"

# Configuration
MAX_PARALLEL=${MAX_PARALLEL:-5}
RETRY_TIMES=${RETRY_TIMES:-3}
REPORT_FILE="/tmp/mirror-report.md"
RESULTS_DIR="/tmp/mirror-results"

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# Build skopeo common arguments
SKOPEO_ARGS=(
  "--format" "v2s2"
  "--dest-creds" "${TARGET_USER}:${TARGET_PASSWORD}"
  "--src-no-creds"
  "--retry-times" "$RETRY_TIMES"
)

if [[ "$MULTI_ARCH" == "true" ]]; then
  SKOPEO_ARGS+=("--all")
fi

# Read images from stdin into array
mapfile -t IMAGES < <(tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')

TOTAL=${#IMAGES[@]}

if [[ $TOTAL -eq 0 ]]; then
  log_error "No images to sync"
  exit 1
fi

log "Starting mirror of $TOTAL image(s) to ${TARGET_REGISTRY}/${TARGET_NAMESPACE}"
log "Multi-arch: $MULTI_ARCH | Parallelism: $MAX_PARALLEL | Retries: $RETRY_TIMES"

# Copy a single image. Writes result to a per-image file.
copy_image() {
  local index="$1"
  local source="$2"
  local target
  target="$(compute_target_image "$source" "$TARGET_REGISTRY" "$TARGET_NAMESPACE")"
  local result_file="${RESULTS_DIR}/${index}.result"

  log "[$index/$TOTAL] Copying: $source -> $target"

  local start_time end_time duration
  start_time=$(date +%s)

  if skopeo copy \
    "docker://${source}" \
    "docker://${target}" \
    "${SKOPEO_ARGS[@]}" 2>&1; then
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    echo "SUCCESS|${source}|${target}|${duration}s" > "$result_file"
    log "[$index/$TOTAL] SUCCESS: $source (${duration}s)"
  else
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    echo "FAILED|${source}|${target}|${duration}s" > "$result_file"
    log_error "[$index/$TOTAL] FAILED: $source (${duration}s)"
  fi
}

# Execute copies in parallel with semaphore pattern
running=0
for i in "${!IMAGES[@]}"; do
  index=$((i + 1))
  copy_image "$index" "${IMAGES[$i]}" &
  running=$((running + 1))

  if [[ $running -ge $MAX_PARALLEL ]]; then
    wait -n || true
    running=$((running - 1))
  fi
done

wait || true

# Generate report
log "Generating sync report..."

success_count=0
fail_count=0
success_lines=""
fail_lines=""

for result_file in "$RESULTS_DIR"/*.result; do
  [[ -f "$result_file" ]] || continue
  IFS='|' read -r status source target duration < "$result_file"
  if [[ "$status" == "SUCCESS" ]]; then
    success_count=$((success_count + 1))
    success_lines+="| \`${source}\` | \`${target}\` | ${duration} |\n"
  else
    fail_count=$((fail_count + 1))
    fail_lines+="| \`${source}\` | \`${target}\` | ${duration} |\n"
  fi
done

{
  echo "## Mirror Sync Report"
  echo ""
  echo "**Total**: ${TOTAL} | **Success**: ${success_count} | **Failed**: ${fail_count}"
  echo ""

  if [[ $success_count -gt 0 ]]; then
    echo "### Succeeded"
    echo ""
    echo "| Source | Target | Duration |"
    echo "|--------|--------|----------|"
    echo -e "$success_lines"
  fi

  if [[ $fail_count -gt 0 ]]; then
    echo "### Failed"
    echo ""
    echo "| Source | Target | Duration |"
    echo "|--------|--------|----------|"
    echo -e "$fail_lines"
    echo ""
    echo "> **Tip**: Failed images may be due to network issues, the source image not existing,"
    echo "> or incorrect tag. You can re-open this issue to retry."
  fi

  if [[ $fail_count -eq 0 ]]; then
    echo ""
    echo "All images synced successfully!"
  fi
} > "$REPORT_FILE"

log "Report written to $REPORT_FILE"

if [[ $fail_count -gt 0 ]]; then
  log_error "$fail_count image(s) failed to sync"
  exit 1
fi
