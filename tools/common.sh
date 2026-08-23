#!/usr/bin/env bash

set -euo pipefail

OROCOS_ROCK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OROCOS_ROCK_DEFAULT_PREFIX="${OROCOS_PREFIX:-$HOME/.orocos}"
OROCOS_ROCK_DEFAULT_TARGET="${OROCOS_TARGET:-gnulinux}"
OROCOS_ROCK_DEFAULT_XENOMAI_DIR="${XENOMAI_DIR:-/usr/xenomai}"

orocos_rock_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

orocos_rock_info() {
    printf '%s\n' "$*" >&2
}

orocos_rock_require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        if [ "$1" = "autoproj" ]; then
            orocos_rock_die "required command 'autoproj' was not found in PATH; run ./tools/install-autoproj.sh or add an existing Autoproj install to PATH"
        fi
        orocos_rock_die "required command '$1' was not found in PATH"
    fi
}

orocos_rock_require_file() {
    [ -f "$1" ] || orocos_rock_die "required file is missing: $1"
}

orocos_rock_set_ruby_gem_cache() {
    local cache="$1"

    [ -d "$cache" ] || orocos_rock_die "Ruby gem cache does not exist: $cache"
    OROCOS_ROCK_RUBY_GEM_CACHE="$(cd "$cache" && pwd)"
    export OROCOS_ROCK_RUBY_GEM_CACHE
}

orocos_rock_cached_gem_path() {
    local gem_name="$1"
    local gem_version="$2"
    local gem_path

    [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ] ||
        orocos_rock_die "OROCOS_ROCK_RUBY_GEM_CACHE is not set"
    gem_path="$OROCOS_ROCK_RUBY_GEM_CACHE/$gem_name-$gem_version.gem"
    orocos_rock_require_file "$gem_path"
    printf '%s\n' "$gem_path"
}

orocos_rock_cleanup_install_env_snapshot() {
    local snapshot="$1"

    rm -f -- \
        "$snapshot/env.sh" \
        "$snapshot/dev-env.sh" \
        "$snapshot/env.sh.missing" \
        "$snapshot/dev-env.sh.missing" || return 1
    rmdir -- "$snapshot" || return 1
}

orocos_rock_snapshot_install_env() {
    local prefix="$1"
    local snapshot="$2"
    local entry
    local source

    for entry in env.sh dev-env.sh; do
        source="$prefix/$entry"
        if [ -L "$source" ] || [ -f "$source" ]; then
            cp -a -- "$source" "$snapshot/$entry" || return 1
        elif [ -e "$source" ]; then
            orocos_rock_info "Cannot preserve installed environment entry that is not a file: $source"
            return 1
        else
            : >"$snapshot/$entry.missing" || return 1
        fi
    done
}

orocos_rock_restore_install_env() {
    local prefix="$1"
    local snapshot="$2"
    local entry
    local destination

    for entry in env.sh dev-env.sh; do
        if [ ! -e "$snapshot/$entry" ] && [ ! -L "$snapshot/$entry" ] &&
           [ ! -f "$snapshot/$entry.missing" ]; then
            orocos_rock_info "Installed environment snapshot is incomplete: $snapshot"
            return 1
        fi

        destination="$prefix/$entry"
        if [ -d "$destination" ] && [ ! -L "$destination" ]; then
            orocos_rock_info "Cannot restore installed environment over a directory: $destination"
            return 1
        fi
    done

    mkdir -p "$prefix" || return 1
    for entry in env.sh dev-env.sh; do
        destination="$prefix/$entry"
        rm -f -- "$destination" || return 1
        if [ -e "$snapshot/$entry" ] || [ -L "$snapshot/$entry" ]; then
            cp -a -- "$snapshot/$entry" "$destination" || return 1
        fi
    done

    orocos_rock_cleanup_install_env_snapshot "$snapshot" || return 1
}

orocos_rock_run_preserving_install_env() {
    local prefix="$1"
    local snapshot
    local command_status
    local restore_status
    shift

    snapshot="$(mktemp -d "${TMPDIR:-/tmp}/orocos-rock-install-env.XXXXXX")" || return 1
    if ! orocos_rock_snapshot_install_env "$prefix" "$snapshot"; then
        orocos_rock_cleanup_install_env_snapshot "$snapshot" || true
        return 1
    fi

    if "$@"; then
        command_status=0
    else
        command_status=$?
    fi

    if orocos_rock_restore_install_env "$prefix" "$snapshot"; then
        restore_status=0
    else
        restore_status=$?
        orocos_rock_info "Failed to restore installed environment from $snapshot"
    fi

    if [ "$restore_status" -ne 0 ]; then
        return "$restore_status"
    fi
    return "$command_status"
}

