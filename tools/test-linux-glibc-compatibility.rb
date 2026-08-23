#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

root = File.expand_path("..", __dir__)
checker = File.join(root, "tools", "check-linux-glibc-compatibility.rb")

Dir.mktmpdir("orocos-glibc-compatibility.") do |directory|
  prefix = File.join(directory, "toolchain")
  FileUtils.mkdir_p(prefix)
  compatible = File.join(prefix, "compatible.so")
  incompatible = File.join(prefix, "incompatible.so")
  File.binwrite(compatible, "\x7FELFfixture")

  readelf = File.join(directory, "readelf")
  File.write(readelf, <<~'SH')
    #!/bin/sh
    case "$3" in
      */compatible.so) printf '%s\n' 'Name: GLIBC_2.17' ;;
      */incompatible.so) printf '%s\n' 'Name: GLIBC_2.38' ;;
      *) exit 2 ;;
    esac
  SH
  FileUtils.chmod(0o755, readelf)

  command = [
    RbConfig.ruby, checker,
    "--prefix", prefix,
    "--maximum-version", "2.17",
    "--readelf", readelf
  ]
  output, status = Open3.capture2e(*command)
  raise "compatible ELF was rejected: #{output}" unless status.success?

  File.binwrite(incompatible, "\x7FELFfixture")
  output, status = Open3.capture2e(*command)
  raise "incompatible ELF was accepted" if status.success?
  unless output.include?("incompatible.so: requires GLIBC_2.38")
    raise "incompatible ELF failure was not diagnostic: #{output}"
  end
end

puts "Linux GLIBC compatibility regression checks passed."
