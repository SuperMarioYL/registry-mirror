#!/usr/bin/env bash
set -euo pipefail

# Validate Docker image format from stdin (one image per line).
# Each image must include a tag. Exits 1 if any line is invalid.

VALID_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9._-]*(\/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$'

errors=()
line_num=0
total=0

while IFS= read -r image || [[ -n "$image" ]]; do
  image="$(echo "$image" | xargs)" # trim whitespace
  [[ -z "$image" ]] && continue
  line_num=$((line_num + 1))
  total=$((total + 1))

  if ! [[ "$image" =~ $VALID_PATTERN ]]; then
    errors+=("Line $line_num: invalid format '$image'")
  fi
done

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "::error::Validation failed for ${#errors[@]} image(s):"
  for err in "${errors[@]}"; do
    echo "  - $err"
  done
  exit 1
fi

echo "All $total image(s) validated successfully."
