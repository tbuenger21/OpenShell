#!/usr/bin/env bash

# Shared release metadata and registry guard helpers.

canonical_image_source_url() {
  local source_root="$1"
  local source_url scheme remainder authority path host

  source_url="${OPENSHELL_IMAGE_SOURCE_URL:-}"
  if [[ -z "$source_url" ]]; then
    source_url="$(git -C "$source_root" config --get remote.origin.url 2>/dev/null || true)"
  fi
  # Git remotes should not include either component, but an override might.
  # Strip both before parsing so credentials cannot reach OCI labels.
  source_url="${source_url%%\?*}"
  source_url="${source_url%%\#*}"
  source_url="${source_url%.git}"
  if [[ -z "$source_url" ]]; then
    echo "unable to determine image source URL; set OPENSHELL_IMAGE_SOURCE_URL" >&2
    return 1
  fi

  case "$source_url" in
    https://*|http://*)
      scheme="${source_url%%://*}"
      remainder="${source_url#*://}"
      if [[ "$remainder" == */* ]]; then
        authority="${remainder%%/*}"
        path="/${remainder#*/}"
      else
        authority="$remainder"
        path=""
      fi
      # OCI metadata must never include Git credentials or access tokens.
      authority="${authority##*@}"
      if [[ -z "$authority" || -z "$path" ]]; then
        echo "image source URL must include a host and repository path" >&2
        return 1
      fi
      printf '%s://%s%s\n' "$scheme" "$authority" "$path"
      ;;
    git@*:* )
      remainder="${source_url#git@}"
      host="${remainder%%:*}"
      path="${remainder#*:}"
      if [[ -z "$host" || -z "$path" ]]; then
        echo "invalid Git SSH source URL" >&2
        return 1
      fi
      printf 'https://%s/%s\n' "$host" "$path"
      ;;
    ssh://git@*/*)
      remainder="${source_url#ssh://git@}"
      host="${remainder%%/*}"
      path="${remainder#*/}"
      host="${host%%:*}"
      if [[ -z "$host" || -z "$path" ]]; then
        echo "invalid Git SSH source URL" >&2
        return 1
      fi
      printf 'https://%s/%s\n' "$host" "$path"
      ;;
    *)
      echo "image source URL must be an http(s) or Git SSH repository URL" >&2
      return 1
      ;;
  esac
}

require_source_sha_candidate_tag() {
  local image_tag="$1"
  local source_revision="$2"
  local expected_tag="sha-${source_revision}"

  if [[ "$image_tag" != "$expected_tag" ]]; then
    echo "candidate tag must be $expected_tag for the checked-out source revision" >&2
    return 1
  fi
}

image_ref_exists() {
  local image_ref="$1"
  local inspection_output

  if inspection_output="$(docker buildx imagetools inspect "$image_ref" 2>&1)"; then
    return 0
  fi

  # Only the Buildx not-found response that names this exact reference proves
  # absence. Auth, credential-helper, network, and registry failures must stop
  # a release rather than permit replacement.
  case "$inspection_output" in
    "ERROR: ${image_ref}: not found"|"ERROR: ${image_ref}: manifest unknown"|"ERROR: ${image_ref}: name unknown")
      return 1
      ;;
    *)
      echo "unable to determine whether release image exists; refusing to publish: $image_ref" >&2
      return 2
      ;;
  esac
}

require_new_image_ref() {
  local image_ref="$1"
  local inspection_status=0

  image_ref_exists "$image_ref" || inspection_status=$?
  if [[ "$inspection_status" -eq 0 ]]; then
    echo "refusing to replace an existing release image: $image_ref" >&2
    return 1
  fi
  if [[ "$inspection_status" -eq 1 ]]; then
    return 0
  fi
  return "$inspection_status"
}

is_docker_image_tag() {
  local image_tag="$1"
  local docker_tag_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'

  [[ "$image_tag" =~ $docker_tag_pattern ]]
}

