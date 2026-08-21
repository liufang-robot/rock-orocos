#!/usr/bin/env ruby

require "json"
require "open3"
require "rbconfig"
require "tempfile"

ROOT = File.expand_path("..", __dir__)
SOURCE_LOCK = File.join(ROOT, "packaging", "source-lock.json")
VALIDATOR = File.join(ROOT, "tools", "linux-source-lock.rb")

def run_validation(lock_path)
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby, VALIDATOR, "validate", lock_path, ROOT
  )
  ["#{stdout}#{stderr}", status]
end

output, status = run_validation(SOURCE_LOCK)
raise "canonical source lock failed validation: #{output}" unless status.success?
unless output.include?("Validated 14 locked Linux build sources.")
  raise "canonical source lock reported an unexpected source count: #{output.inspect}"
end

mutations = {
  "farbot" => "https://example.invalid/farbot.git",
  "rock-package-set" => "",
  "vcpkg" => "https://example.invalid/vcpkg.git"
}
accepted = []

mutations.each do |name, repository|
  document = JSON.parse(File.read(SOURCE_LOCK))
  source = document.fetch("sources").find { |entry| entry.fetch("name") == name }
  raise "canonical source lock is missing #{name}" unless source

  source["repository"] = repository
  Tempfile.create(["source-lock-#{name}", ".json"]) do |file|
    file.write(JSON.generate(document))
    file.flush
    mutation_output, mutation_status = run_validation(file.path)
    if mutation_status.success?
      accepted << "source lock accepted noncanonical repository for #{name}"
    elsif !mutation_output.include?(name)
      accepted << "source lock rejection did not name #{name}: #{mutation_output.inspect}"
    end
  end
end

raise accepted.join("\n") unless accepted.empty?

puts "Linux source lock repository tests passed."