orocos_rock_user_gem_home() {
    ruby -rrubygems -e 'print Gem.user_dir'
}

orocos_rock_user_gem_path() {
    ruby -rrubygems -e 'paths = [Gem.user_dir] + Gem.path + Gem.default_path; print paths.uniq.join(":")'
}

orocos_rock_validate_target() {
    case "$1" in
        gnulinux|xenomai) ;;
        *) orocos_rock_die "unsupported Orocos target '$1'; expected gnulinux or xenomai" ;;
    esac
}

orocos_rock_target_deployer() {
    case "$1" in
        gnulinux) printf '%s\n' "deployer-gnulinux" ;;
        xenomai) printf '%s\n' "deployer-xenomai" ;;
        *) orocos_rock_die "unsupported Orocos target '$1'; expected gnulinux or xenomai" ;;
    esac
}

orocos_rock_target_opcua_deployer() {
    orocos_rock_validate_target "$1"
    printf '%s\n' "deployer-opcua-$1"
}

orocos_rock_validate_deployer_version_output() {
    target="$1"
    output="$2"

    case "$target" in
        gnulinux)
            grep -q "OROCOS Toolchain version" <<<"$output"
            ;;
        xenomai)
            grep -q "Xenomai/cobalt" <<<"$output"
            ;;
        *)
            orocos_rock_die "unsupported Orocos target '$target'; expected gnulinux or xenomai"
            ;;
    esac
}

orocos_rock_configure_target_environment() {
    target="$1"
    orocos_rock_validate_target "$target"
    export OROCOS_TARGET="$target"

    if [ "$target" = "xenomai" ]; then
        export XENOMAI_DIR="${XENOMAI_DIR:-$OROCOS_ROCK_DEFAULT_XENOMAI_DIR}"
        export XENOMAI_ROOT_DIR="${XENOMAI_ROOT_DIR:-$XENOMAI_DIR}"
        if [ -x "$XENOMAI_DIR/bin/xeno-config" ]; then
            case ":${PATH:-}:" in
                *:"$XENOMAI_DIR/bin":*) ;;
                *) export PATH="$XENOMAI_DIR/bin:${PATH:-}" ;;
            esac
        fi
        orocos_rock_require_command xeno-config
    fi
}

orocos_rock_prepare_autoproj_workspace() {
    prefix="$1"
    osdeps_mode="${2:-none}"
    target="${3:-$OROCOS_ROCK_DEFAULT_TARGET}"
    orocos_rock_validate_target "$target"
    ruby_version="$(ruby -e 'print RUBY_VERSION')"
    ruby_executable="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        bundler_executable="$(ruby -e 'gem "bundler", "= 2.6.9"; print Gem.bin_path("bundler", "bundle", "= 2.6.9")')"
    else
        bundler_executable="$(ruby -e 'gem "bundler"; print Gem.bin_path("bundler", "bundle")')"
    fi
    mkdir -p "$OROCOS_ROCK_ROOT/.autoproj"
    mkdir -p "$OROCOS_ROCK_ROOT/.autoproj/bin"
    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        locked_bundler_cache="$OROCOS_ROCK_ROOT/.autoproj/vendor/cache"
        mkdir -p "$locked_bundler_cache"
        find "$locked_bundler_cache" -mindepth 1 -delete
        locked_gem_paths="$({ ruby "$OROCOS_ROCK_ROOT/tools/locked-ruby-gems.rb" paths \
            "$OROCOS_ROCK_RUBY_GEM_CACHE"; } 2>&1)" || orocos_rock_die "$locked_gem_paths"
        while IFS= read -r gem_path; do
            cp -- "$gem_path" "$locked_bundler_cache/"
        done <<<"$locked_gem_paths"
    fi
    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        cat >"$OROCOS_ROCK_ROOT/.autoproj/bin/bundle" <<EOF
#! /bin/sh
export BUNDLE_CACHE_PATH="$locked_bundler_cache"
export BUNDLE_DISABLE_VERSION_CHECK=true
case "\${1:-}" in
    install)
        shift
        exec "$ruby_executable" "$bundler_executable" install --local "\$@"
        ;;
    *) exec "$ruby_executable" "$bundler_executable" "\$@" ;;
