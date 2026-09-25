#!/bin/bash
set -euo pipefail
export LC_ALL=C TZ=UTC DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Customize the project's development tools here. RunsOn is installed separately.
# The Cobalt recipe uses the compiler, kernel, and boot tools in this list.
apt-get update
apt-get -y --no-install-recommends install \
  binutils \
  build-essential \
  cmake \
  castxml \
  cpio \
  g++-14 \
  gcc-14 \
  grub-common \
  grub2-common \
  initramfs-tools \
  libffi-dev \
  libncurses-dev \
  libssl-dev \
  libxml2-dev \
  libxml-xpath-perl \
  lsb-release \
  make \
  ninja-build \
  pkg-config \
  python3-dev \
  python3-pip \
  ripgrep \
  ruby \
  ruby-dev \
  xz-utils
