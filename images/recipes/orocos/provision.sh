#!/bin/bash
set -euo pipefail
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace="$recipe_dir/.build/source"
python3 - "$recipe_dir" <<'PY'
import hashlib, json, pathlib, sys
directory = pathlib.Path(sys.argv[1])
identity = json.loads((directory / 'source.json').read_text())
actual = hashlib.sha256((directory / 'source.tar.gz').read_bytes()).hexdigest()
if actual != identity['source_archive_sha256']:
    raise SystemExit('Orocos source bundle checksum mismatch')
PY
mkdir -p "$workspace" /opt/orocos
tar -xzf "$recipe_dir/source.tar.gz" -C "$workspace"
chown -R runner:runner "$workspace" /opt/orocos
# Install development dependencies while the source tree is available. Its
# build and Autoproj state disappear with the disposable disk at finalization.
runuser -u runner -- bash "$recipe_dir/build.sh" "$workspace"
install -Dm0644 "$recipe_dir/source.json" /usr/local/share/rock-orocos-image/source.json
install -Dm0644 "$workspace/packaging/source-lock.json" /usr/local/share/rock-orocos-image/source-lock.json
install -Dm0644 "$workspace/packaging/native-boost.json" /usr/local/share/rock-orocos-image/native-boost.json
