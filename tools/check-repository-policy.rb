#!/usr/bin/env ruby

require "open3"
require "yaml"

SETUP_PIXI_ACTION = "prefix-dev/setup-pixi@f00437f565399d418b0acc85936d12c1fb668347".freeze
PIXI_ACTIVATION_COMMAND = "pixi workspace activation list " \
                          "--manifest-path examples/pixi-consumer/pixi.toml"

def executable_commands(step)
  step.fetch("run", "").lines.map(&:strip).reject do |line|
    line.empty? || line.start_with?("#")
  end
end

def normalize_command(command)
  command.to_s.gsub(/\s+/, " ").strip
end

root = File.expand_path("..", __dir__)
agents_path = File.join(root, "AGENTS.md")
readme_path = File.join(root, "README.md")
pixi_manifest_path = File.join(root, "pixi.toml")
repository_workflow_path = File.join(root, ".github", "workflows", "repository-policy.yml")
docs_workflow_path = File.join(root, ".github", "workflows", "docs.yml")
xenomai3_path = File.join(root, "docs", "src", "xenomai3-integration.md")
docs_src = File.join(root, "docs", "src")
summary_path = File.join(docs_src, "SUMMARY.md")
todo_dir = File.join(docs_src, "todo")
errors = []

if !File.file?(pixi_manifest_path)
  errors << "missing pixi.toml"
else
  pixi_manifest = File.read(pixi_manifest_path)
  package_dependencies = pixi_manifest[
    /^\[feature\.package\.dependencies\]\s*$\n(.*?)(?=^\[|\z)/m, 1
  ].to_s
  %w[python zstd].each do |dependency|
    unless package_dependencies.match?(/^#{Regexp.escape(dependency)}\s*=/)
      errors << "Pixi package environment must explicitly depend on #{dependency}"
    end
  end
end

%w[docs/book docs/superpowers].each do |directory|
  tracked_files, git_status = Open3.capture2(
    "git", "-c", "safe.directory=#{root}",
    "-C", root, "ls-files", "--", directory
  )

  unless git_status.success?
    errors << "failed to inspect tracked #{directory} files"
  end

  tracked_files.lines.map(&:strip).reject(&:empty?).each do |path|
    errors << "#{path}: #{directory} files must remain untracked"
  end
end

tracked_markdown, markdown_status = Open3.capture2(
  "git", "-c", "safe.directory=#{root}",
  "-C", root, "ls-files", "-z", "--", "*.md"
)

if !markdown_status.success?
  errors << "failed to inspect tracked Markdown files"
else
  tracked_markdown.split("\0").reject(&:empty?).sort.each do |relative|
    page = File.join(root, relative)
    next unless File.file?(page)

    File.read(page).scan(/\]\(([^)]+)\)/).flatten.each do |target|
      local_target = target.split("#", 2).first
      next if local_target.empty?
      next unless local_target.end_with?(".md")
      next if local_target.match?(/\A[a-z][a-z0-9+.-]*:/i)

      resolved = File.expand_path(local_target, File.dirname(page))
      unless File.file?(resolved)
        errors << "#{relative}: missing link target #{local_target}"
      end
    end
  end
end

required_policy_links = {
  "README.md" => "./README.md",
  "docs/src/architecture.md" => "./docs/src/architecture.md",
  "docs/src/package-policy.md" => "./docs/src/package-policy.md",
  "docs/src/install-contract.md" => "./docs/src/install-contract.md"
}.freeze

if !File.file?(agents_path)
  errors << "missing AGENTS.md"
else
  agents = File.read(agents_path)

  errors << "AGENTS.md: must describe the standalone Orocos/Rock toolchain contract" unless agents.include?("standalone Orocos/Rock toolchain")

  required_policy_links.each do |label, target|
    markdown_link = "[#{label}](#{target})"
    errors << "AGENTS.md: missing policy link #{markdown_link}" unless agents.include?(markdown_link)
  end

  %w[
    ./docs/architecture.md
    ./docs/package-policy.md
    ./docs/install-contract.md
  ].each do |stale_target|
    errors << "AGENTS.md: must not link stale path #{stale_target}" if agents.include?(stale_target)
  end
end

if !File.file?(readme_path)
  errors << "missing README.md"
else
  readme = File.read(readme_path)
  %w[
    ./docs/src/architecture.md
    ./docs/src/package-policy.md
    ./docs/src/install-contract.md
  ].each do |target|
    errors << "README.md: missing policy link #{target}" unless readme.include?(target)
  end
end

if !File.file?(xenomai3_path)
  errors << "missing docs/src/xenomai3-integration.md"
