#!/usr/bin/env ruby
require_relative 'release'

module BBCReleaseToolchain
  # These exact compiler builds are reviewed; a floating runner update must stop.
  REVIEWED = {
    '27B48' => ['/Applications/Xcode_27.2_Release_Candidate.app/Contents/Developer'],
    '27B52' => ['/Applications/Xcode_27.2.app/Contents/Developer', '/Applications/Xcode.app/Contents/Developer']
  }.freeze

  def self.validate!(version, real_directory, environment)
    build = version[/\AXcode 27\.2\nBuild version (\S+)\z/, 1]
    unless build && REVIEWED.fetch(build, []).include?(real_directory)
      raise BBCRelease::Failure, 'Select a reviewed Xcode 27.2 build and installation path; release stopped before credentials'
    end
    image = {'os' => environment['ImageOS'], 'version' => environment['ImageVersion']}
    if environment['GITHUB_ACTIONS'] == 'true' && image.values.any? { |value| value.to_s.empty? }
      raise BBCRelease::Failure, 'Hosted runner image provenance is missing'
    end
    {'xcode_build' => build, 'developer_directory' => real_directory, 'runner_image' => image}
  end

  def self.verify!(environment = ENV)
    directory = File.realpath(environment.fetch('DEVELOPER_DIR'))
    validate!(BBCRelease.capture('xcodebuild', '-version'), directory, environment)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.pretty_generate(BBCReleaseToolchain.verify!)
  rescue BBCRelease::Failure, KeyError, Errno::ENOENT => error
    warn "Toolchain check failed: #{error.message}"
    exit 1
  end
end
