#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_owner=juicesharp
repo_name=rpiv-mono
repo_url="https://github.com/$repo_owner/$repo_name"
archive_base_url="$repo_url/archive/refs/tags"

source_file=src.nix
lock_patch=package-lock.patch
voice_package_attr=rpiv-voice

fake_npm_deps_hash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

die() {
  echo "$*" >&2
  exit 1
}

latest_release_info() {
  local tag version

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
  jq -n --arg version "$version" '{ version: $version }'
}

current_version() {
  sed -n 's/^  version = "\(.*\)";$/\1/p' "$source_file"
}

current_hash() {
  sed -n 's/^    hash = "\(.*\)";$/\1/p' "$source_file"
}

current_npm_deps_hash() {
  sed -n 's/^  npmDepsHash = "\(.*\)";$/\1/p' "$source_file"
}

write_source_nix() {
  local version=$1
  local hash=$2
  local npm_deps_hash=$3
  local tmp

  tmp=$(mktemp)

  sed \
    -e "s|^  version = \".*\";$|  version = \"${version}\";|" \
    -e "s|^  npmDepsHash = \".*\";$|  npmDepsHash = \"${npm_deps_hash}\";|" \
    -e "s|^    hash = \".*\";$|    hash = \"${hash}\";|" \
    "$source_file" >"$tmp"

  mv "$tmp" "$source_file"
}

repair_missing_integrities() {
  local lockfile=$1
  local entry package version integrity

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

    #
    # Insert integrity immediately after the matching "resolved" line.
    #
    # Unlike jq, this preserves the rest of package-lock.json byte-for-byte.
    #
    ENTRY="$entry" INTEGRITY="$integrity" perl -0pi -e '
      my $entry = quotemeta($ENV{ENTRY});
      my $integrity = $ENV{INTEGRITY};

      my $count = s{
        ("$entry"\s*:\s*\{
          (?:(?!\n\s*"[^\n"]+"\s*:\s*\{).)*?
          "resolved"\s*:\s*"[^"]+",)
      }{$1\n      "integrity": "$integrity",}xs;

      die "Expected exactly one lockfile entry for $ENV{ENTRY}, found $count\n"
        unless $count == 1;
    ' "$lockfile"
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

  # Never carry a patch from the previous release into the new source.
  rm -f "$script_dir/$lock_patch"

  cp "$lockfile" "$original"

  #
  # Do NOT run `npm install --package-lock-only` here.
  #
  # In a large npm workspace that can rewrite thousands of unrelated
  # lockfile lines. We only repair the metadata that fetchNpmDeps requires.
  #
  repair_missing_integrities "$lockfile"

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

  write_source_nix \
    "$new_version" \
    "$new_hash" \
    "$fake_npm_deps_hash"

  set +e
  (
    cd "$repo_root"

    # Use the working tree rather than the Git-filtered flake source.
    #
    # package-lock.patch may have just been generated by this updater and
    # therefore may not be tracked yet. A path: flake includes it without
    # requiring the updater to modify the Git index.
    nix build \
      -L \
      --no-link \
      "path:$repo_root#legacyPackages.x86_64-linux.$voice_package_attr"
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
    if [[ -f "$backup_dir/$source_file" ]]; then
      cp "$backup_dir/$source_file" "$source_file"
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
# Read current metadata.
#

old_version=$(current_version)
old_hash=$(current_hash)
old_npm_deps_hash=$(current_npm_deps_hash)

[[ -n "$old_version" ]] ||
  die "Failed to determine current version from $source_file"

[[ -n "$old_hash" ]] ||
  die "Failed to determine current hash from $source_file"

[[ -n "$old_npm_deps_hash" ]] ||
  die "Failed to determine current npmDepsHash from $source_file"

#
# Find latest upstream release.
#

release_json=$(latest_release_info)
new_version=$(jq -r '.version' <<<"$release_json")

[[ -n "$new_version" && "$new_version" != null ]] ||
  die "Failed to determine latest version"

#
# Back up files modified by this updater.
#

backup_dir=$(mktemp -d)

cp "$source_file" "$backup_dir/$source_file"

if [[ -f "$lock_patch" ]]; then
  cp "$lock_patch" "$backup_dir/$lock_patch"
fi

trap restore_and_cleanup EXIT

#
# Prefetch upstream source.
#

archive_url="$archive_base_url/v$new_version.tar.gz"

echo "Prefetching rpiv-mono $new_version..." >&2

prefetch_json=$(
  nix store prefetch-file \
    --json \
    --unpack \
    "$archive_url"
)

new_hash=$(jq -r '.hash' <<<"$prefetch_json")

[[ -n "$new_hash" && "$new_hash" != null ]] ||
  die "Failed to determine source hash"

#
# Only regenerate package-lock.patch when the source changed.
#

source_changed=false

if [[ "$new_version" != "$old_version" ||
      "$new_hash" != "$old_hash" ]]; then
  source_changed=true
fi

if [[ "$source_changed" == true ]]; then
  upstream_checkout=$(mktemp -d)

  echo "Fetching upstream v$new_version..." >&2

  git -c advice.detachedHead=false \
    clone \
    --quiet \
    --depth 1 \
    --branch "v$new_version" \
    "$repo_url" \
    "$upstream_checkout"

  generate_lockfile_patch "$upstream_checkout"
fi

#
# Determine npmDepsHash.
#

new_npm_deps_hash="$old_npm_deps_hash"

if [[ "$source_changed" == true ]]; then
  echo "Source changed; determining npmDepsHash..." >&2

  if ! new_npm_deps_hash=$(prefetch_npm_deps_hash); then
    die "Failed to determine npmDepsHash"
  fi

  [[ -n "$new_npm_deps_hash" ]] ||
    die "Failed to determine npmDepsHash"

  write_source_nix \
    "$new_version" \
    "$new_hash" \
    "$new_npm_deps_hash"
fi

#
# Report result.
#

if [[ "$new_version" != "$old_version" ]]; then
  echo "Updated $source_file to $new_version"
elif [[ "$new_hash" != "$old_hash" ||
        "$new_npm_deps_hash" != "$old_npm_deps_hash" ]]; then
  echo "Updated shared source metadata for $new_version"
else
  echo "No changes to commit"
fi

if [[ -f "$lock_patch" ]]; then
  echo "Using $lock_patch"
fi

trap - EXIT
cleanup