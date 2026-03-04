#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Arguments
TARGET_REGISTRY="${1:?TARGET_REGISTRY is required}"
TARGET_NAMESPACE="${2:?TARGET_NAMESPACE is required}"
TARGET_USER="${3:?TARGET_REGISTRY_USER is required}"
TARGET_PASSWORD="${4:?TARGET_REGISTRY_PASSWORD is required}"
PLATFORMS_CSV="${5:-linux/amd64}"

# Configuration
MAX_PARALLEL=${MAX_PARALLEL:-5}
RETRY_TIMES=${RETRY_TIMES:-3}
RUN_KEY="${GITHUB_RUN_ID:-$(date +%s)}-${GITHUB_RUN_ATTEMPT:-0}"
REPORT_FILE="/tmp/mirror-report.md"
RESULTS_DIR="/tmp/mirror-results"
PLATFORMS=()

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

join_by_comma() {
  local result=""
  for item in "$@"; do
    [[ -z "$item" ]] && continue
    if [[ -z "$result" ]]; then
      result="$item"
    else
      result="${result},${item}"
    fi
  done
  if [[ -z "$result" ]]; then
    echo "-"
  else
    echo "$result"
  fi
}

parse_platforms() {
  local csv="$1"
  local normalized
  normalized="$(echo "$csv" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -z "$normalized" ]]; then
    PLATFORMS=("linux/amd64")
    return
  fi

  IFS=',' read -r -a raw_platforms <<< "$normalized"
  PLATFORMS=()
  for platform in "${raw_platforms[@]-}"; do
    local exists=0
    [[ -z "$platform" ]] && continue
    for existing in "${PLATFORMS[@]-}"; do
      if [[ "$existing" == "$platform" ]]; then
        exists=1
        break
      fi
    done
    if [[ $exists -eq 0 ]]; then
      PLATFORMS+=("$platform")
    fi
  done

  if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
    PLATFORMS=("linux/amd64")
  fi
}

split_platform() {
  local platform="$1"
  local os arch variant
  IFS='/' read -r os arch variant <<< "$platform"
  echo "${os}|${arch}|${variant:-}"
}

is_missing_platform_error() {
  local output_lower
  output_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$output_lower" == *"no image found in image index"* ]] && return 0
  [[ "$output_lower" == *"no image found in manifest list"* ]] && return 0
  [[ "$output_lower" == *"no match for platform in manifest"* ]] && return 0
  [[ "$output_lower" == *"no matching manifest for"* ]] && return 0
  return 1
}

cleanup_temp_refs() {
  local refs=("$@")
  for ref in "${refs[@]}"; do
    skopeo delete --creds "${TARGET_USER}:${TARGET_PASSWORD}" "docker://${ref}" >/dev/null 2>&1 || true
  done
}

build_details() {
  local copied="$1"
  local missing="$2"
  local errors="$3"
  local action="$4"

  local details=""
  if [[ "$copied" != "-" ]]; then
    details="copied: ${copied}"
  fi
  if [[ "$missing" != "-" ]]; then
    if [[ -n "$details" ]]; then details="${details}; "; fi
    details="${details}missing: ${missing}"
  fi
  if [[ "$errors" != "-" ]]; then
    if [[ -n "$details" ]]; then details="${details}; "; fi
    details="${details}errors: ${errors}"
  fi
  if [[ -n "$action" && "$action" != "-" ]]; then
    if [[ -n "$details" ]]; then details="${details}; "; fi
    details="${details}action: ${action}"
  fi

  if [[ -z "$details" ]]; then
    echo "-"
  else
    echo "$details"
  fi
}

