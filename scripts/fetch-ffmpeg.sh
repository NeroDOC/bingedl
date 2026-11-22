#!/usr/bin/env bash
# Download static ffmpeg + ffprobe (latest release from ffmpeg.martin-riedl.de,
# GPL builds) for this OS/arch into DIR and verify their SHA-256.
# Usage: scripts/fetch-ffmpeg.sh DIR
set -eu
dir=${1:?usage: fetch-ffmpeg.sh DIR}
case $(uname -s) in Linux) os=linux;; Darwin) os=macos;; *) echo "unsupported OS" >&2; exit 1;; esac
case $(uname -m) in x86_64|amd64) arch=amd64;; arm64|aarch64) arch=arm64;; *) echo "unsupported arch" >&2; exit 1;; esac
base=https://ffmpeg.martin-riedl.de
mkdir -p "$dir"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for tool in ffmpeg ffprobe; do
  url=$(curl -sS --retry 3 -o /dev/null -w '%{redirect_url}' "$base/redirect/latest/$os/$arch/release/$tool.zip")
  [ -n "$url" ] || { echo "cannot resolve $tool download" >&2; exit 1; }
  curl -sSf --retry 3 -o "$tmp/$tool.zip" "$url"
  want=$(curl -sSf --retry 3 "$url.sha256" | awk '{print $1}')
  got=$(openssl dgst -sha256 "$tmp/$tool.zip" | awk '{print $NF}')
  [ "$want" = "$got" ] || { echo "$tool: checksum mismatch" >&2; exit 1; }
  unzip -oq "$tmp/$tool.zip" "$tool" -d "$dir"
  chmod +x "$dir/$tool"
  echo "$tool: $url"
done
