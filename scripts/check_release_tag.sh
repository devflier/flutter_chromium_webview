#!/usr/bin/env bash
set -euo pipefail
package_dir="${1:?Provide the package directory}"
prefix="${2:?Provide the tag prefix}"
tag="${GITHUB_REF_NAME:?This check requires the GitHub release tag}"
version="$(awk '$1 == "version:" {print $2; exit}' "$package_dir/pubspec.yaml" | tr -d '\r')"
if [[ -z "$version" || "$tag" != "$prefix$version" ]]; then
  printf 'Release tag %s does not match %s version %s (expected %s%s).\n' \
    "$tag" "$package_dir" "$version" "$prefix" "$version" >&2
  exit 1
fi
printf 'Release tag matches package version: %s\n' "$tag"