# Read images from stdin into array
IMAGES=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="$(echo "$raw_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  IMAGES+=("$line")
done
parse_platforms "$PLATFORMS_CSV"
PLATFORM_LIST="$(join_by_comma "${PLATFORMS[@]}")"
TOTAL_PLATFORMS=${#PLATFORMS[@]}

TOTAL=${#IMAGES[@]}

if [[ $TOTAL -eq 0 ]]; then
  log_error "No images to sync"
  exit 1
fi

log "Starting mirror of $TOTAL image(s) to ${TARGET_REGISTRY}/${TARGET_NAMESPACE}"
log "Platforms: ${PLATFORM_LIST} | Parallelism: $MAX_PARALLEL | Retries: $RETRY_TIMES"

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
  local -a copied_platforms=()
  local -a missing_platforms=()
  local -a error_platforms=()
  local -a temp_refs=()
  local copied_count=0
  local missing_count=0
  local error_count=0
  local status="FAILED"
  local action="-"
  local publish_failed=0

  for platform in "${PLATFORMS[@]-}"; do
    local os arch variant
    IFS='|' read -r os arch variant < <(split_platform "$platform")

    local platform_copy_args=(
      "--format" "v2s2"
      "--dest-creds" "${TARGET_USER}:${TARGET_PASSWORD}"
      "--src-no-creds"
      "--retry-times" "$RETRY_TIMES"
      "--override-os" "$os"
      "--override-arch" "$arch"
    )
    if [[ -n "$variant" ]]; then
      platform_copy_args+=("--override-variant" "$variant")
    fi

    local safe_platform tmp_target copy_output
    safe_platform="${platform//\//-}"
    safe_platform="${safe_platform//./-}"
    tmp_target="${target}-tmp-${RUN_KEY}-${index}-${safe_platform}"

    if copy_output=$(skopeo copy "docker://${source}" "docker://${tmp_target}" "${platform_copy_args[@]}" 2>&1); then
      copied_platforms+=("$platform")
      temp_refs+=("$tmp_target")
      copied_count=$((copied_count + 1))
      log "[$index/$TOTAL] [$platform] COPIED: $source"
    else
      if is_missing_platform_error "$copy_output"; then
        missing_platforms+=("$platform")
        missing_count=$((missing_count + 1))
        log "[$index/$TOTAL] [$platform] WARN: platform not found for $source"
      else
        error_platforms+=("$platform")
        error_count=$((error_count + 1))
        log_error "[$index/$TOTAL] [$platform] ERROR while copying $source"
        echo "$copy_output" >&2
      fi
    fi
  done

  if [[ $copied_count -gt 1 ]]; then
    if docker buildx imagetools create -t "$target" "${temp_refs[@]}" >/dev/null 2>&1; then
      action="pushed-multi-arch"
    else
      publish_failed=1
      error_platforms+=("manifest-assemble")
      error_count=$((error_count + 1))
      action="publish-failed"
      log_error "[$index/$TOTAL] Failed to assemble multi-arch manifest for $source"
    fi
  elif [[ $copied_count -eq 1 ]]; then
    local finalize_output
    if finalize_output=$(skopeo copy \
      "docker://${temp_refs[0]}" \
      "docker://${target}" \
      --format v2s2 \
      --src-creds "${TARGET_USER}:${TARGET_PASSWORD}" \
      --dest-creds "${TARGET_USER}:${TARGET_PASSWORD}" \
      --retry-times "$RETRY_TIMES" 2>&1); then
      action="pushed-single-arch"
    else
      publish_failed=1
      error_platforms+=("finalize-copy")
      error_count=$((error_count + 1))
      action="publish-failed"
      log_error "[$index/$TOTAL] Failed to publish final tag for $source"
      echo "$finalize_output" >&2
    fi
  else
    action="skipped-no-available-platform"
  fi

  cleanup_temp_refs "${temp_refs[@]-}"

  if [[ $copied_count -eq 0 ]]; then
    if [[ $error_count -gt 0 ]]; then
      status="FAILED"
      action="skipped-hard-error"
    else
      status="WARN"
    fi
  elif [[ $publish_failed -eq 1 ]]; then
    status="FAILED"
  elif [[ $missing_count -gt 0 || $error_count -gt 0 ]]; then
    status="WARN"
  else
    status="SUCCESS"
  fi

  end_time=$(date +%s)
  duration=$((end_time - start_time))

  local copied_csv missing_csv errors_csv
  copied_csv="$(join_by_comma "${copied_platforms[@]-}")"
  missing_csv="$(join_by_comma "${missing_platforms[@]-}")"
  errors_csv="$(join_by_comma "${error_platforms[@]-}")"

  echo "${status}|${source}|${target}|${duration}s|${copied_csv}|${missing_csv}|${errors_csv}|${action}" > "$result_file"

  if [[ "$status" == "SUCCESS" ]]; then
    log "[$index/$TOTAL] SUCCESS: $source (${duration}s)"
  elif [[ "$status" == "WARN" ]]; then
    log "[$index/$TOTAL] WARN: $source (${duration}s)"
  else
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
warn_count=0
fail_count=0
success_lines=""
warn_lines=""
fail_lines=""

for result_file in "$RESULTS_DIR"/*.result; do
  [[ -f "$result_file" ]] || continue
  IFS='|' read -r status source target duration copied missing errors action < "$result_file"
  details="$(build_details "$copied" "$missing" "$errors" "$action")"
  if [[ "$status" == "SUCCESS" ]]; then
    success_count=$((success_count + 1))
    success_lines+="| \`${source}\` | \`${target}\` | ${duration} | ${details} |\n"
  elif [[ "$status" == "WARN" ]]; then
    warn_count=$((warn_count + 1))
    warn_lines+="| \`${source}\` | \`${target}\` | ${duration} | ${details} |\n"
  else
    fail_count=$((fail_count + 1))
    fail_lines+="| \`${source}\` | \`${target}\` | ${duration} | ${details} |\n"
  fi
done

{
  echo "## Mirror Sync Report"
  echo ""
  echo "**Total**: ${TOTAL} | **Success**: ${success_count} | **Warning**: ${warn_count} | **Failed**: ${fail_count}"
  echo ""
  echo "**Requested platforms**: \`${PLATFORM_LIST}\` (${TOTAL_PLATFORMS})"
  echo ""

  if [[ $success_count -gt 0 ]]; then
    echo "### Succeeded"
    echo ""
    echo "| Source | Target | Duration | Details |"
    echo "|--------|--------|----------|---------|"
    echo -e "$success_lines"
  fi

  if [[ $warn_count -gt 0 ]]; then
    echo "### Warning"
    echo ""
    echo "| Source | Target | Duration | Details |"
    echo "|--------|--------|----------|---------|"
    echo -e "$warn_lines"
    echo ""
    echo "> Warning does not fail the workflow. Common cases:"
    echo "> missing requested platforms, or partial platform sync."
  fi

  if [[ $fail_count -gt 0 ]]; then
    echo "### Failed"
    echo ""
    echo "| Source | Target | Duration | Details |"
    echo "|--------|--------|----------|---------|"
    echo -e "$fail_lines"
    echo ""
    echo "> **Tip**: Failed images indicate hard errors (network/auth/publish failures)."
    echo "> You can re-open this issue to retry after fixing credentials or registry availability."
  fi

  if [[ $fail_count -eq 0 && $warn_count -eq 0 ]]; then
    echo ""
    echo "All images synced successfully!"
  elif [[ $fail_count -eq 0 && $warn_count -gt 0 ]]; then
    echo ""
    echo "Sync finished with warnings."
  fi
} > "$REPORT_FILE"

log "Report written to $REPORT_FILE"

if [[ $fail_count -gt 0 ]]; then
  log_error "$fail_count image(s) failed to sync"
  exit 1
fi

if [[ $warn_count -gt 0 ]]; then
  log "$warn_count image(s) completed with warnings"
fi