esac
EOF
    else
        cat >"$OROCOS_ROCK_ROOT/.autoproj/bin/bundle" <<EOF
#! /bin/sh
exec "$ruby_executable" "$bundler_executable" "\$@"
EOF
    fi
    chmod +x "$OROCOS_ROCK_ROOT/.autoproj/bin/bundle"
    cp "$OROCOS_ROCK_ROOT/.autoproj/bin/bundle" "$OROCOS_ROCK_ROOT/.autoproj/bin/bundler"
    autoproj_gem_path="$(orocos_rock_user_gem_path)"
    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        cat >"$OROCOS_ROCK_ROOT/.autoproj/bin/autoproj" <<EOF
#!$ruby_executable
require "rubygems"
ENV["AUTOPROJ_CURRENT_ROOT"] = "$OROCOS_ROCK_ROOT"
ENV["BUNDLE_GEMFILE"] ||= "$OROCOS_ROCK_ROOT/.autoproj/Gemfile"
ENV["GEM_PATH"] = "$autoproj_gem_path"
Gem.clear_paths
require "$OROCOS_ROCK_ROOT/tools/locked-ruby-gems"
OrocosRock::LockedRubyGems.activate_autoproj!
gem "autoproj", "= 2.18.1"
load Gem.bin_path("autoproj", "autoproj")
EOF
    else
        cat >"$OROCOS_ROCK_ROOT/.autoproj/bin/autoproj" <<EOF
#!$ruby_executable
require "rubygems"
ENV["AUTOPROJ_CURRENT_ROOT"] = "$OROCOS_ROCK_ROOT"
ENV["BUNDLE_GEMFILE"] ||= "$OROCOS_ROCK_ROOT/.autoproj/Gemfile"
ENV["GEM_PATH"] = "$autoproj_gem_path"
Gem.clear_paths
gem "facets", "< 3.2"
load Gem.bin_path("autoproj", "autoproj")
EOF
    fi
    chmod +x "$OROCOS_ROCK_ROOT/.autoproj/bin/autoproj"
    cat >"$OROCOS_ROCK_ROOT/.autoproj/Gemfile" <<EOF
source "https://rubygems.org"
ruby "$ruby_version" if respond_to?(:ruby)
EOF
    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        ruby "$OROCOS_ROCK_ROOT/tools/locked-ruby-gems.rb" gemfile >>"$OROCOS_ROCK_ROOT/.autoproj/Gemfile"
    else
        cat >>"$OROCOS_ROCK_ROOT/.autoproj/Gemfile" <<'EOF'
gem "autoproj", ">= 2.18.0"
gem "facets", "= 3.1.0"
config_path = File.join(__dir__, 'config.yml')
if File.file?(config_path)
    require 'yaml'
    config = YAML.load(File.read(config_path)) || Hash.new
    (config['plugins'] || Hash.new).
        each do |plugin_name, (version, options)|
            gem plugin_name, version, **options
        end
end
EOF
    fi
    cat >"$OROCOS_ROCK_ROOT/.autoproj/config.yml" <<EOF
prefix: "$prefix"
gems_install_path: "$OROCOS_ROCK_ROOT/.autoproj/gems"
osdeps_mode: "$osdeps_mode"
apt_dpkg_update: false
prefer_indep_over_os_packages: false
USE_OCL: true
rtt_target: "$target"
rtt_corba_implementation: none
XENOMAI_DIR: "${XENOMAI_DIR:-$OROCOS_ROCK_DEFAULT_XENOMAI_DIR}"
EOF
}

orocos_rock_require_autoproj() {
    orocos_rock_require_command ruby
    gem_path="$(orocos_rock_user_gem_path)"
    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        GEM_PATH="$gem_path" ruby "$OROCOS_ROCK_ROOT/tools/locked-ruby-gems.rb" activate \
            >/dev/null 2>&1 ||
            orocos_rock_die "locked Autoproj 2.18.1 Ruby gems are not usable"
    else
        GEM_PATH="$gem_path" \
            ruby -e 'gem "facets", "< 3.2"; gem "autoproj"; require "facets/kernel/constant"' >/dev/null 2>&1 ||
            orocos_rock_die "Autoproj Ruby gems are not usable; run ./tools/install-autoproj.sh"
    fi
}

orocos_rock_workspace_gem_home() {
    ruby -rrbconfig -e 'print File.join(ARGV.fetch(0), ".autoproj", "gems", "ruby", RbConfig::CONFIG.fetch("ruby_version"))' "$OROCOS_ROCK_ROOT"
}

