#!/usr/bin/env ruby

require "optparse"
require "pty"
require "timeout"

options = {}
OptionParser.new do |parser|
  parser.on("--client PATH") { |value| options[:client] = value }
  parser.on("--endpoint URL") { |value| options[:endpoint] = value }
  parser.on("--component NAME") { |value| options[:component] = value }
  parser.on("--self-check") { options[:self_check] = true }
end.parse!

ANSI_ESCAPE = /\e\[[0-?]*[ -\/]*[@-~]/
SESSION_TIMEOUT = 30
TERMINATION_TIMEOUT = 2

def scalar_result_pattern(value, require_zero_decimal:)
  suffix = require_zero_decimal ? "\\.0+" : ""
  /^[ \t]*=[ \t]*#{Regexp.escape(value.to_s)}#{suffix}[ \t]*$/
end

def verify_scalar_result_patterns
  float_pattern = scalar_result_pattern(10, require_zero_decimal: true)
  persisted_pattern = scalar_result_pattern(101, require_zero_decimal: true)
  integer_pattern = scalar_result_pattern(30, require_zero_decimal: false)

  valid = [
    [float_pattern, " = 10.0"],
    [float_pattern, " = 10.000   "],
    [integer_pattern, " = 30"]
  ]
  invalid = [
    [float_pattern, " = 10"],
    [float_pattern, " = 10.5"],
    [float_pattern, " = 10e0"],
    [float_pattern, " = 10value"],
    [persisted_pattern, " = 101.9"],
    [integer_pattern, " = 30.25"]
  ]

  abort("scalar result pattern rejected an exact value") unless
    valid.all? { |pattern, text| pattern.match?(text) }
  abort("scalar result pattern accepted a numeric suffix") if
    invalid.any? { |pattern, text| pattern.match?(text) }

  puts "ctaskbrowser scalar result pattern self-check passed"
end

if options[:self_check]
  verify_scalar_result_patterns
  exit 0
end

%i[client endpoint component].each do |key|
  abort("missing --#{key.to_s.tr('_', '-')}") unless options[key]
end

def normalize_transcript(transcript)
  transcript.gsub(ANSI_ESCAPE, "").delete("\r")
end

def terminate_child(pid)
  return unless pid

  begin
    Process.kill("TERM", pid)
  rescue Errno::ESRCH
  end

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
             TERMINATION_TIMEOUT
  loop do
    begin
      waited_pid, = Process.waitpid2(pid, Process::WNOHANG)
      return if waited_pid
    rescue Errno::ECHILD
      return
    end
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.05
  end

  begin
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
  end
  begin
    Process.wait(pid)
  rescue Errno::ECHILD
  end
end

def run_session(options, commands)
  transcript = +""
  child_pid = nil
  status = nil

  begin
    Timeout.timeout(SESSION_TIMEOUT) do
      PTY.spawn(
        { "TERM" => "dumb" },
        options.fetch(:client),
        "--import", "orocos_opcua_fixture",
        options.fetch(:endpoint), options.fetch(:component)
      ) do |reader, writer, pid|
        child_pid = pid
        writer.write(commands.join("\n") + "\n")
        writer.flush
        begin
          loop { transcript << reader.readpartial(4096) }
        rescue EOFError, Errno::EIO
        end
        _, status = Process.wait2(pid)
        child_pid = nil
      end
    end
  rescue Timeout::Error
    terminate_child(child_pid)
    child_pid = nil
    abort(
      "ctaskbrowser-opcua timed out after #{SESSION_TIMEOUT}s:\n" \
      "#{normalize_transcript(transcript)}"
    )
  rescue StandardError => error
    terminate_child(child_pid)
    child_pid = nil
    abort(
      "ctaskbrowser-opcua failed with #{error.class}: #{error.message}\n" \
      "#{normalize_transcript(transcript)}"
    )
  ensure
    terminate_child(child_pid)
  end

  transcript = normalize_transcript(transcript)
  abort("ctaskbrowser-opcua failed:\n#{transcript}") unless status&.success?
  transcript
end

def command_segments(transcript, component, commands)
  starts = []
  commands.each do |command|
    prompt = /^#{Regexp.escape(component)} \[[^\]\n]+\]> #{Regexp.escape(command)}$/
    match = transcript.match(prompt, starts.last&.fetch(1) || 0)
    abort("command not echoed as a prompt line: #{command}\n#{transcript}") unless match

    starts << [match.begin(0), match.end(0)]
  end

  commands.each_index.to_h do |index|
    finish = starts[index + 1]&.fetch(0) || transcript.length
    [commands[index], transcript[starts[index].fetch(1)...finish]]
  end
end

def expect_segment(segments, command, pattern, transcript)
  result = segments.fetch(command).strip
  return if result.match?(pattern)

  abort(
    "unexpected result for #{command}: expected #{pattern.inspect}\n" \
    "#{transcript}"
  )
end

first_commands = [
  "Float64ArrayAttribute",
  "Int32ArrayAttribute",
  "StringArrayAttribute",
  "PointAttribute",
  "EnvelopeAttribute",
  "EnvelopeConstant",
  "PointArrayAttribute",
  "PointAttribute.x",
  "EnvelopeAttribute.point.x",
  "EnvelopeAttribute.quality",
  "EnvelopeProperty.point.y",
  "PointArrayAttribute[0].x",
  "EnvelopeEcho(EnvelopeAttribute)",
  "EnvelopeAttribute.point.x = 101",
  "EnvelopeAttribute.quality = 102",
  "EnvelopeProperty.point.y = 103",
  "PointArrayAttribute[0].x = 201",
  "EnvelopeConstant.point.x = 999",
  "LargePointArrayAttribute",
  "EnvelopeConstant.point.x",
  "quit"
]

first_transcript = run_session(options, first_commands)
first = command_segments(
  first_transcript, options.fetch(:component), first_commands
)
expect_segment(first, "Float64ArrayAttribute",
               /\A[ \t]*=[ \t]*\[3\.75, 5\.0\][ \t]*\z/,
               first_transcript)
expect_segment(first, "Int32ArrayAttribute",
               /\A[ \t]*=[ \t]*\[30, 40\][ \t]*\z/,
               first_transcript)
expect_segment(first, "StringArrayAttribute",
               /\A[ \t]*=[ \t]*\[gamma, delta\][ \t]*\z/,
               first_transcript)
expect_segment(first, "PointAttribute",
               /^[ \t]*=[ \t]*\{x: 10\.0, y: 20\.0\}[ \t]*$/,
               first_transcript)
expect_segment(
  first, "EnvelopeAttribute",
  /^[ \t]*=[ \t]*\{point: \{x: 10\.0, y: 20\.0\}, quality: 30\}[ \t]*$/,
  first_transcript
)
expect_segment(
  first, "EnvelopeConstant",
  /^[ \t]*=[ \t]*\{point: \{x: 3\.0, y: 4\.0\}, quality: 5\}[ \t]*$/,
  first_transcript
)
expect_segment(
  first, "PointArrayAttribute",
  %r{\A[ \t]*=[ \t]*\[/orocos/fixture/Point\{x: 10\.0, y: 11\.0\}, /orocos/fixture/Point\{x: 12\.0, y: 13\.0\}\][ \t]*\z},
  first_transcript
)
expect_segment(first, "PointAttribute.x",
               scalar_result_pattern(10, require_zero_decimal: true),
               first_transcript)
expect_segment(first, "EnvelopeAttribute.point.x",
               scalar_result_pattern(10, require_zero_decimal: true),
               first_transcript)
expect_segment(first, "EnvelopeAttribute.quality",
               scalar_result_pattern(30, require_zero_decimal: false),
               first_transcript)
expect_segment(first, "EnvelopeProperty.point.y",
               scalar_result_pattern(20, require_zero_decimal: true),
               first_transcript)
expect_segment(first, "PointArrayAttribute[0].x",
               scalar_result_pattern(10, require_zero_decimal: true),
               first_transcript)
expect_segment(
  first, "EnvelopeEcho(EnvelopeAttribute)",
  /^[ \t]*=[ \t]*\{point: \{x: 10\.0, y: 20\.0\}, quality: 30\}[ \t]*$/,
  first_transcript
)
expect_segment(
  first, "EnvelopeConstant.point.x = 999",
  /Fatal Semantic error:.*Cannot assign constant/m, first_transcript
)
expect_segment(first, "EnvelopeConstant.point.x",
               scalar_result_pattern(3, require_zero_decimal: true),
               first_transcript)
expect_segment(
  first, "LargePointArrayAttribute",
  Regexp.new(
    "\\A[ \\t]*=[ \\t]*" \
    "\\[\\n  /orocos/fixture/Point\\{x: 1\\.0, y: 2\\.0\\},\\n  " \
    "/orocos/fixture/Point\\{x: 3\\.0, y: 4\\.0\\},\\n  " \
    "/orocos/fixture/Point\\{x: 5\\.0, y: 6\\.0\\},\\n  " \
    "\\.\\.\\. 997 items omitted\\n\\][ \\t]*\\z"
  ),
  first_transcript
)

second_commands = [
  "EnvelopeAttribute.point.x",
  "EnvelopeAttribute.quality",
  "EnvelopeProperty.point.y",
  "PointArrayAttribute[0].x",
  "EnvelopeConstant.point.x",
  "quit"
]

second_transcript = run_session(options, second_commands)
second = command_segments(
  second_transcript, options.fetch(:component), second_commands
)
expect_segment(second, "EnvelopeAttribute.point.x",
               scalar_result_pattern(101, require_zero_decimal: true),
               second_transcript)
expect_segment(second, "EnvelopeAttribute.quality",
               scalar_result_pattern(102, require_zero_decimal: false),
               second_transcript)
expect_segment(second, "EnvelopeProperty.point.y",
               scalar_result_pattern(103, require_zero_decimal: true),
               second_transcript)
expect_segment(second, "PointArrayAttribute[0].x",
               scalar_result_pattern(201, require_zero_decimal: true),
               second_transcript)
expect_segment(second, "EnvelopeConstant.point.x",
               scalar_result_pattern(3, require_zero_decimal: true),
               second_transcript)

puts "ctaskbrowser-opcua custom datatype acceptance passed"
