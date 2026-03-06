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

join_by_semicolon() {
  local result=""
  for item in "$@"; do
    [[ -z "$item" ]] && continue
    if [[ -z "$result" ]]; then
      result="$item"
    else
      result="${result}; ${item}"
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

classify_hard_error_cn() {
  local output_lower
  output_lower="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

  if [[ "$output_lower" == *"manifest unknown"* ]]; then
    echo "源镜像 tag 不存在或写错（manifest unknown）"
    return
  fi
  if [[ "$output_lower" == *"requested access to the resource is denied"* ]]; then
    echo "源镜像无权限访问，或镜像路径/仓库名不正确"
    return
  fi
  if [[ "$output_lower" == *"unauthorized"* || "$output_lower" == *"authentication required"* ]]; then
    echo "源镜像鉴权失败（未登录或凭据无效）"
    return
  fi
  if [[ "$output_lower" == *"name unknown"* ]]; then
    echo "源镜像仓库不存在（name unknown）"
    return
  fi
  if [[ "$output_lower" == *"no such host"* || "$output_lower" == *"dial tcp"* || "$output_lower" == *"i/o timeout"* || "$output_lower" == *"tls handshake timeout"* ]]; then
    echo "网络连接源仓库失败（DNS/网络超时）"
    return
  fi
  if [[ "$output_lower" == *"toomanyrequests"* || "$output_lower" == *"429"* ]]; then
    echo "源仓库访问频率受限（限流）"
    return
  fi

  echo "未知错误，请查看原始日志"
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
  local error_reasons="$5"

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
  if [[ "$error_reasons" != "-" ]]; then
    if [[ -n "$details" ]]; then details="${details}; "; fi
    details="${details}error_reason_cn: ${error_reasons}"
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
  local -a error_reason_items=()
  local -a temp_refs=()
  local copied_count=0
  local missing_count=0
  local error_count=0
  local status="FAILED"
  local action="-"
  local publish_failed=0
  local first_error_reason_cn=""

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
        log "[$index/$TOTAL] [$platform] WARN: 请求的平台在源镜像中不存在"
      else
        local reason_cn
        reason_cn="$(classify_hard_error_cn "$copy_output")"
        error_platforms+=("$platform")
        error_reason_items+=("${platform}:${reason_cn}")
        error_count=$((error_count + 1))
        if [[ -z "$first_error_reason_cn" ]]; then
          first_error_reason_cn="$reason_cn"
        fi
        log_error "[$index/$TOTAL] [$platform] ERROR while copying $source | 原因: ${reason_cn}"
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
      error_reason_items+=("manifest-assemble:目标仓库组装多架构清单失败")
      error_count=$((error_count + 1))
      action="publish-failed"
      if [[ -z "$first_error_reason_cn" ]]; then
        first_error_reason_cn="目标仓库组装多架构清单失败"
      fi
      log_error "[$index/$TOTAL] Failed to assemble multi-arch manifest for $source | 原因: 目标仓库组装多架构清单失败"
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
      error_reason_items+=("finalize-copy:目标标签发布失败")
      error_count=$((error_count + 1))
      action="publish-failed"
      if [[ -z "$first_error_reason_cn" ]]; then
        first_error_reason_cn="目标标签发布失败"
      fi
      log_error "[$index/$TOTAL] Failed to publish final tag for $source | 原因: 目标标签发布失败"
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

  local copied_csv missing_csv errors_csv error_reason_cn
  copied_csv="$(join_by_comma "${copied_platforms[@]-}")"
  missing_csv="$(join_by_comma "${missing_platforms[@]-}")"
  errors_csv="$(join_by_comma "${error_platforms[@]-}")"
  error_reason_cn="$(join_by_semicolon "${error_reason_items[@]-}")"

  echo "${status}|${source}|${target}|${duration}s|${copied_csv}|${missing_csv}|${errors_csv}|${action}|${error_reason_cn}" > "$result_file"

  if [[ "$status" == "SUCCESS" ]]; then
    log "[$index/$TOTAL] SUCCESS: $source (${duration}s)"
  elif [[ "$status" == "WARN" ]]; then
    log "[$index/$TOTAL] WARN: $source (${duration}s)"
  else
    if [[ -n "$first_error_reason_cn" ]]; then
      log_error "[$index/$TOTAL] FAILED: $source (${duration}s) | 主要原因: ${first_error_reason_cn}"
    else
      log_error "[$index/$TOTAL] FAILED: $source (${duration}s)"
    fi
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
  IFS='|' read -r status source target duration copied missing errors action error_reason_cn < "$result_file"
  details="$(build_details "$copied" "$missing" "$errors" "$action" "${error_reason_cn:--}")"
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
    echo "> Warning 不会导致工作流失败。常见原因："
    echo "> 请求的平台不存在，或仅部分平台同步成功。"
  fi

  if [[ $fail_count -gt 0 ]]; then
    echo "### Failed"
    echo ""
    echo "| Source | Target | Duration | Details |"
    echo "|--------|--------|----------|---------|"
    echo -e "$fail_lines"
    echo ""
    echo "> **提示**：Failed 表示硬错误（如网络、鉴权、目标仓库发布失败）。"
    echo "> 修复后可重新打开 Issue 触发重试。"
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
