#!/bin/bash
set -euo pipefail
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$recipe_dir/xenomai-cobalt/inputs.sh"
source "$recipe_dir/etherlab/inputs.sh"
source "$recipe_dir/runner-inputs.sh"
export ACTIONS_RUNNER_VERSION RUNS_ON_BOOTSTRAP_VERSION
export LINUX_REPOSITORY LINUX_REF LINUX_REVISION SOURCE_SHA256
export XENOMAI_REPOSITORY XENOMAI_REF XENOMAI_REVISION XENOMAI_SHA256 KERNEL_CONFIG_SHA256
export ETHERLAB_REPOSITORY ETHERLAB_REF ETHERLAB_REVISION ETHERLAB_SHA256
python3 - "$recipe_dir" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
directory = pathlib.Path('/usr/local/share/rock-orocos-image')
release = (directory / 'kernel-release').read_text().strip()
sources = {}
for name in ('LINUX', 'XENOMAI', 'ETHERLAB'):
    sources[name.lower()] = {key.lower(): os.environ[f'{name}_{key}']
                            for key in ('REPOSITORY', 'REF', 'REVISION')}
    sources[name.lower()]['archive_sha256'] = os.environ['SOURCE_SHA256' if name == 'LINUX' else f'{name}_SHA256']
manifest = {
    'schema_version': 1,
    'image_family': 'rock-orocos-xenomai',
    'orocos': json.loads((directory / 'source.json').read_text()),
    'sources': sources,
    'base_image': json.loads((pathlib.Path(sys.argv[1]) / 'recipe.json').read_text())['source_image'],
    'kernel_release': release,
    'kernel_input_config_sha256': os.environ['KERNEL_CONFIG_SHA256'],
    'kernel_effective_config_sha256': hashlib.sha256(pathlib.Path(f'/boot/config-{release}').read_bytes()).hexdigest(),
    'orocos_source_lock_sha256': hashlib.sha256((directory / 'source-lock.json').read_bytes()).hexdigest(),
    'prefixes': {'xenomai': '/usr/xenomai', 'etherlab': '/opt/etherlab', 'orocos': '/opt/orocos'},
    'etherlab_kernel_modules': False,
    'actions_runner_version': os.environ['ACTIONS_RUNNER_VERSION'],
    'runs_on_bootstrap_version': os.environ['RUNS_ON_BOOTSTRAP_VERSION'],
}
(directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(directory / 'packages.tsv').write_text(subprocess.check_output(
    ['dpkg-query', '-W', '-f=${binary:Package}\t${Version}\n'], text=True))
print(json.dumps(manifest, indent=2))
PY
