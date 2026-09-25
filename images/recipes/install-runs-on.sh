#!/bin/bash
set -euo pipefail
export LC_ALL=C TZ=UTC DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
source /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13 ]]
printf 'Acquire::Retries "3";\n' > /etc/apt/apt.conf.d/80-rock-orocos-retries
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$recipe_dir/runner-inputs.sh"
build_dir="$recipe_dir/.build"
export TMPDIR="$build_dir/tmp"
mkdir -p "$TMPDIR"

# RunsOn's minimal-image tooling and the GitHub Actions runner's Debian runtime.
# https://github.com/runs-on/runner-images-for-aws/blob/main/patches/ubuntu/files/minimal-install-target-tooling.sh
# https://github.com/actions/runner/blob/main/src/Misc/layoutbin/installdependencies.sh
apt-get update
apt-get -y --no-install-recommends install \
  ca-certificates \
  curl \
  git \
  jq \
  libicu76 \
  libkrb5-3 \
  liblttng-ust1t64 \
  libssl3t64 \
  netcat-openbsd \
  openssh-server \
  python3 \
  sudo \
  unzip \
  zip \
  zlib1g \
  zstd

download_verified() {
  local url=$1 sha256=$2 destination=$3
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" -o "$destination"
  printf '%s  %s\n' "$sha256" "$destination" | sha256sum --check --strict
}

runner_home=/home/runner
useradd --uid 1001 --user-group --create-home --home-dir "$runner_home" --shell /bin/bash runner
printf '%s\n' 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-rock-orocos-runner
chmod 0440 /etc/sudoers.d/90-rock-orocos-runner
archive="$build_dir/actions-runner.tar.gz"
download_verified "$ACTIONS_RUNNER_URL" "$ACTIONS_RUNNER_SHA256" "$archive"
tar -xzf "$archive" --no-same-owner -C "$runner_home"
chown --recursive runner:runner "$runner_home"
bootstrap="$build_dir/runs-on-bootstrap"
download_verified "$RUNS_ON_BOOTSTRAP_URL" "$RUNS_ON_BOOTSTRAP_SHA256" "$bootstrap"
install -m 0755 "$bootstrap" "/usr/local/bin/runs-on-bootstrap-v$RUNS_ON_BOOTSTRAP_VERSION"
