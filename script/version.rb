#!/usr/bin/env ruby
# Shared version data; never evaluates the tracked file as code.
require 'json'

module BBCVersion
  def self.read(root)
    value = JSON.parse(File.read(File.join(root, 'VERSION')))
    unless value.is_a?(Hash) && value.keys.sort == %w[build version] &&
           value['version'].is_a?(String) && value['version'].match?(/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/) &&
           value['build'].is_a?(Integer) && value['build'].between?(1, 2_147_483_647)
      raise ArgumentError, 'VERSION must contain a three-part version and a positive integer build'
    end
    value
  rescue JSON::ParserError, Errno::ENOENT => error
    raise ArgumentError, "Invalid VERSION: #{error.class}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    data = BBCVersion.read(File.expand_path('..', __dir__))
    field = ARGV.fetch(0)
    abort 'Usage: version.rb version|build' unless %w[version build].include?(field) && ARGV.length == 1
    puts data.fetch(field)
  rescue ArgumentError, IndexError => error
    abort error.message
  end
end
