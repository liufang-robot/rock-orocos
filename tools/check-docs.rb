#!/usr/bin/env ruby

require "pathname"
require "set"

root = File.expand_path("..", __dir__)
docs = File.join(root, "docs")
source = File.join(docs, "src")
summary_path = File.join(source, "SUMMARY.md")
errors = []

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
  headings = contents.scan(/^# (.+)$/)
  errors << "#{relative} must contain exactly one level-one heading" unless headings.size == 1
  first_content = contents.lines.find { |line| !line.strip.empty? }
  errors << "#{relative} must start with its level-one heading" unless first_content&.start_with?("# ")

  contents.scan(/\]\(([^)]+)\)/).flatten.each do |target|
    local = target.split("#", 2).first
    next if local.empty? || local.match?(/\A[a-z][a-z0-9+.-]*:/i)
    next unless local.end_with?(".md")

    resolved = File.expand_path(local, File.dirname(page))
    errors << "#{relative}: missing local link #{local}" unless File.file?(resolved)
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

unless File.read(File.join(root, "README.md")).include?("https://liufang-robot.github.io/rock-orocos/")
  errors << "README.md must link to the published manual"
end
unless File.read(File.join(root, "packaging", "README.md")).include?("../docs/src/release-guide.md")
  errors << "packaging/README.md must point to the canonical release guide"
end

package_guide = File.read(File.join(source, "conda-packages.md"))
[
  "[target.unix.activation]",
  "[target.win.activation]",
  "examples/pixi-consumer",
  "pixi shell"
].each do |token|
  unless package_guide.include?(token)
    errors << "package guide is missing automatic activation token #{token}"
  end
end

channel_description =
  "Standalone Orocos RTT runtime and development toolchain for Linux and " \
  "Windows, including OCL, OroGen, Typegen, and native OPC UA."
release_guide = File.read(File.join(source, "release-guide.md"))
channel_quotes = release_guide.scan(/(?:^> .*$\n?)+/).map do |quote|
  quote.lines.map { |line| line.delete_prefix("> ").strip }.join(" ")
end
unless channel_quotes.include?(channel_description)
  errors << "release guide is missing the canonical Prefix channel description"
end

unless errors.empty?
  warn errors.join("\n")
  exit 1
end

puts "Documentation structure and links are valid."
