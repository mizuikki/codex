#!/usr/bin/env bash

set -euo pipefail

REPOSITORY="mizuikki/codex"
TARGET="x86_64-unknown-linux-gnu"

usage() {
  cat <<'EOF'
Install, update, or uninstall the latest mizuikki/codex fork release.

Usage:
  scripts/install-codex-release.sh [install|update|uninstall] [options]

Options:
  --bin-dir <dir>       Directory for the codex command links.
                        Default: $HOME/.local/bin
  --install-root <dir>  Directory containing managed release files.
                        Default: $XDG_DATA_HOME/mizuikki-codex or
                        $HOME/.local/share/mizuikki-codex
  -h, --help            Show this help.

The installer currently supports x86_64 Linux with glibc. Set GITHUB_TOKEN if
GitHub API rate limits apply. The default command is install; update is an alias.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

command_name="install"
if [[ ${1:-} == "install" || ${1:-} == "update" || ${1:-} == "uninstall" ]]; then
  command_name=$1
  shift
fi

data_home=${XDG_DATA_HOME:-"${HOME}/.local/share"}
if [[ $data_home != /* ]]; then
  data_home="${HOME}/.local/share"
fi
bin_dir="${HOME}/.local/bin"
install_root="${data_home}/mizuikki-codex"

while [[ $# -gt 0 ]]; do
  case $1 in
    --bin-dir)
      [[ $# -ge 2 ]] || die "--bin-dir requires a value"
      bin_dir=$2
      shift 2
      ;;
    --install-root)
      [[ $# -ge 2 ]] || die "--install-root requires a value"
      install_root=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ $bin_dir == /* ]] || die "--bin-dir must be an absolute path"
[[ $install_root == /* ]] || die "--install-root must be an absolute path"
bin_dir=${bin_dir%/}
install_root=${install_root%/}
[[ -n $bin_dir && $bin_dir != / ]] || die "refusing unsafe bin directory"
[[ -n $install_root && $install_root != / && $install_root != "$HOME" ]] || \
  die "refusing unsafe install root"

codex_link="$bin_dir/codex"
host_link="$bin_dir/codex-code-mode-host"
managed_codex="$install_root/current/codex"
managed_host="$install_root/current/codex-code-mode-host"
managed_marker="$install_root/.mizuikki-codex-managed"

remove_managed_link() {
  local link_path=$1
  local expected_target=$2

  if [[ -L $link_path && $(readlink "$link_path") == "$expected_target" ]]; then
    rm -- "$link_path"
  elif [[ -e $link_path || -L $link_path ]]; then
    echo "warning: leaving unmanaged path in place: $link_path" >&2
  fi
}

uninstall() {
  remove_managed_link "$codex_link" "$managed_codex"
  remove_managed_link "$host_link" "$managed_host"

  if [[ -L $install_root ]]; then
    die "refusing to remove a symbolic-link install root: $install_root"
  elif [[ -e $install_root && \
    (! -f $managed_marker || $(<"$managed_marker") != "$REPOSITORY") ]]; then
    die "refusing to remove an unmanaged install root: $install_root"
  elif [[ -d $install_root ]]; then
    rm -rf -- "$install_root"
  fi
  echo "Uninstalled mizuikki/codex managed files."
}

if [[ $command_name == "uninstall" ]]; then
  uninstall
  exit 0
fi

[[ $(uname -s) == "Linux" ]] || die "only Linux is currently supported"
case $(uname -m) in
  x86_64 | amd64) ;;
  *) die "only x86_64 Linux is currently supported" ;;
esac

for required_command in curl find grep python3 tar sha256sum install; do
  command -v "$required_command" >/dev/null 2>&1 || \
    die "$required_command is required"
done

validate_managed_link() {
  local link_path=$1
  local expected_target=$2

  if [[ -e $link_path || -L $link_path ]]; then
    if [[ ! -L $link_path || $(readlink "$link_path") != "$expected_target" ]]; then
      die "refusing to replace unmanaged path: $link_path"
    fi
  fi
}

validate_managed_link "$codex_link" "$managed_codex"
validate_managed_link "$host_link" "$managed_host"

if [[ -L $install_root ]]; then
  die "install root must not be a symbolic link: $install_root"
elif [[ -d $install_root && ! -f $managed_marker && \
  -n $(find "$install_root" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  die "refusing to use a non-empty unmanaged install root: $install_root"
elif [[ -e $install_root && ! -d $install_root ]]; then
  die "install root is not a directory: $install_root"
fi

mkdir -p -- "$install_root" "$install_root/releases" "$bin_dir"
printf '%s\n' "$REPOSITORY" >"$managed_marker"
temp_dir=$(mktemp -d "$install_root/.install.XXXXXX")
cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

curl_args=(--fail --silent --show-error --location --retry 3)
if [[ -n ${GITHUB_TOKEN:-} ]]; then
  curl_args+=(--header "Authorization: Bearer ${GITHUB_TOKEN}")
fi

releases_json="$temp_dir/releases.json"
curl "${curl_args[@]}" \
  "https://api.github.com/repos/${REPOSITORY}/releases?per_page=100" \
  --output "$releases_json"

release_info=$(python3 - "$releases_json" "$TARGET" <<'PY'
import json
import sys

releases_path, target = sys.argv[1:]
with open(releases_path, encoding="utf-8") as releases_file:
    releases = json.load(releases_file)

if not isinstance(releases, list):
    raise SystemExit("GitHub returned an unexpected releases response")

for release in releases:
    tag = release.get("tag_name", "")
    if release.get("draft") or release.get("prerelease") or not tag.startswith("fork-v"):
        continue
    version = tag[len("fork-v") :]
    expected_name = f"codex-{version}-{target}.tar.gz"
    for asset in release.get("assets", []):
        if asset.get("name") == expected_name:
            print(f"{version}\t{asset['browser_download_url']}")
            raise SystemExit(0)

raise SystemExit(f"No published fork release contains an asset for {target}")
PY
)

IFS=$'\t' read -r version download_url <<<"$release_info"
[[ -n $version && -n $download_url ]] || die "failed to resolve the latest release"

archive_name="codex-${version}-${TARGET}.tar.gz"
archive_path="$temp_dir/$archive_name"
echo "Downloading ${REPOSITORY} ${version}..."
curl "${curl_args[@]}" "$download_url" --output "$archive_path"

expected_dir="codex-${version}-${TARGET}"
archive_entries=$(tar -tzf "$archive_path")
while IFS= read -r entry; do
  case $entry in
    "$expected_dir/" | \
    "$expected_dir/codex" | \
    "$expected_dir/codex-code-mode-host" | \
    "$expected_dir/SHA256SUMS") ;;
    *) die "unexpected archive entry: $entry" ;;
  esac
done <<<"$archive_entries"

tar --no-same-owner -xzf "$archive_path" -C "$temp_dir"
extracted_dir="$temp_dir/$expected_dir"
[[ -f $extracted_dir/codex && ! -L $extracted_dir/codex ]] || \
  die "archive does not contain a regular codex binary"
[[ -f $extracted_dir/codex-code-mode-host && \
  ! -L $extracted_dir/codex-code-mode-host ]] || \
  die "archive does not contain a regular codex-code-mode-host binary"
[[ -f $extracted_dir/SHA256SUMS && ! -L $extracted_dir/SHA256SUMS ]] || \
  die "archive does not contain SHA256SUMS"

(
  cd "$extracted_dir"
  sha256sum -c SHA256SUMS
)
"$extracted_dir/codex" --version | grep -Fx "codex-cli $version" >/dev/null || \
  die "downloaded codex binary reports an unexpected version"
"$extracted_dir/codex-code-mode-host" --help >/dev/null || \
  die "downloaded codex-code-mode-host failed its startup check"

generation="${version}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
release_dir="$install_root/releases/$generation"
mkdir -- "$release_dir"
install -m 0755 -- "$extracted_dir/codex" "$release_dir/codex"
install -m 0755 -- \
  "$extracted_dir/codex-code-mode-host" \
  "$release_dir/codex-code-mode-host"
printf '%s\n' "$version" >"$release_dir/VERSION"

previous_release=""
if [[ -L $install_root/current ]]; then
  previous_release=$(readlink "$install_root/current")
elif [[ -e $install_root/current ]]; then
  die "managed current path is not a symbolic link: $install_root/current"
fi

new_current="$install_root/.current.$$"
ln -s "releases/$generation" "$new_current"
mv -T -- "$new_current" "$install_root/current"

install_managed_link() {
  local link_path=$1
  local target_path=$2
  local temporary_link="${link_path}.mizuikki-codex.$$"

  if [[ -e $link_path || -L $link_path ]]; then
    if [[ ! -L $link_path || $(readlink "$link_path") != "$target_path" ]]; then
      die "refusing to replace unmanaged path: $link_path"
    fi
  fi

  ln -s "$target_path" "$temporary_link"
  mv -T -- "$temporary_link" "$link_path"
}

install_managed_link "$codex_link" "$managed_codex"
install_managed_link "$host_link" "$managed_host"

case $previous_release in
  releases/*)
    previous_dir="$install_root/$previous_release"
    if [[ $previous_dir != "$release_dir" && -d $previous_dir ]]; then
      rm -rf -- "$previous_dir"
    fi
    ;;
  "") ;;
  *) echo "warning: leaving unexpected previous release path: $previous_release" >&2 ;;
esac

echo "Installed mizuikki/codex $version."
echo "  codex: $codex_link"
echo "  code mode host: $host_link"

resolved_codex=$(command -v codex 2>/dev/null || true)
if [[ $resolved_codex != "$codex_link" ]]; then
  echo "warning: $bin_dir is not first in PATH; 'codex' currently resolves to ${resolved_codex:-nothing}" >&2
fi
