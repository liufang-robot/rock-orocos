#!/bin/bash
set -euo pipefail
export PATH=/usr/xenomai/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13 ]]
printf '%s\n' "$PRETTY_NAME"

directory=${1:?validation directory required}
expected_revision=${2:?expected source revision required}
[[ "$(id -u)" == 1001 && "$(id -un)" == runner ]]
manifest=/usr/local/share/rock-orocos-image/manifest.json
cat "$manifest"
python3 - "$manifest" "$expected_revision" <<'PY'
import hashlib, json, pathlib, platform, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest['orocos']['revision'] == sys.argv[2], 'Image source revision mismatch'
assert platform.release() == manifest['kernel_release'], 'Wrong running kernel'
config = pathlib.Path('/boot/config-' + platform.release()).read_bytes()
assert hashlib.sha256(config).hexdigest() == manifest['kernel_effective_config_sha256']
PY
test -r /proc/xenomai/version
cat /proc/xenomai/version
/usr/xenomai/bin/xeno-config --version
/usr/xenomai/bin/xeno-config --skin=native --cflags
/usr/xenomai/bin/xeno-config --skin=posix --cflags
lsinitramfs "/boot/initrd.img-$(uname -r)" > "$directory/initramfs.txt"
for module in nvme ext4 virtio_blk virtio_net ena; do
    modinfo "$module" >/dev/null
    grep -E "/$module[.]ko([.](gz|xz|zst))?$" "$directory/initramfs.txt"
done
/usr/bin/cmake -S "$directory/cobalt" -B "$directory/build" -G Ninja \
    -DCMAKE_C_COMPILER=/usr/bin/gcc-14 -DCMAKE_MAKE_PROGRAM=/usr/bin/ninja \
    -DXENOMAI_ROOT=/usr/xenomai
/usr/bin/cmake --build "$directory/build"
timeout 20s "$directory/build/cobalt"
smokey_tests=(arith posix_cond posix_mutex xddp iddp bufp)
smokey_selection=$(IFS=,; printf '%s' "${smokey_tests[*]}")
timeout 180s /usr/xenomai/bin/smokey --vm --run="$smokey_selection" \
    2>&1 | tee "$directory/smokey.log"
# This case changes CLOCK_REALTIME, which needs CAP_SYS_TIME independently of
# Cobalt group access. Keep the other cases and application checks unprivileged.
sudo -n timeout 180s /usr/xenomai/bin/smokey --vm --run=posix_clock \
    2>&1 | tee -a "$directory/smokey.log"
# Smokey returns success for unsupported tests. Require explicit success for
# every maintained case so a skipped test cannot satisfy image acceptance.
for name in "${smokey_tests[@]}" posix_clock; do
    grep -Fx "$name OK" "$directory/smokey.log"
done
bash "$directory/orocos/tools/validate-install.sh" --prefix /opt/orocos --target xenomai
# Calling the library's version function proves a real header/library link
# without requesting a master or opening a hardware device.
cat > "$directory/etherlab.c" <<'EOF'
#include <ecrt.h>
int main(void) { return ecrt_version_magic() == ECRT_VERSION_MAGIC ? 0 : 1; }
EOF
gcc-14 "$directory/etherlab.c" -I/opt/etherlab/include -L/opt/etherlab/lib \
    -Wl,-rpath,/opt/etherlab/lib -lethercat -o "$directory/etherlab"
"$directory/etherlab"
