#!/usr/bin/env ruby

require "pathname"
require "set"

def strip_html_comments(contents)
  contents.gsub(/<!--.*?-->/m, "")
end

def level_two_section(contents, heading)
  match = contents.match(/^#{Regexp.escape(heading)}\r?\n(.*?)(?=^## |\z)/m)
  match && match[1]
end

def fenced_blocks(contents, language = nil)
  fence_type = language ? Regexp.escape(language) : "[^\\r\\n]*"
  contents.scan(/^```#{fence_type}[ \t]*\r?\n(.*?)^```[ \t]*\r?$/m).flatten
end

def fenced_command?(contents, command)
  fenced_blocks(contents).any? do |block|
    block.lines.any? { |line| line.strip == command }
  end
end

root = File.expand_path("..", __dir__)
docs = File.join(root, "docs")
source = File.join(docs, "src")
summary_path = File.join(source, "SUMMARY.md")
recipe_path = File.join(root, "packaging", "conda", "recipe.yaml")
errors = []

recipe = File.read(recipe_path)
package_version = recipe[/^  version:\s*"([^"]+)"\s*$/, 1]
abort "missing package version in packaging/conda/recipe.yaml" unless package_version

unless File.file?(summary_path)
  abort "missing docs/src/SUMMARY.md"
end

