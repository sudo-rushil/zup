#!/usr/bin/env bash

# zup install script

set -euo pipefail

repo="sudo-rushil/zup"
asset="zup-aarch64-macos.tar.gz"
install_dir="$HOME/.zig"
bin_dir="$install_dir/bin"

if [[ $# -gt 0 ]]; then
  printf 'Usage: install.sh\n' >&2
  exit 1
fi

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) ;;
  *)
    printf 'zup requires Apple Silicon macOS\n' >&2
    exit 1
    ;;
esac
if [[ "${EUID:-$(id -u)}" == "0" ]]; then
  printf 'Run this installer without sudo\n' >&2
  exit 1
fi
command -v curl >/dev/null || { printf 'curl is required\n' >&2; exit 1; }
command -v tar >/dev/null || { printf 'tar is required\n' >&2; exit 1; }

version="${ZUP_VERSION:-}"
if [[ -z "$version" ]]; then
  version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$repo/releases/latest" | sed 's|.*/||; s|^v||')"
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  printf 'Invalid zup version: %s\n' "$version" >&2
  exit 1
fi

base_url="https://github.com/$repo/releases/download/$version"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

curl -fsSL "$base_url/$asset" -o "$work_dir/$asset"

stage="$work_dir/stage"
mkdir -p "$stage"
tar -xzf "$work_dir/$asset" -C "$stage"
if [[ ! -f "$stage/zup" ]]; then
  printf 'Installation bundle is missing zup\n' >&2
  exit 1
fi
chmod 0755 "$stage/zup"
"$stage/zup" help >/dev/null

mkdir -p "$bin_dir"
rm -f "$bin_dir/zup"
mv "$stage/zup" "$bin_dir/zup"

profile=""
profiles=("")
case "$(basename "${SHELL:-sh}")" in
  zsh)
    zsh_dir="${ZDOTDIR:-$HOME}"
    profiles=("$zsh_dir/.zshrc" "$zsh_dir/.zshenv")
    ;;
  bash)
    profiles=("$HOME/.bash_profile" "$HOME/.bashrc")
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
      profiles+=("$XDG_CONFIG_HOME/bash_profile" "$XDG_CONFIG_HOME/bashrc")
    fi
    ;;
esac
for candidate in "${profiles[@]}"; do
  if [[ -n "$candidate" && -f "$candidate" && -w "$candidate" ]]; then
    profile="$candidate"
    break
  fi
done
path_line='export PATH="$HOME/.zig/bin:$PATH"'
if [[ -n "$profile" ]] && ! grep -Fqx "$path_line" "$profile"; then
  printf '\n%s\n' "$path_line" >> "$profile"
fi

printf '\nzup %s was successfully installed\n' "$version"
if [[ -n "$profile" ]]; then
  printf 'Restart your terminal, then run: zup help\n'
else
  printf 'Add %s to your PATH, then run: zup help\n' "$bin_dir"
fi
