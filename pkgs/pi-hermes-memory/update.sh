#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_owner=chandra447
repo_name=pi-hermes-memory
repo_url="https://github.com/$repo_owner/$repo_name"
archive_base_url="$repo_url/archive/refs/tags"

package_file=default.nix
lock_patch=package-lock.patch
package_attr=pi-hermes-memory

fake_npm_deps_hash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

die() {
  echo "$*" >&2
  exit 1
}

latest_release_info() {
  local tag version rev

  tag=$(
    git ls-remote \
      --tags \
      --sort=-version:refname \
      "$repo_url" \
      'v*' |
      awk '!/\^\{\}$/ {
        sub("refs/tags/", "", $2)
        print $2
        exit
      }'
  )

  [[ -n "$tag" ]] || die "Failed to determine latest tag"

  version=${tag#v}
  rev=$tag

  jq -n \
    --arg version "$version" \
    --arg rev "$rev" \
    '{
      version: $version,
      rev: $rev
    }'
}

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$package_file"
}

current_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$package_file"
}

current_npm_deps_hash() {
  sed -n 's/^  npmDepsHash = "\(.*\)";$/\1/p' "$package_file"
}

write_package_nix() {
  local version=$1
  local hash=$2
  local npm_deps_hash=$3
  local tmp

  tmp=$(mktemp)

  sed \
    -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
    -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
    -e "s|^  npmDepsHash = \".*\";$|  npmDepsHash = \"${npm_deps_hash}\";|" \
    "$package_file" >"$tmp"

  mv "$tmp" "$package_file"
}

