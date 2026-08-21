#!/usr/bin/env ruby

require "open3"

root = File.expand_path("..", __dir__)
agents_path = File.join(root, "AGENTS.md")
readme_path = File.join(root, "README.md")
workflow_path = File.join(root, ".github", "workflows", "repository-policy.yml")
xenomai3_path = File.join(root, "docs", "src", "xenomai3-integration.md")
docs_src = File.join(root, "docs", "src")
summary_path = File.join(docs_src, "SUMMARY.md")
todo_dir = File.join(docs_src, "todo")
errors = []

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

if !File.file?(workflow_path)
  errors << "missing .github/workflows/repository-policy.yml"
else
  workflow = File.read(workflow_path)

  errors << "repository policy workflow must run on pull requests" unless workflow.include?("pull_request:")
  errors << "repository policy workflow must run on pushes to main" unless workflow.include?("push:") && workflow.include?("- main")
  errors << "repository policy workflow must support manual dispatch" unless workflow.include?("workflow_dispatch:")
  %w[
    "AGENTS.md"
    "README.md"
    ".github/workflows/docs.yml"
    ".github/workflows/linux-packages.yml"
    ".github/workflows/repository-policy.yml"
    ".github/workflows/windows-packages.yml"
    "docs/book/**"
    "docs/src/**"
    "docs/superpowers/**"
    "examples/pixi-consumer/**"
    "tools/check-repository-policy.rb"
    "tools/check-docs.rb"
    "tools/check-linux-package-ci.rb"
    "tools/check-source-provenance.rb"
    "tools/check-windows-package-ci.rb"
    "tools/prepare-windows-conda-release.ps1"
    "tools/test-pixi-consumer-activation.rb"
    "tools/test-source-provenance.rb"
    "tools/test-windows-package-ci.rb"
    "tools/test-windows-conda-consumer.ps1"
    "tools/prepare-linux-conda-release.rb"
    "tools/test-linux-conda-consumer.sh"
    "tools/test-linux-prefix-sanitizer.rb"
    "packaging/**"
    "pixi.toml"
    "pixi.lock"
  ].each do |path|
    errors << "repository policy workflow must watch #{path}" unless workflow.include?(path)
  end
  errors << "repository policy workflow must run repository policy check" unless workflow.include?("ruby tools/check-repository-policy.rb")
  errors << "repository policy workflow must run Pixi consumer activation tests" unless workflow.include?("ruby tools/test-pixi-consumer-activation.rb")
  errors << "repository policy workflow must run source provenance test" unless workflow.include?("ruby tools/test-source-provenance.rb")
  errors << "repository policy workflow must run source provenance check" unless workflow.include?("ruby tools/check-source-provenance.rb")
  errors << "repository policy workflow must run Windows package CI mutation tests" unless workflow.include?("ruby tools/test-windows-package-ci.rb")
  errors << "repository policy workflow must run Windows package CI policy check" unless workflow.include?("ruby tools/check-windows-package-ci.rb")
  errors << "repository policy workflow must run Linux package CI policy check" unless workflow.include?("ruby tools/check-linux-package-ci.rb")
  errors << "repository policy workflow must run Linux prefix sanitizer tests" unless workflow.include?("ruby tools/test-linux-prefix-sanitizer.rb")
  errors << "repository policy workflow must run documentation policy check" unless workflow.include?("ruby tools/check-docs.rb")
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