require_docker_image_tag() {
  local image_tag="$1"
  local label="${2:-image tag}"

  if ! is_docker_image_tag "$image_tag"; then
    echo "$label must be a Docker-compatible tag of at most 128 characters: $image_tag" >&2
    return 1
  fi
}

is_moving_image_alias() {
  case "$1" in
    dev|latest|edge|nightly) return 0 ;;
    *) return 1 ;;
  esac
}

is_semantic_release_version() {
  local version="$1"
  local version_pattern='^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-[0-9A-Za-z-]+([.][0-9A-Za-z-]+)*)?$'

  [[ "$version" =~ $version_pattern ]] && is_docker_image_tag "$version"
}

require_semantic_release_version() {
  local version="$1"

  if ! is_semantic_release_version "$version"; then
    echo "release version must use Docker-compatible semantic version form vMAJOR.MINOR.PATCH: $version" >&2
    return 1
  fi
}

require_moving_image_alias() {
  local alias="$1"

  if ! is_moving_image_alias "$alias"; then
    echo "release alias must be one of dev, latest, edge, or nightly: $alias" >&2
    return 1
  fi
}

require_new_release_alias() {
  local image_ref="$1"
  local alias="$2"

  if is_moving_image_alias "$alias"; then
    return 0
  fi
  require_new_image_ref "$image_ref"
}

validate_release_manifest_records() {
  local manifest_path="$1"
  shift
  local allowed_keys expected_key

  if [[ ! -f "$manifest_path" ]]; then
    echo "release manifest not found: $manifest_path" >&2
    return 1
  fi
  if (( $# == 0 )); then
    echo "release manifest validation requires at least one expected key" >&2
    return 1
  fi
  for expected_key in "$@"; do
    if [[ ! "$expected_key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "invalid expected release manifest key: $expected_key" >&2
      return 1
    fi
  done

  allowed_keys="$(IFS=,; printf '%s' "$*")"
  if ! awk -v allowed_keys="$allowed_keys" '
    BEGIN {
      expected_count = split(allowed_keys, expected_list, ",")
      for (position = 1; position <= expected_count; position++) {
        expected[expected_list[position]] = 1
      }
      record_pattern = "^[A-Z][A-Z0-9_]*=[-A-Za-z0-9./:@_+,]*$"
    }
    $0 !~ record_pattern {
      printf "invalid release manifest record: %s\n", $0 > "/dev/stderr"
      invalid = 1
      next
    }
    {
      separator = index($0, "=")
      key = substr($0, 1, separator - 1)
      if (!(key in expected)) {
        printf "unexpected release manifest key: %s\n", key > "/dev/stderr"
        invalid = 1
      } else if (++seen[key] != 1) {
        printf "duplicate release manifest key: %s\n", key > "/dev/stderr"
        invalid = 1
      }
    }
    END {
      for (key in expected) {
        if (!(key in seen)) {
          printf "missing release manifest key: %s\n", key > "/dev/stderr"
          invalid = 1
        }
      }
      exit invalid
    }
  ' "$manifest_path"; then
    echo "release manifest is invalid: $manifest_path" >&2
    return 1
  fi
}

read_release_manifest_value() {
  local manifest_path="$1"
  local expected_key="$2"
  local value

  if [[ ! "$expected_key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "invalid release manifest key requested: $expected_key" >&2
    return 1
  fi
  if ! value="$(awk -v expected_key="$expected_key" '
    index($0, expected_key "=") == 1 {
      print substr($0, length(expected_key) + 2)
      exit
    }
  ' "$manifest_path")"; then
    echo "unable to read release manifest key: $expected_key" >&2
    return 1
  fi
  if [[ ! "$value" =~ ^[-A-Za-z0-9./:@_+,]*$ ]]; then
    echo "release manifest value contains unsupported characters: $expected_key" >&2
    return 1
  fi
  printf '%s\n' "$value"
}