repair_missing_integrities() {
  local lockfile=$1
  local entry package version integrity tmp

  while IFS=$'\t' read -r entry package version; do
    [[ -n "$entry" ]] || continue

    [[ -n "$package" ]] ||
      die "Could not determine package name for $entry"

    [[ -n "$version" ]] ||
      die "Could not determine version for $entry"

    echo "Repairing missing integrity: $package@$version" >&2

    integrity=$(
      npm view "$package@$version" dist.integrity |
        tail -n 1
    )

    case "$integrity" in
      sha512-*|sha384-*|sha256-*|sha1-*)
        ;;
      *)
        die "Failed to determine integrity for $package@$version"
        ;;
    esac

    echo "  $integrity" >&2

    tmp=$(mktemp)

    jq \
      --arg entry "$entry" \
      --arg integrity "$integrity" \
      '.packages[$entry].integrity = $integrity' \
      "$lockfile" >"$tmp"

    mv "$tmp" "$lockfile"
  done < <(
    jq -r '
      .packages
      | to_entries[]
      | select(
          .key != ""
          and (.value.link // false) != true
          and .value.integrity == null
          and (
            (.value.resolved // "")
            | test("^https://registry\\.npmjs\\.org/")
          )
        )
      | [
          .key,
          (
            .key
            | split("/node_modules/")
            | last
          ),
          .value.version
        ]
      | @tsv
    ' "$lockfile"
  )
}

validate_lockfile() {
  local lockfile=$1
  local count

  count=$(
    jq '
      [
        .packages
        | to_entries[]
        | select(
            .key != ""
            and (.value.link // false) != true
            and .value.integrity == null
            and (
              (.value.resolved // "")
              | test("^https://registry\\.npmjs\\.org/")
            )
          )
      ]
      | length
    ' "$lockfile"
  )

  if (( count == 0 )); then
    return 0
  fi

  echo "Registry dependencies still missing integrity:" >&2

  jq -r '
    .packages
    | to_entries[]
    | select(
        .key != ""
        and (.value.link // false) != true
        and .value.integrity == null
        and (
          (.value.resolved // "")
          | test("^https://registry\\.npmjs\\.org/")
        )
      )
    | "  \(.key) (\(.value.version // "<no version>"))"
  ' "$lockfile" >&2

  return 1
}

generate_lockfile_patch() {
  local checkout=$1
  local lockfile="$checkout/package-lock.json"
  local original="$checkout/package-lock.json.orig"

  echo "Checking upstream package-lock.json..." >&2

  [[ -f "$lockfile" ]] ||
    die "Upstream release has no package-lock.json"

  # Do not accidentally carry a patch for the previous upstream source
  # into the new source.
  rm -f "$script_dir/$lock_patch"

  cp "$lockfile" "$original"

  #
  # First let npm normalize/reconstruct as much lockfile metadata as it can.
  #
  (
    cd "$checkout"

    npm install \
      --package-lock-only \
      --ignore-scripts \
      --no-audit \
      --no-fund \
      >/dev/null
  )

  #
  # npm can leave registry entries with a resolved tarball but without an
  # integrity value. Nix's npm dependency parser rejects those entries.
  #
  repair_missing_integrities "$lockfile"

  #
  # Refuse to generate a patch if known-invalid registry entries remain.
  #
  validate_lockfile "$lockfile" ||
    die "Failed to repair package-lock.json"

  if cmp -s "$original" "$lockfile"; then
    echo "package-lock.json does not need patching" >&2
    rm -f "$original"
    return 0
  fi

  echo "package-lock.json needs repair; generating $lock_patch" >&2

  diff -u \
    --label a/package-lock.json \
    --label b/package-lock.json \
    "$original" \
    "$lockfile" \
    >"$script_dir/$lock_patch" || true

  rm -f "$original"

  [[ -s "$script_dir/$lock_patch" ]] ||
    die "Failed to generate $lock_patch"

  echo "Generated $lock_patch" >&2
}

prefetch_npm_deps_hash() {
  local repo_root
  local build_log
  local status
  local hash

  repo_root=$(git rev-parse --show-toplevel)
  build_log=$(mktemp)

  #
  # Temporarily point default.nix at the new source and deliberately use an
  # incorrect npmDepsHash. A successful dependency fetch will then fail with
  # the correct fixed-output hash in the Nix diagnostic.
  #
  write_package_nix \
    "$new_version" \
    "$new_hash" \
    "$fake_npm_deps_hash"

  set +e
  (
    cd "$repo_root"

    #
    # Use a path flake rather than the Git-backed flake.
    #
    # package-lock.patch may have just been generated and be untracked.
    # path: makes it visible to Nix without modifying the Git index.
    #
    nix build \
      -L \
      --no-link \
      "path:$repo_root#$package_attr"
  ) >"$build_log" 2>&1

  status=$?
  set -e

  if (( status == 0 )); then
    echo >&2
    echo "nix build unexpectedly succeeded with fake npmDepsHash." >&2
    echo >&2
    cat "$build_log" >&2

    rm -f "$build_log"
    die "Unexpectedly resolved fake npmDepsHash"
  fi

  hash=$(
    sed -n \
      's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\).*$/\1/p' \
      "$build_log" |
      tail -n 1
  )

  if [[ -z "$hash" ]]; then
    echo >&2
    echo "Failed to extract npmDepsHash." >&2
    echo >&2
    echo "----- nix build output -----" >&2
    cat "$build_log" >&2
    echo "----- end nix build output -----" >&2
    echo >&2

    rm -f "$build_log"
    return 1
  fi

  rm -f "$build_log"
  printf '%s\n' "$hash"
}

cleanup() {
  if [[ -n "${upstream_checkout:-}" ]]; then
    rm -rf "$upstream_checkout"
  fi

  if [[ -n "${backup_dir:-}" ]]; then
    rm -rf "$backup_dir"
  fi
}

restore_and_cleanup() {
  local status=$?

  if (( status != 0 )) && [[ -n "${backup_dir:-}" ]]; then
    if [[ -f "$backup_dir/$package_file" ]]; then
      cp "$backup_dir/$package_file" "$package_file"
    fi

    if [[ -f "$backup_dir/$lock_patch" ]]; then
      cp "$backup_dir/$lock_patch" "$lock_patch"
    else
      rm -f "$lock_patch"
    fi
  fi

  cleanup
  exit "$status"
}

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
  pwd
)
cd "$script_dir"

#
# Read current package metadata.
#

old_version=$(current_version)
old_hash=$(current_hash)
old_npm_deps_hash=$(current_npm_deps_hash)

[[ -n "$old_version" ]] ||
  die "Failed to determine current version from $package_file"

[[ -n "$old_hash" ]] ||
  die "Failed to determine current hash from $package_file"

[[ -n "$old_npm_deps_hash" ]] ||
  die "Failed to determine current npmDepsHash from $package_file"

#
# Determine the latest upstream release.
#

release_json=$(latest_release_info)

new_version=$(jq -r '.version' <<<"$release_json")
new_rev=$(jq -r '.rev' <<<"$release_json")

[[ -n "$new_version" && "$new_version" != null ]] ||
  die "Failed to determine latest version"

[[ -n "$new_rev" && "$new_rev" != null ]] ||
  die "Failed to determine latest revision"

#
# Back up everything that this updater can modify.
#

backup_dir=$(mktemp -d)

cp "$package_file" "$backup_dir/$package_file"

if [[ -f "$lock_patch" ]]; then
  cp "$lock_patch" "$backup_dir/$lock_patch"
fi

trap restore_and_cleanup EXIT

#
# Prefetch the upstream source.
#

archive_url="$archive_base_url/$new_rev.tar.gz"

echo "Prefetching $repo_name $new_version..." >&2

prefetch_json=$(
  nix store prefetch-file \
    --json \
    --unpack \
    "$archive_url"
)

new_hash=$(jq -r '.hash' <<<"$prefetch_json")

[[ -n "$new_hash" && "$new_hash" != null ]] ||
  die "Failed to determine source hash"

source_changed=false

if [[ "$new_version" != "$old_version" ||
      "$new_hash" != "$old_hash" ]]; then
  source_changed=true
fi

#
# A pre-existing package-lock.patch also requires a refresh.
#
# This is useful when introducing the lockfile repair mechanism to a package
# whose version/source hash is already current.
#
needs_npm_refresh=false

if [[ "$source_changed" == true ]]; then
  needs_npm_refresh=true
fi

#
# Generate the normalized lockfile patch.
#

if [[ "$needs_npm_refresh" == true ]]; then
  upstream_checkout=$(mktemp -d)

  echo "Fetching upstream $new_rev..." >&2

  git -c advice.detachedHead=false \
    clone \
    --quiet \
    --depth 1 \
    --branch "$new_rev" \
    "$repo_url" \
    "$upstream_checkout"

  generate_lockfile_patch "$upstream_checkout"
fi

#
# Determine npmDepsHash.
#

new_npm_deps_hash="$old_npm_deps_hash"

if [[ "$needs_npm_refresh" == true ]]; then
  echo "Determining npmDepsHash..." >&2

  if ! new_npm_deps_hash=$(prefetch_npm_deps_hash); then
    die "Failed to determine npmDepsHash"
  fi

  [[ -n "$new_npm_deps_hash" ]] ||
    die "Failed to determine npmDepsHash"

  write_package_nix \
    "$new_version" \
    "$new_hash" \
    "$new_npm_deps_hash"
elif [[ "$source_changed" == true ]]; then
  write_package_nix \
    "$new_version" \
    "$new_hash" \
    "$new_npm_deps_hash"
fi

#
# Report result.
#

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $package_file to $new_version ($new_rev)"
elif [[ "$new_hash" != "$old_hash" ||
        "$new_npm_deps_hash" != "$old_npm_deps_hash" ]]; then
  echo "Updated package metadata for $new_version"
else
  echo "No metadata changes"
fi

if [[ -f "$lock_patch" ]]; then
  echo "Using $lock_patch"
else
  echo "No package-lock patch required"
fi

trap - EXIT
cleanup