summary = File.read(summary_path)
summary_targets = summary.scan(/\]\(([^)#]+\.md)(?:#[^)]+)?\)/)
                         .flatten
                         .map { |target| File.expand_path(target, source) }
duplicates = summary_targets.tally.select { |_path, count| count > 1 }.keys
duplicates.each do |path|
  errors << "SUMMARY.md includes #{Pathname(path).relative_path_from(Pathname(source))} more than once"
end

pages = Dir[File.join(source, "**", "*.md")]
        .reject { |path| path == summary_path }
        .sort
missing_from_summary = pages.to_set - summary_targets.to_set
extra_in_summary = summary_targets.to_set - pages.to_set
missing_from_summary.each do |path|
  errors << "#{Pathname(path).relative_path_from(Pathname(root))} is missing from SUMMARY.md"
end
extra_in_summary.each do |path|
  errors << "SUMMARY.md points to missing page #{Pathname(path).relative_path_from(Pathname(root))}"
end

pages.each do |page|
  relative = Pathname(page).relative_path_from(Pathname(root))
  contents = File.read(page)
  visible_contents = strip_html_comments(contents)
  headings = visible_contents.scan(/^# (.+)$/)
  errors << "#{relative} must contain exactly one level-one heading" unless headings.size == 1
  first_content = visible_contents.lines.find { |line| !line.strip.empty? }
  errors << "#{relative} must start with its level-one heading" unless first_content&.start_with?("# ")

  visible_contents.scan(/\]\(([^)]+)\)/).flatten.each do |target|
    local = target.split("#", 2).first
    next if local.empty? || local.match?(/\A[a-z][a-z0-9+.-]*:/i)
    next if local.start_with?("/")

    resolved = File.expand_path(local, File.dirname(page))
    relative_to_source = Pathname(resolved).relative_path_from(Pathname(source))
    if relative_to_source.each_filename.first == ".."
      errors << "#{relative}: relative link #{local} points outside docs/src; use an absolute repository URL"
    elsif !File.exist?(resolved)
      errors << "#{relative}: missing local link #{local}"
    end
  end
end

book_config = File.read(File.join(docs, "book.toml"))
{
  "Mermaid preprocessor" => "mdbook-mermaid",
  "published site path" => 'site-url = "/rock-orocos/"',
  "source repository" => 'git-repository-url = "https://github.com/liufang-robot/rock-orocos"'
}.each do |contract, token|
  errors << "docs/book.toml is missing #{contract}" unless book_config.include?(token)
end

readme = strip_html_comments(File.read(File.join(root, "README.md")))
unless readme.include?("(./docs/src)")
  errors << "README.md must link to the manual sources"
end
unless File.read(File.join(root, "packaging", "README.md")).include?("../docs/src/release-guide.md")
  errors << "packaging/README.md must point to the canonical release guide"
end

activation_block = <<~TOML.chomp
  [target.unix.activation]
  scripts = ["scripts/activate-orocos.sh"]

  [target.win.activation]
  scripts = ["scripts/activate-orocos.ps1"]
TOML

package_guide = strip_html_comments(File.read(File.join(source, "conda-packages.md")))
automatic_activation = level_two_section(package_guide, "## Automatic Pixi Activation")
if automatic_activation.nil?
  errors << "package guide is missing the Automatic Pixi Activation section"
else
  unless fenced_blocks(automatic_activation, "toml").any? { |block| block.include?(activation_block) }
    errors << "Automatic Pixi Activation must contain the exact target activation TOML"
  end
  unless fenced_command?(automatic_activation, "pixi shell")
    errors << "Automatic Pixi Activation must contain a fenced pixi shell command"
  end
  {
    "Windows runtime batch entrypoint" => 'Library\env.bat',
    "Windows package activation hook" =>
      'etc\conda\activate.d\orocos-activate.bat',
    "runtime-only Windows package activation" =>
      'Runtime-only Windows consumers do not need `[target.win.activation]`'
  }.each do |contract, token|
    unless automatic_activation.include?(token)
      errors << "Automatic Pixi Activation is missing #{contract}"
    end
  end
end

example_manifest_path = File.join(root, "examples", "pixi-consumer", "pixi.toml")
if !File.file?(example_manifest_path)
  errors << "missing examples/pixi-consumer/pixi.toml"
else
  example_manifest = File.read(example_manifest_path)
  unless example_manifest.include?(activation_block)
    errors << "examples/pixi-consumer/pixi.toml is missing the exact target activation TOML"
  end
  unless example_manifest.include?(%Q{orocos-dev = "==#{package_version}"})
    errors << "examples/pixi-consumer/pixi.toml must select orocos-dev==#{package_version}"
  end
end

[
  "examples/pixi-consumer/scripts/activate-orocos.sh",
  "examples/pixi-consumer/scripts/activate-orocos.ps1"
].each do |wrapper|
  errors << "missing #{wrapper}" unless File.file?(File.join(root, wrapper))
end

manual_fallback = level_two_section(package_guide, "## Manual Fallback")
if manual_fallback.nil?
  errors << "package guide is missing the Manual Fallback section"
else
  {
    "Unix development" => 'source "$CONDA_PREFIX/dev-env.sh"',
    "Unix runtime" => 'source "$CONDA_PREFIX/env.sh"',
    "Windows development" => '. "$env:CONDA_PREFIX\Library\dev-env.ps1"',
    "Windows PowerShell runtime" => '. "$env:CONDA_PREFIX\Library\env.ps1"',
    "Windows cmd runtime" => 'call "%CONDA_PREFIX%\Library\env.bat"'
  }.each do |contract, command|
    unless manual_fallback.include?(command)
      errors << "Manual Fallback is missing the #{contract} command"
    end
  end
end

install_contract = strip_html_comments(
  File.read(File.join(source, "install-contract.md"))
)
{
  "Windows batch runtime entrypoint" => '`env.bat`',
  "Windows Conda activation hook" =>
    '`etc/conda/activate.d/orocos-activate.bat`',
  "PowerShell compatibility entrypoint" => '`env.ps1`',
  "development entrypoint" => '`dev-env.ps1`'
}.each do |contract, token|
  unless install_contract.include?(token)
    errors << "install contract is missing #{contract}"
  end
end

install_with_pixi = level_two_section(readme, "## Install With Pixi")
if install_with_pixi.nil?
  errors << "README.md is missing the Install With Pixi section"
else
  example_url = "https://github.com/liufang-robot/rock-orocos/tree/main/examples/pixi-consumer"
  errors << "Install With Pixi must link to the canonical consumer example" unless install_with_pixi.include?(example_url)
  expected_dependency = "orocos-dev==#{package_version}"
  unless install_with_pixi.include?(expected_dependency)
    errors << "Install With Pixi must select #{expected_dependency}"
  end
  unless fenced_command?(install_with_pixi, "pixi shell")
    errors << "Install With Pixi must contain a fenced pixi shell command"
  end
  if install_with_pixi.match?(/\bsource\s+[^\n]*(?:dev-)?env\.sh/) ||
     install_with_pixi.match?(/^\s*\.\s+[^\n]*(?:dev-)?env\.ps1/m)
    errors << "Install With Pixi must not contain manual environment fallback commands"
  end
end

channel_description =
  "Standalone Orocos RTT runtime and development toolchain for Linux and " \
  "Windows, including OCL, OroGen, Typegen, and native OPC UA."
release_guide = strip_html_comments(File.read(File.join(source, "release-guide.md")))
prefix_channel_setup = level_two_section(release_guide, "## Prefix Channel Setup")
channel_quotes = if prefix_channel_setup
                   prefix_channel_setup.scan(/(?:^> .*$\n?)+/).map do |quote|
                     quote.lines.map { |line| line.delete_prefix("> ").strip }.join(" ")
                   end
                 else
                   []
                 end
unless channel_quotes.include?(channel_description)
  errors << "release guide is missing the canonical Prefix channel description"
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "Documentation structure and links are valid."
