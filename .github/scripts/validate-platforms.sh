#!/usr/bin/env bash
set -euo pipefail

# Validate platform format from stdin (one platform per line).
# Accepted formats:
#   os/arch
#   os/arch/variant

VALID_PATTERN='^[a-z0-9]+/[a-z0-9]+(/[a-z0-9][a-z0-9._-]*)?$'

errors=()
line_num=0
total=0

while IFS= read -r platform || [[ -n "$platform" ]]; do
  platform="$(echo "$platform" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ -z "$platform" ]] && continue
  line_num=$((line_num + 1))
  total=$((total + 1))

  if ! [[ "$platform" =~ $VALID_PATTERN ]]; then
    errors+=("Line $line_num: invalid platform '$platform'")
  fi
done

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "::error::Platform validation failed for ${#errors[@]} item(s):"
  for err in "${errors[@]}"; do
    echo "  - $err"
  done
  exit 1
fi

if [[ $total -eq 0 ]]; then
  echo "::error::No platforms provided for validation"
  exit 1
fi

echo "All $total platform(s) validated successfully."
