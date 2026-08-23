#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

root = File.expand_path("..", __dir__)
sanitizer = File.join(root, "packaging", "conda", "sanitize-linux-prefix.rb")

Dir.mktmpdir("orocos-prefix-sanitizer.") do |directory|
  prefix = File.join(directory, "host-prefix")
  build_prefix = File.join(directory, "build-prefix")
  temporary_home = File.join(directory, "temporary-home")
  toolchain = File.join(prefix, "toolchain")
  sysroot = File.join(build_prefix, "x86_64-conda-linux-gnu", "sysroot")
  [toolchain, File.join(sysroot, "usr", "include"),
   File.join(sysroot, "usr", "lib"), temporary_home].each do |path|
    FileUtils.mkdir_p(path)
  end

  File.write(File.join(prefix, "env.sh"), "OROCOS_PREFIX=#{prefix}\n")
  File.write(File.join(prefix, "dev-env.sh"), ". #{prefix}/env.sh\n")
  File.write(
    File.join(toolchain, "metadata.txt"),
    "-I#{sysroot}/usr/include -L#{sysroot}/usr/lib " \
      "#{sysroot}/usr/lib/libpthread.a #{sysroot}/usr/lib/libpthread.so\n"
  )
  File.write(
    File.join(toolchain, "catalog.xml"),
    "<system uri=\"file://#{root}/build/doc/xml/orocos.ent\" />\n"
  )
  File.write(
    File.join(toolchain, "ruby-wrapper"),
    "#!#{build_prefix}/bin/ruby\nputs :ok\n"
  )
  dependency_file = File.join(prefix, "include", "dependency.h")
  FileUtils.mkdir_p(File.dirname(dependency_file))
  File.write(dependency_file, "/* dependency metadata: #{root} */\n")

  command = [
    RbConfig.ruby, sanitizer,
    "--prefix", prefix,
    "--build-prefix", build_prefix,
    "--repository-root", root,
    "--temporary-home", temporary_home
  ]
  output, status = Open3.capture2e(*command)
  raise "sanitizer failed: #{output}" unless status.success?

  metadata = File.read(File.join(toolchain, "metadata.txt"))
  raise "compiler sysroot was retained" if metadata.include?(build_prefix)
  raise "pthread dependency was removed" unless metadata.include?("pthread")
  unless File.read(File.join(toolchain, "catalog.xml")).include?('uri="orocos.ent"')
    raise "installed XML catalog was not made relative"
  end
  unless File.read(File.join(toolchain, "ruby-wrapper")).start_with?("#!/usr/bin/env ruby\n")
    raise "Ruby wrapper shebang was not made relocatable"
  end

  File.write(File.join(toolchain, "leak.txt"), "source=#{root}/toolchain/tools/rtt\n")
  output, status = Open3.capture2e(*command)
  raise "sanitizer accepted a repository path leak" if status.success?
  raise "sanitizer failure was not diagnostic" unless output.include?("leak.txt")
end

puts "Linux prefix sanitizer regression checks passed."
