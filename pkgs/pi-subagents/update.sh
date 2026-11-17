#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#jq nixpkgs#nix nixpkgs#nodejs -c bash
# shellcheck shell=bash
set -euo pipefail

repo_url=https://github.com/nicobailon/pi-subagents.git
archive_base_url=https://github.com/nicobailon/pi-subagents/archive/refs/tags
package_file=default.nix

die() { echo "$*" >&2; exit 1; }

# Latest `vX.Y.Z` tag. Annotated tags appear twice in `git ls-remote --tags`
# (the tag object and the dereferenced commit `refs/tags/vX^{}`), and only the
# commit is a usable `fetchFromGitHub` rev, so prefer the dereferenced sha.
latest_release_info() {
  local line rev tag version

  line=$(git ls-remote --tags "$repo_url" 'v*' | awk '
    {
      sha = $1; ref = $2;
      sub(/^refs\/tags\//, "", ref);
      if (ref ~ /\^\{\}$/) {
        commit[substr(ref, 1, length(ref) - 3)] = sha;
      } else if (ref ~ /^v[0-9]+(\.[0-9]+)*$/) {
        if (!(ref in commit)) lightweight[ref] = sha;
      }
    }
    END {
      for (tag in lightweight) if (!(tag in commit)) print lightweight[tag] "\t" tag;
      for (tag in commit) print commit[tag] "\t" tag;
    }
  ' | sort -t$'\t' -k2,2V | tail -n1)

  [[ -n "$line" ]] || die "Failed to determine latest upstream tag"

  rev=${line%%$'\t'*}
  tag=${line#*$'\t'}
  version=${tag#v}

  jq -n \
    --arg version "$version" \
    --arg rev "$rev" \
    --arg tag "$tag" \
    '{ version: $version, rev: $rev, tag: $tag }'
}

# Dependency names packaged in $package_file (the `runtimeDeps` list).
packaged_dependency_names() {
  sed -n 's/^      name = "\(.*\)";$/\1/p' "$package_file" | jq -R . | jq -s .
}

# version/integrity for each packaged name, taken from the upstream lockfile
# when present (it also covers transitive deps such as jsbi).
resolve_packaged_dependencies() {
  local src_dir=$1 names_json=$2

  node -e '
    const fs = require("fs");
    const path = require("path");

    const names = JSON.parse(process.argv[1]);
    const src = process.argv[2];
    const pkg = JSON.parse(fs.readFileSync(path.join(src, "package.json"), "utf8"));

    const lockPath = path.join(src, "package-lock.json");
    const lock = fs.existsSync(lockPath)
      ? JSON.parse(fs.readFileSync(lockPath, "utf8"))
      : null;

    const result = [];
    for (const name of names) {
      const entry = lock?.packages?.[`node_modules/${name}`] ?? {};
      result.push({
        name,
        version: entry.version ?? "",
        hash: entry.integrity ?? "",
        // Upstream moved `typebox` out of dependencies, so fall back through
        // devDependencies and peerDependencies before giving up.
        range: pkg.dependencies?.[name]
          ?? pkg.devDependencies?.[name]
          ?? pkg.peerDependencies?.[name]
          ?? "",
      });
    }
    process.stdout.write(JSON.stringify(result));
  ' "$names_json" "$src_dir"
}

resolve_dependency_version() {
  local name=$1 range=$2
  npm view "$name@$range" version --json </dev/null | node -e 'let data=""; process.stdin.on("data", c => data += c); process.stdin.on("end", () => { const value = JSON.parse(data); process.stdout.write(Array.isArray(value) ? String(value[value.length - 1] ?? "") : String(value ?? "")); });'
}

resolve_dependency_hash() {
  local name=$1 version=$2
  npm view "$name@$version" dist.integrity --json </dev/null | tr -d '"'
}

# Warn when upstream declares runtime dependencies we do not package, since a
# missing one only shows up as a runtime module-not-found error.
warn_unpackaged_dependencies() {
  local src_dir=$1 names_json=$2 unpackaged

  unpackaged=$(node -e '
    const fs = require("fs");
    const names = new Set(JSON.parse(process.argv[1]));
    const pkg = JSON.parse(fs.readFileSync(require("path").join(process.argv[2], "package.json"), "utf8"));
    process.stdout.write(Object.keys(pkg.dependencies ?? {}).filter((n) => !names.has(n)).join(" "));
  ' "$names_json" "$src_dir")

  if [[ -n "$unpackaged" ]]; then
    echo "warning: upstream runtime dependencies not packaged: $unpackaged" >&2
    echo "warning: check whether the extension imports them at runtime and add fetchurl sources if so" >&2
  fi
}

write_package_nix() {
  local version=$1 rev=$2 hash=$3 deps_file=$4 tmp

  tmp=$(mktemp)

  awk \
    -v version="$version" \
    -v rev="$rev" \
    -v hash="$hash" \
    -v depsfile="$deps_file" '
      BEGIN {
        while ((getline line < depsfile) > 0) {
          split(line, field, "\t");
          dep_version[field[1]] = field[2];
          dep_hash[field[1]] = field[3];
        }
        close(depsfile);
        current = "";
      }
      /^  version = "/ { print "  version = \"" version "\";"; next }
      /^    rev = "/ { print "    rev = \"" rev "\";"; next }
      /^    hash = "/ { print "    hash = \"" hash "\";"; next }
      /^      name = "/ {
        current = $0;
        sub(/^      name = "/, "", current);
        sub(/";$/, "", current);
        print;
        next;
      }
      /^      version = "/ {
        if (current in dep_version) print "      version = \"" dep_version[current] "\";";
        else print;
        next;
      }
      /^      hash = "/ {
        if (current in dep_hash) print "      hash = \"" dep_hash[current] "\";";
        else print;
        next;
      }
      { print }
    ' "$package_file" > "$tmp"

  if cmp -s "$tmp" "$package_file"; then
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$package_file"
  return 0
}

cleanup() {
  rm -rf "${tmpdir:-}" "${backup_dir:-}"
}

restore_and_cleanup() {
  local status=$?
  if (( status != 0 )); then
    cp "$backup_dir/$package_file" "$package_file" 2>/dev/null || true
  fi
  cleanup
  exit "$status"
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$script_dir"

[[ -f "$package_file" ]] || die "Failed to find $package_file"

release_json=$(latest_release_info)
new_version=$(jq -r '.version' <<< "$release_json")
new_rev=$(jq -r '.rev' <<< "$release_json")
new_tag=$(jq -r '.tag' <<< "$release_json")
[[ -n "$new_version" && "$new_version" != null ]] || die "Failed to determine latest version"
[[ -n "$new_rev" && "$new_rev" != null ]] || die "Failed to determine latest revision"
[[ -n "$new_tag" && "$new_tag" != null ]] || die "Failed to determine latest tag"

tmpdir=$(mktemp -d)
backup_dir=$(mktemp -d)
cp "$package_file" "$backup_dir/$package_file"
trap restore_and_cleanup EXIT

archive_url="$archive_base_url/$new_tag.tar.gz"
prefetch_json=$(nix store prefetch-file --json --unpack "$archive_url")
new_hash=$(jq -r .hash <<< "$prefetch_json")
[[ -n "$new_hash" && "$new_hash" != null ]] || die "Failed to determine source hash"

git clone --depth 1 --branch "$new_tag" "$repo_url" "$tmpdir/src" >/dev/null 2>&1 \
  || die "Failed to clone $new_tag"

names_json=$(packaged_dependency_names)
dependency_json=$(resolve_packaged_dependencies "$tmpdir/src" "$names_json")
warn_unpackaged_dependencies "$tmpdir/src" "$names_json"

deps_file="$tmpdir/deps.tsv"
: > "$deps_file"

# One JSON record per dependency line; `IFS= read -r` keeps empty fields intact.
while IFS= read -r record; do
  name=$(jq -r '.name // empty' <<< "$record")
  version=$(jq -r '.version // empty' <<< "$record")
  hash=$(jq -r '.hash // empty' <<< "$record")
  range=$(jq -r '.range // empty' <<< "$record")
  if [[ -z "$version" ]]; then
    [[ -n "$range" ]] || die "Failed to determine dependency range for $name (checked dependencies, devDependencies, peerDependencies)"
    version=$(resolve_dependency_version "$name" "$range")
    [[ -n "$version" ]] || die "Failed to determine version for $name ($range)"
  fi
  if [[ -z "$hash" ]]; then
    hash=$(resolve_dependency_hash "$name" "$version")
    [[ -n "$hash" ]] || die "Failed to determine hash for $name@$version"
  fi
  printf '%s\t%s\t%s\n' "$name" "$version" "$hash" >> "$deps_file"
done < <(jq -c '.[]' <<< "$dependency_json")

if write_package_nix "$new_version" "$new_rev" "$new_hash" "$deps_file"; then
  if [[ "$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$package_file")" != "$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$backup_dir/$package_file")" ]]; then
    echo "Updated $package_file to $new_version ($new_tag)"
  else
    echo "Updated package metadata for $new_version"
  fi
else
  echo "No changes to commit"
fi

trap - EXIT
cleanup
