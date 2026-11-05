#!/usr/bin/env ruby
# This helper is only for fresh GitHub-hosted release VMs, never a developer Mac.
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'shellwords'
require 'tmpdir'
require_relative 'ci_release'
require_relative 'ci_release_toolchain'

module BBCReleaseSigning
  SECRET_NAMES = %w[BBC_DEVELOPER_ID_P12_BASE64 BBC_DEVELOPER_ID_P12_PASSWORD BBC_ASC_KEY_P8 BBC_ASC_KEY_ID BBC_ASC_ISSUER_ID].freeze

  def self.private_command(*command)
    out, _, state = Open3.capture3(*command)
    raise BBCRelease::Failure, "#{File.basename(command.first)} signing setup failed; credentials were not logged" unless state.success?
    out
  end

  def self.cleanup(directory)
    return if directory.to_s.empty? || !File.directory?(directory)
    runner_temp = File.realpath(ENV.fetch('RUNNER_TEMP'))
    real = File.realpath(directory)
    unless File.dirname(real) == runner_temp && File.basename(real).start_with?('bbc-release-signing-')
      raise BBCRelease::Failure, 'Refusing cleanup outside this job signing directory'
    end
    state_file = File.join(real, 'state.json')
    failures = []
    begin
      if File.file?(state_file)
        state = JSON.parse(File.read(state_file))
        # Restore every setting even if a preceding command fails.
        commands = []
        commands << ['/usr/bin/security', 'default-keychain', '-d', 'user', '-s', state.fetch('default')] if state['default']
        commands << ['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *state.fetch('search')]
        commands.each do |command|
          begin
            private_command(*command)
          rescue StandardError => error
            failures << error
          end
        end
      end
    rescue StandardError => error
      failures << error
    ensure
      keychain = File.join(real, 'signing.keychain-db')
      begin
        private_command('/usr/bin/security', 'delete-keychain', keychain) if File.exist?(keychain)
      rescue StandardError => error
        failures << error
      ensure
        FileUtils.remove_entry(real)
      end
    end
    raise BBCRelease::Failure, 'Signing cleanup encountered an error; the isolated job VM must be discarded' unless failures.empty?
  end

  def self.run(root)
    raise BBCRelease::Failure, 'Signing credentials may only be used on an ephemeral GitHub macOS job' unless ENV['GITHUB_ACTIONS'] == 'true' && ENV['RUNNER_OS'] == 'macOS'
    trusted_main = BBCReleaseCI.context!(ENV)
    tag = ENV.fetch('BBC_RELEASE_TAG')
    BBCReleaseCI.verify_source(root, tag, trusted_main, ENV.fetch('BBC_RELEASE_COMMIT'), checkout: true)
    raise BBCRelease::Failure, 'Release runner must be Apple Silicon' unless private_command('/usr/bin/uname', '-m').strip == 'arm64'
    BBCReleaseToolchain.verify!
    SECRET_NAMES.each { |name| raise BBCRelease::Failure, "Required protected environment secret #{name} is missing" if ENV[name].to_s.empty? }
    File.umask(0o077)
    directory = Dir.mktmpdir('bbc-release-signing-', ENV.fetch('RUNNER_TEMP'))
    File.open(ENV.fetch('GITHUB_ENV'), 'a') { |file| file.puts("BBC_RELEASE_STATE_DIR=#{directory}") }
    state = {
      'search' => Shellwords.split(private_command('/usr/bin/security', 'list-keychains', '-d', 'user')),
      'default' => Shellwords.split(private_command('/usr/bin/security', 'default-keychain', '-d', 'user')).first
    }
    File.write(File.join(directory, 'state.json'), JSON.generate(state))
    password = SecureRandom.hex(32)
    puts "::add-mask::#{password}"
    keychain = File.join(directory, 'signing.keychain-db')
    certificate = File.join(directory, 'certificate.p12')
    api_key = File.join(directory, 'notary-key.p8')
    File.binwrite(certificate, Base64.strict_decode64(ENV.fetch('BBC_DEVELOPER_ID_P12_BASE64').gsub(/\s+/, '')))
    File.write(api_key, ENV.fetch('BBC_ASC_KEY_P8'))
    private_command('/usr/bin/security', 'create-keychain', '-p', password, keychain)
    private_command('/usr/bin/security', 'set-keychain-settings', '-lut', '7200', keychain)
    private_command('/usr/bin/security', 'unlock-keychain', '-p', password, keychain)
    # Apple security import requires -P for headless operation. Values are never
    # printed, and the VM contains only this trusted job. Imported keys cannot export.
    private_command('/usr/bin/security', 'import', certificate, '-k', keychain, '-f', 'pkcs12', '-P', ENV.fetch('BBC_DEVELOPER_ID_P12_PASSWORD'), '-x', '-T', '/usr/bin/codesign')
    private_command('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain)
    private_command('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', keychain)
    private_command('/usr/bin/security', 'default-keychain', '-d', 'user', '-s', keychain)
    identities = private_command('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', keychain).lines.map do |line|
      match = line.match(/^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"Developer ID Application: [^"]+"/)
      match && match[1]
    end
    identities.compact!
    raise BBCRelease::Failure, 'The imported certificate must contain exactly one valid Developer ID Application identity' unless identities.length == 1
    profile = 'BBCReleaseNotary'
    private_command('xcrun', 'notarytool', 'store-credentials', profile, '--key', api_key, '--key-id', ENV.fetch('BBC_ASC_KEY_ID'), '--issuer', ENV.fetch('BBC_ASC_ISSUER_ID'), '--keychain', keychain, '--validate')
    SECRET_NAMES.each { |name| ENV.delete(name) }
    File.delete(certificate)
    File.delete(api_key)
    ENV['BBC_RELEASE_SIGNING_IDENTITY'] = identities.first
    ENV['BBC_NOTARY_PROFILE'] = profile
    ENV['BBC_NOTARY_KEYCHAIN'] = keychain
    BBCRelease.release(root, {tag: tag})
  ensure
    SECRET_NAMES.each { |name| ENV.delete(name) }
    cleanup(directory) if directory
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV == ['--cleanup']
      BBCReleaseSigning.cleanup(ENV['BBC_RELEASE_STATE_DIR'])
    elsif ARGV.empty?
      %w[INT TERM].each { |signal| Signal.trap(signal) { raise Interrupt, 'Release signing interrupted' } }
      BBCReleaseSigning.run(ENV.fetch('BBC_RELEASE_SOURCE_ROOT') { File.expand_path('..', __dir__) })
    else
      raise BBCRelease::Failure, 'Usage: ci_release_sign.rb [--cleanup]'
    end
  rescue BBCRelease::Failure, ArgumentError, KeyError, JSON::ParserError, Errno::ENOENT, Interrupt => error
    warn "CI signing stopped: #{error.message}"
    exit 1
  end
end
