#!/usr/bin/env ruby
# Secret-free validation used before credential access and again before draft upload.
require 'digest'
require 'json'
require 'open3'
require 'pathname'
require_relative 'release'

module BBCReleaseCI
  REPOSITORY = 'lucasilverentand/BBC'.freeze
  TAG = /\Av(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/
  SHA = /\A[0-9a-f]{40}\z/

  def self.capture(*command)
    out, err, status = Open3.capture3(*command)
    raise BBCRelease::Failure, "#{File.basename(command.first)} validation failed" unless status.success?
    out.strip
  end

  def self.tag!(tag)
    raise BBCRelease::Failure, 'Expected an existing vX.Y.Z release tag' unless tag.is_a?(String) && tag.match?(TAG)
    tag
  end

  def self.sha!(sha)
    raise BBCRelease::Failure, 'Expected a full source commit SHA' unless sha.is_a?(String) && sha.match?(SHA)
    sha
  end

  def self.context!(environment)
    unless environment['GITHUB_REPOSITORY'] == REPOSITORY && environment['GITHUB_REF'] == 'refs/heads/main' && environment['GITHUB_EVENT_NAME'] == 'workflow_dispatch'
      raise BBCRelease::Failure, 'Releases can only be dispatched from this repository main branch'
    end
    sha!(environment.fetch('GITHUB_SHA'))
  end

  def self.verify_source(root, tag, trusted_main, expected = nil, checkout: false)
    tag!(tag); sha!(trusted_main)
    commit = capture('git', '-C', root, 'rev-parse', '--verify', "refs/tags/#{tag}^{commit}")
    sha!(commit)
    capture('git', '-C', root, 'merge-base', '--is-ancestor', commit, trusted_main)
    raise BBCRelease::Failure, 'Verified tag changed between release jobs' if expected && commit != sha!(expected)
    head = capture('git', '-C', root, 'rev-parse', 'HEAD')
    raise BBCRelease::Failure, 'Unexpected checked-out source' unless head == (checkout ? commit : trusted_main)
    version = JSON.parse(capture('git', '-C', root, 'show', "#{commit}:VERSION"))
    unless version.is_a?(Hash) && version.keys.sort == %w[build version] && version['version'] == tag.delete_prefix('v') && version['build'].is_a?(Integer) && version['build'] > 0
      raise BBCRelease::Failure, 'Release VERSION does not match the tag'
    end
    capture('git', '-C', root, 'cat-file', '-e', "#{commit}:docs/releases/#{tag}.md")
    raise BBCRelease::Failure, 'Release source is dirty' unless capture('git', '-C', root, 'status', '--porcelain', '--untracked-files=all').empty?
    commit
  end

  def self.validate_artifacts(directory, tag, expected_commit)
    tag!(tag); sha!(expected_commit)
    directory = File.realpath(directory)
    archive = "BlueBubbleClub-#{tag.delete_prefix('v')}-macos-arm64.zip"
    expected = [archive, 'manifest.json', 'SHA256SUMS'].sort
    raise BBCRelease::Failure, 'Unexpected release artifact files' unless Dir.children(directory).sort == expected
    expected.each do |name|
      path = File.join(directory, name)
      unless File.file?(path) && !File.symlink?(path) && File.realpath(path).start_with?(directory + '/')
        raise BBCRelease::Failure, 'Release artifact must be a regular file'
      end
    end
    manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
    unless manifest['version'] == tag.delete_prefix('v') && manifest['tag'] == tag && manifest['commit'] == expected_commit && manifest['architecture'] == 'arm64' && manifest['archive'] == archive && manifest['notarized'] == true && manifest['build'].is_a?(Integer) && manifest['build'] > 0
      raise BBCRelease::Failure, 'Release manifest does not match verified source and notarization'
    end
    checksums = File.readlines(File.join(directory, 'SHA256SUMS'), chomp: true)
    raise BBCRelease::Failure, 'Expected checksums for archive and manifest only' unless checksums.length == 2
    seen = []
    checksums.each do |line|
      match = line.match(/\A([0-9a-f]{64})  (.+)\z/)
      raise BBCRelease::Failure, 'Malformed release checksum' unless match && [archive, 'manifest.json'].include?(match[2]) && !seen.include?(match[2])
      raise BBCRelease::Failure, 'Release checksum mismatch' unless Digest::SHA256.file(File.join(directory, match[2])).hexdigest == match[1]
      seen << match[2]
    end
    entries = capture('/usr/bin/unzip', '-Z1', File.join(directory, archive)).lines.map(&:chomp)
    raise BBCRelease::Failure, 'Release archive is empty' if entries.empty?
    entries.each do |entry|
      parts = entry.split('/')
      if entry.start_with?('/') || entry.include?('\\') || parts.include?('..') || !["Blue Bubble Club.app/", '__MACOSX/'].any? { |prefix| entry.start_with?(prefix) }
        raise BBCRelease::Failure, 'Unsafe or unexpected path in release archive'
      end
    end
    archive
  end

  def self.draft(root, directory, tag, commit)
    archive = validate_artifacts(directory, tag, commit)
    BBCRelease.remote_tag!(tag, commit)
    notes = capture('git', '-C', root, 'show', "#{commit}:docs/releases/#{tag}.md")
    notes_path = File.join(ENV.fetch('RUNNER_TEMP'), 'bbc-reviewed-release-notes.md')
    File.write(notes_path, notes + "\n")
    BBCRelease.run('gh', 'release', 'create', tag, '--repo', REPOSITORY, '--verify-tag', '--draft', '--title', "Blue Bubble Club #{tag.delete_prefix('v')}", '--notes-file', notes_path,
                   File.join(directory, archive), File.join(directory, 'manifest.json'), File.join(directory, 'SHA256SUMS'))
  ensure
    File.delete(notes_path) if notes_path && File.file?(notes_path)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    root = ENV.fetch('BBC_RELEASE_SOURCE_ROOT') { File.expand_path('..', __dir__) }
    trusted_main = BBCReleaseCI.context!(ENV)
    tag = ENV.fetch('BBC_RELEASE_TAG')
    case command
    when 'verify'
      commit = BBCReleaseCI.verify_source(root, tag, trusted_main)
      File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') { |output| output.puts("commit=#{commit}") }
      puts 'Release tag and reviewed main ancestry verified.'
    when 'checkout'
      BBCReleaseCI.verify_source(root, tag, trusted_main, ENV.fetch('BBC_RELEASE_COMMIT'), checkout: true)
      puts 'Checked-out release source verified.'
    when 'artifacts'
      BBCReleaseCI.validate_artifacts(ENV.fetch('BBC_RELEASE_ARTIFACTS'), tag, ENV.fetch('BBC_RELEASE_COMMIT'))
      puts 'Release files, provenance, checksums and archive paths verified.'
    when 'draft'
      BBCReleaseCI.draft(root, ENV.fetch('BBC_RELEASE_ARTIFACTS'), tag, ENV.fetch('BBC_RELEASE_COMMIT'))
    else
      raise BBCRelease::Failure, 'Usage: ci_release.rb verify|checkout|artifacts|draft'
    end
  rescue BBCRelease::Failure, KeyError, JSON::ParserError, Errno::ENOENT => error
    warn "CI release stopped: #{error.message}"
    exit 1
  end
end