else
  xenomai3 = File.read(xenomai3_path)
  [
    "ahoarau-xenomai3-support-v2",
    "CPU affinity",
    "rt_task_join",
    "OROCOS_TARGET=xenomai",
    "deployer-xenomai",
    "libfakeethercat"
  ].each do |token|
    errors << "docs/src/xenomai3-integration.md: missing #{token}" unless xenomai3.include?(token)
  end
end

if !File.file?(repository_workflow_path)
  errors << "missing .github/workflows/repository-policy.yml"
else
  workflow = YAML.safe_load(File.read(repository_workflow_path), aliases: true) || {}
  triggers = workflow["on"] || workflow[true] || {}
  unless triggers.is_a?(Hash)
    errors << "repository policy workflow must define structured workflow triggers"
    triggers = {}
  end

  pull_request = triggers.fetch("pull_request", {}) || {}
  push = triggers.fetch("push", {}) || {}
  errors << "repository policy workflow must run on pull requests" unless triggers.key?("pull_request")
  errors << "repository policy workflow must run on pushes" unless triggers.key?("push")
  unless Array(push["branches"]) == ["main"]
    errors << "repository policy workflow pushes must be limited to main"
  end
  errors << "repository policy workflow must support manual dispatch" unless triggers.key?("workflow_dispatch")

  required_paths = %w[
    AGENTS.md
    README.md
    .github/workflows/docs.yml
    .github/workflows/linux-packages.yml
    .github/workflows/repository-policy.yml
    .github/workflows/windows-packages.yml
    docs/book/**
    docs/src/**
    docs/superpowers/**
    examples/pixi-consumer/**
    tools/check-repository-policy.rb
    tools/check-docs.rb
    tools/check-linux-package-ci.rb
    tools/check-source-provenance.rb
    tools/check-windows-package-ci.rb
    tools/inspect-conda-archive.py
    tools/prepare-windows-conda-release.ps1
    tools/test-pixi-consumer-activation.rb
    tools/test-source-provenance.rb
    tools/test-windows-package-ci.rb
    tools/test-windows-conda-consumer.ps1
    tools/prepare-linux-conda-release.rb
    tools/test-linux-conda-consumer.sh
    tools/test-linux-prefix-sanitizer.rb
    tools/test-linux-source-lock.rb
    tools/test-linux-conda-release.py
    packaging/**
    pixi.toml
    pixi.lock
  ].each do |path|
    {
      "pull requests" => Array(pull_request["paths"]),
      "main pushes" => Array(push["paths"])
    }.each do |trigger_name, paths|
      errors << "repository policy workflow #{trigger_name} must watch #{path}" unless paths.include?(path)
    end
  end

  policy_steps = Array(workflow.dig("jobs", "policy", "steps"))
  repository_policy_step = policy_steps.find { |step| step["name"] == "Check repository policy" }
  if repository_policy_step.nil?
    errors << "repository policy workflow must define the Check repository policy step"
  else
    commands = executable_commands(repository_policy_step)
    {
      "ruby tools/check-repository-policy.rb" => "repository policy workflow must run repository policy check",
      "ruby tools/test-windows-package-ci.rb" => "repository policy workflow must run Windows package CI mutation tests",
      "ruby tools/check-windows-package-ci.rb" => "repository policy workflow must run Windows package CI policy check",
      "ruby tools/check-linux-package-ci.rb" => "repository policy workflow must run Linux package CI policy check",
      "python3 tools/test-linux-conda-release.py" => "repository policy workflow must run Linux conda archive tests",
      "ruby tools/test-linux-prefix-sanitizer.rb" => "repository policy workflow must run Linux prefix sanitizer tests",
      "ruby tools/check-docs.rb" => "repository policy workflow must run documentation policy check",
      "ruby tools/test-pixi-consumer-activation.rb" => "repository policy workflow must run Pixi consumer activation tests"
    }.each do |command, message|
      errors << message unless commands.include?(command)
    end
  end

  provenance_step = policy_steps.find { |step| step["name"] == "Check source provenance" }
  if provenance_step.nil?
    errors << "repository policy workflow must define the Check source provenance step"
  else
    commands = executable_commands(provenance_step)
    {
      "ruby tools/test-linux-source-lock.rb" => "repository policy workflow must run Linux source-lock test",
      "ruby tools/test-source-provenance.rb" => "repository policy workflow must run source provenance test",
      "ruby tools/check-source-provenance.rb" => "repository policy workflow must run source provenance check"
    }.each do |command, message|
      errors << message unless commands.include?(command)
    end
  end
end

if !File.file?(docs_workflow_path)
  errors << "missing .github/workflows/docs.yml"
else
  docs_workflow = YAML.safe_load(File.read(docs_workflow_path), aliases: true) || {}
  docs_triggers = docs_workflow["on"] || docs_workflow[true] || {}
  docs_triggers = {} unless docs_triggers.is_a?(Hash)
  docs_pull_request = docs_triggers.fetch("pull_request", {}) || {}
  docs_push = docs_triggers.fetch("push", {}) || {}
  {
    "pull requests" => Array(docs_pull_request["paths"]),
    "main pushes" => Array(docs_push["paths"])
  }.each do |trigger_name, paths|
    unless paths.include?("examples/pixi-consumer/**")
      errors << "documentation workflow #{trigger_name} must watch examples/pixi-consumer/**"
    end
  end

  docs_steps = Array(docs_workflow.dig("jobs", "build", "steps"))
  setup_step = docs_steps.find { |step| step["name"] == "Set up locked documentation environment" }
  if setup_step.nil?
    errors << "documentation workflow must set up the locked documentation environment"
  else
    unless setup_step["uses"] == SETUP_PIXI_ACTION
      errors << "documentation workflow must use the pinned setup-pixi action"
    end
    unless setup_step.dig("with", "pixi-version") == "v0.76.2"
      errors << "documentation workflow must pin Pixi v0.76.2"
    end
    unless setup_step.dig("with", "environments") == "docs" &&
           setup_step.dig("with", "locked") == true
      errors << "documentation workflow must install the locked docs environment"
    end
  end

  manual_index = docs_steps.index { |step| step["name"] == "Validate and build the manual" }
  activation_index = docs_steps.index { |step| step["name"] == "Validate Pixi consumer activation example" }
  errors << "documentation workflow must validate and build the manual" if manual_index.nil?
  if activation_index.nil?
    errors << "documentation workflow must validate the Pixi consumer activation example"
  else
    activation_step = docs_steps.fetch(activation_index)
    unless normalize_command(activation_step["run"]) == PIXI_ACTIVATION_COMMAND
      errors << "documentation workflow Pixi activation must use the exact parse-only command"
    end
  end
  if manual_index && activation_index && activation_index != manual_index + 1
    errors << "documentation workflow must validate Pixi activation immediately after the manual"
  end
end

if !File.file?(summary_path)
  errors << "missing docs/src/SUMMARY.md"
else
  summary = File.read(summary_path)
  summary_targets = summary.scan(/\]\(([^)#]+\.md)(?:#[^)]+)?\)/)
                           .flatten
                           .map { |target| File.expand_path(target, docs_src) }
                           .uniq
  source_pages = Dir[File.join(docs_src, "**", "*.md")]
                 .reject { |path| path == summary_path }
                 .sort

  source_pages.each do |path|
    relative = path.delete_prefix("#{docs_src}/")
    unless summary_targets.include?(path)
      errors << "docs/src/#{relative}: missing from SUMMARY.md"
    end
  end

  summary_targets.each do |path|
    next if File.file?(path)

    errors << "docs/src/SUMMARY.md: missing target #{path.delete_prefix("#{root}/")}"
  end

  implementation_plans = source_pages.reject do |path|
    path.start_with?("#{todo_dir}/")
  end.select do |path|
    File.basename(path).end_with?("-plan.md")
  end
  implementation_plans.each do |path|
    errors << "#{path.delete_prefix("#{root}/")}: implementation plans belong below docs/src/todo"
  end
end

Dir[File.join(todo_dir, "**", "*.md")].sort.each do |path|
  next if File.basename(path) == "index.md"

  content = File.read(path)
  relative = path.delete_prefix("#{root}/")
  unless content.include?("Status: Planned and not implemented")
    errors << "#{relative}: missing planned-status marker"
  end
  todo = content[/^## TODO$\n(.*?)(?=^## |\z)/m, 1]
  unless todo&.match?(/^- \[ \] /)
    errors << "#{relative}: missing TODO outcome checklist"
  end
  stable_contracts = content[/^## Stable Contracts$\n(.*?)(?=^## |\z)/m, 1]
  unless stable_contracts&.match?(/\]\(\.\.\/[^)#]+\.md(?:#[^)]+)?\)/)
    errors << "#{relative}: missing stable-contract links"
  end
  acceptance_criteria = content[/^## Acceptance Criteria$\n(.*?)(?=^## |\z)/m, 1]
  unless acceptance_criteria&.match?(/^(?:- |\d+\. )/)
    errors << "#{relative}: missing acceptance criteria"
  end
end

if errors.any?
  warn errors.join("\n")
  exit 1
end
