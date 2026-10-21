#!/usr/bin/env bash
set -euo pipefail

bin_dir="${RUNNER_TEMP:?RUNNER_TEMP is required}/hov-ci-bin"
mkdir -p "$bin_dir"

install_asset() {
  local command_name="$1" url="$2" sha="$3"
  local target="$bin_dir/$command_name"
  local download="$target.download"
  curl --fail --location --silent --show-error "$url" --output "$download"
  printf '%s  %s\n' "$sha" "$download" | sha256sum --check --status
  chmod +x "$download"
  mv "$download" "$target"
}

install_asset jq \
  'https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-amd64' \
  '020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d'
install_asset yq \
  'https://github.com/mikefarah/yq/releases/download/v4.50.1/yq_linux_amd64' \
  'c7a1278e6bbc4924f41b56db838086c39d13ee25dcb22089e7fbf16ac901f0d4'

archive="$RUNNER_TEMP/shellcheck-v0.11.0.linux.x86_64.tar.gz"
curl --fail --location --silent --show-error \
  'https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.gz' \
  --output "$archive"
printf '%s  %s\n' \
  'b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6' \
  "$archive" | sha256sum --check --status
tar -xzf "$archive" -C "$RUNNER_TEMP"
cp "$RUNNER_TEMP/shellcheck-v0.11.0/shellcheck" "$bin_dir/shellcheck"

# Select the verified tools here and in subsequent GitHub Actions steps.
export PATH="$bin_dir:$PATH"
for tool in jq yq shellcheck; do
  printf 'Using %s\n' "$(command -v "$tool")"
  "$bin_dir/$tool" --version
done

printf '%s\n' "$bin_dir" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
