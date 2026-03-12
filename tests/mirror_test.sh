#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/.github/scripts/mirror.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "Expected to find: $needle" >&2
    echo "--- file contents ---" >&2
    cat "$file" >&2
    fail "assert_contains"
  fi
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq -- "$needle" "$file"; then
    echo "Did not expect to find: $needle" >&2
    echo "--- file contents ---" >&2
    cat "$file" >&2
    fail "assert_not_contains"
  fi
}

make_fake_bin() {
  local bin_dir="$1"
  local skopeo_log="$2"
  local docker_log="$3"
  local behavior="${4:-always-success}"

  mkdir -p "$bin_dir"

  cat > "${bin_dir}/skopeo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'skopeo %s\n' "\$*" >> "${skopeo_log}"
case "\$1" in
  copy)
    if [[ "${behavior}" == "conversion-fallback" && "\$*" == *"--format v2s2"* ]]; then
      echo 'time="2026-03-12T02:47:07Z" level=fatal msg="copying system image from manifest list: creating an updated image manifest: Unknown media type during manifest conversion: \"application/vnd.docker.image.rootfs.diff.tar.gzip\""' >&2
      exit 1
    fi
    exit 0
    ;;
  delete)
    exit 0
    ;;
  *)
    echo "unexpected skopeo command: \$1" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${bin_dir}/skopeo"

  cat > "${bin_dir}/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "\$*" >> "${docker_log}"
if [[ "\$1" == "buildx" && "\$2" == "imagetools" && "\$3" == "create" ]]; then
  exit 0
fi
echo "unexpected docker command: \$*" >&2
exit 1
EOF
  chmod +x "${bin_dir}/docker"
}

run_mirror() {
  local work_dir="$1"
  local image="$2"
  local platforms_csv="$3"
  local behavior="${4:-always-success}"
  local skopeo_log="${work_dir}/skopeo.log"
  local docker_log="${work_dir}/docker.log"
  local bin_dir="${work_dir}/bin"
  local run_log="${work_dir}/run.log"

  : > "$skopeo_log"
  : > "$docker_log"
  make_fake_bin "$bin_dir" "$skopeo_log" "$docker_log" "$behavior"

  PATH="${bin_dir}:${PATH}" \
  GITHUB_RUN_ID=100 \
  GITHUB_RUN_ATTEMPT=1 \
  bash "$SCRIPT_PATH" \
    "example.registry.io" \
    "mirror-space" \
    "user" \
    "password" \
    "$platforms_csv" >"$run_log" 2>&1 <<EOF
${image}
EOF

  echo "$skopeo_log|$docker_log|$run_log"
}

test_single_platform_publishes_directly_without_cleanup() {
  local work_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' RETURN

  local logs
  logs="$(run_mirror "$work_dir" "vllm/vllm-openai:glm5" "linux/amd64")"
  local skopeo_log="${logs%%|*}"
  local rest="${logs#*|}"
  local docker_log="${rest%%|*}"
  local run_log="${logs##*|}"

  assert_contains "skopeo copy docker://vllm/vllm-openai:glm5 docker://example.registry.io/mirror-space/vllm-openai:glm5" "$skopeo_log"
  assert_not_contains "vllm-openai:glm5-tmp-" "$skopeo_log"
  assert_not_contains "skopeo delete" "$skopeo_log"
  assert_contains "SUCCESS: vllm/vllm-openai:glm5" "$run_log"
  if [[ -s "$docker_log" ]]; then
    echo "--- docker log ---" >&2
    cat "$docker_log" >&2
    fail "single-platform sync should not invoke docker buildx"
  fi
}

test_multi_platform_keeps_staging_manifests() {
  local work_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' RETURN

  local logs
  logs="$(run_mirror "$work_dir" "vllm/vllm-openai:glm5" "linux/amd64,linux/arm64")"
  local skopeo_log="${logs%%|*}"
  local rest="${logs#*|}"
  local docker_log="${rest%%|*}"
  local run_log="${logs##*|}"

  assert_contains "skopeo copy docker://vllm/vllm-openai:glm5 docker://example.registry.io/mirror-space/vllm-openai:glm5-tmp-100-1-1-linux-amd64" "$skopeo_log"
  assert_contains "skopeo copy docker://vllm/vllm-openai:glm5 docker://example.registry.io/mirror-space/vllm-openai:glm5-tmp-100-1-1-linux-arm64" "$skopeo_log"
  assert_contains "docker buildx imagetools create -t example.registry.io/mirror-space/vllm-openai:glm5 example.registry.io/mirror-space/vllm-openai:glm5-tmp-100-1-1-linux-amd64 example.registry.io/mirror-space/vllm-openai:glm5-tmp-100-1-1-linux-arm64" "$docker_log"
  assert_not_contains "skopeo delete" "$skopeo_log"
  assert_contains "SUCCESS: vllm/vllm-openai:glm5" "$run_log"
}

test_conversion_error_falls_back_to_source_format() {
  local work_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' RETURN

  local logs
  logs="$(run_mirror "$work_dir" "quay.io/ascend/vllm-ascend:glm5-openeuler" "linux/arm64" "conversion-fallback")"
  local skopeo_log="${logs%%|*}"
  local rest="${logs#*|}"
  local docker_log="${rest%%|*}"
  local run_log="${logs##*|}"

  assert_contains "skopeo copy docker://quay.io/ascend/vllm-ascend:glm5-openeuler docker://example.registry.io/mirror-space/vllm-ascend:glm5-openeuler --format v2s2" "$skopeo_log"
  assert_contains "skopeo copy docker://quay.io/ascend/vllm-ascend:glm5-openeuler docker://example.registry.io/mirror-space/vllm-ascend:glm5-openeuler --dest-creds user:password --src-no-creds --retry-times 3 --override-os linux --override-arch arm64" "$skopeo_log"
  assert_contains "WARN: v2s2 conversion incompatible for quay.io/ascend/vllm-ascend:glm5-openeuler on linux/arm64, retrying with source manifest format" "$run_log"
  assert_contains "WARN: quay.io/ascend/vllm-ascend:glm5-openeuler" "$run_log"
  if [[ -s "$docker_log" ]]; then
    echo "--- docker log ---" >&2
    cat "$docker_log" >&2
    fail "single-platform fallback should not invoke docker buildx"
  fi
}

test_single_platform_publishes_directly_without_cleanup
test_multi_platform_keeps_staging_manifests
test_conversion_error_falls_back_to_source_format

echo "mirror tests passed"