orocos_rock_install_workspace_gem() {
    gem_name="$1"
    gem_version="${2:-}"
    workspace_gem_home="$3"

    cache_path="$(ruby -e 'name = ARGV.fetch(0); version = ARGV[1]; specs = Gem::Specification.find_all_by_name(name, version && !version.empty? ? "= #{version}" : nil); spec = specs.first; if spec; path = File.join(spec.cache_dir, "#{spec.full_name}.gem"); print path if File.file?(path); end' "$gem_name" "$gem_version")"
    downloaded_gem_path=""

    if [ -n "$gem_version" ]; then
        orocos_rock_info "Installing $gem_name $gem_version into workspace Ruby gems"
    else
        orocos_rock_info "Installing $gem_name into workspace Ruby gems"
    fi

    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        [ -n "$gem_version" ] ||
            orocos_rock_die "cached Ruby gem installs require an exact version: $gem_name"
        locked_gem_path="$(orocos_rock_cached_gem_path "$gem_name" "$gem_version")"
        gem install --install-dir "$workspace_gem_home" --local --no-document "$locked_gem_path"
    elif [ -n "$cache_path" ]; then
        gem install --install-dir "$workspace_gem_home" --no-document "$cache_path"
    elif [ -n "$gem_version" ] && command -v curl >/dev/null 2>&1; then
        downloaded_gem_path="${TMPDIR:-/tmp}/$gem_name-$gem_version.gem"
        curl --fail --location --retry 5 --retry-delay 2 --retry-connrefused \
            --output "$downloaded_gem_path" "https://rubygems.org/downloads/$gem_name-$gem_version.gem"
        gem install --install-dir "$workspace_gem_home" --local --no-document "$downloaded_gem_path"
    elif [ -n "$gem_version" ]; then
        gem install --install-dir "$workspace_gem_home" --no-document "$gem_name" -v "$gem_version"
    else
        gem install --install-dir "$workspace_gem_home" --no-document "$gem_name"
    fi
}

orocos_rock_ensure_workspace_ruby_gems() {
    orocos_rock_require_command gem

    workspace_gem_home="$(orocos_rock_workspace_gem_home)"
    if GEM_HOME="$workspace_gem_home" GEM_PATH="" BUNDLE_GEMFILE="" \
        ruby -e 'gem "facets", "< 3.2"; require "facets/module/spacename"; gem "backports"; require "backports/2.4.0/true_class/dup"' >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p "$workspace_gem_home"
    orocos_rock_install_workspace_gem facets 3.1.0 "$workspace_gem_home"
    orocos_rock_install_workspace_gem backports 3.25.3 "$workspace_gem_home"
}

orocos_rock_autoproj() {
    gem_path="$(orocos_rock_user_gem_path)"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$OROCOS_ROCK_ROOT/.autoproj/xdg}"
    export GEM_PATH
    GEM_PATH="$gem_path"
    if [ -n "${OROCOS_ROCK_RUBY_GEM_CACHE:-}" ]; then
        BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$OROCOS_ROCK_ROOT/.autoproj/Gemfile}" \
            ruby -r"$OROCOS_ROCK_ROOT/tools/locked-ruby-gems.rb" \
            -e 'OrocosRock::LockedRubyGems.activate_autoproj!; gem "autoproj", "= 2.18.1"; load Gem.bin_path("autoproj", "autoproj")' -- "$@"
    else
        BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$OROCOS_ROCK_ROOT/.autoproj/Gemfile}" \
            ruby -e 'gem "facets", "< 3.2"; load Gem.bin_path("autoproj", "autoproj")' -- "$@"
    fi
}

orocos_rock_source_workspace_env() {
    if [ -f "$OROCOS_ROCK_ROOT/env.sh" ] &&
       [ -f "$OROCOS_ROCK_ROOT/.autoproj/env.sh" ] &&
       [ -f "$OROCOS_ROCK_ROOT/.bundle_env.sh" ]; then
        local nounset_was_enabled=0
        local source_status=0

        case "$-" in
            *u*) nounset_was_enabled=1 ;;
        esac
        set +u
        # shellcheck disable=SC1091
        if . "$OROCOS_ROCK_ROOT/env.sh"; then
            source_status=0
        else
            source_status=$?
        fi
        if [ "$nounset_was_enabled" -eq 1 ]; then
            set -u
        else
            set +u
        fi
        return "$source_status"
    fi
}
