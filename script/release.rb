#!/usr/bin/env ruby
# Distribution is a separate, opt-in lane. It never reads LocalSigning.env.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'tmpdir'
require 'time'
require_relative 'version'

module BBCRelease
  class Failure < StandardError; end
  REPOSITORY = 'lucasilverentand/BBC'.freeze
  APP_NAME = 'Blue Bubble Club.app'.freeze
  MACHO_MAGICS = %w[feedface cefaedfe feedfacf cffaedfe cafebabe bebafeca cafebabf bfbafeca].freeze

  def self.capture(*command, env: {}, sensitive: false, input: nil)
    output, error, status = Open3.capture3(env, *command, stdin_data: input || '')
    unless status.success?
      detail = sensitive ? ' (credential or signing validation failed; no credentials were logged)' : "\n#{error.lines.last(8).join}"
      raise Failure, "#{File.basename(command.first)} failed#{detail}"
    end
    output.strip
  end

  def self.run(*command, env: {})
    puts "Running #{File.basename(command.first)}"
    raise Failure, "#{File.basename(command.first)} failed" unless system(env, *command)
  end

  def self.source(root, version, tag)
    raise Failure, 'Tag must match VERSION exactly' unless tag == "v#{version.fetch('version')}"
    raise Failure, 'Release requires a clean tracked and untracked worktree' unless capture('git', '-C', root, 'status', '--porcelain', '--untracked-files=all').empty?
    head = capture('git', '-C', root, 'rev-parse', 'HEAD')
    tagged = capture('git', '-C', root, 'rev-parse', '--verify', "refs/tags/#{tag}^{commit}")
    raise Failure, 'HEAD must equal the release tag' unless head == tagged
    capture('git', '-C', root, 'merge-base', '--is-ancestor', head, 'refs/remotes/origin/main')
    head
  end

  def self.identity(selection)
    raise Failure, 'Set BBC_RELEASE_SIGNING_IDENTITY to a Developer ID Application identity' if selection.to_s.empty?
    available = capture('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', sensitive: true)
    matches = available.lines.map do |line|
      fields = line.match(/^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"/)
      next unless fields && (fields[1].casecmp(selection).zero? || fields[2] == selection)
      fields
    end.compact
    unless matches.length == 1 && matches[0][2].start_with?('Developer ID Application: ')
      raise Failure, 'Release signing must resolve to exactly one Developer ID Application identity; development/ad-hoc signing is refused'
    end
    matches[0][1]
  end

  def self.remote_tag!(tag, expected)
    value = JSON.parse(capture('gh', 'api', "repos/#{REPOSITORY}/git/ref/tags/#{tag}"))
    object = value.fetch('object')
    4.times do
      break unless object['type'] == 'tag'
      sha = object.fetch('sha')
      raise Failure, 'Invalid remote annotated tag' unless sha.match?(/\A[0-9a-f]{40}\z/)
      object = JSON.parse(capture('gh', 'api', "repos/#{REPOSITORY}/git/tags/#{sha}")).fetch('object')
    end
    unless object['type'] == 'commit' && object['sha'] == expected
      raise Failure, 'GitHub release tag does not match the verified source commit'
    end
  end

  def self.machos(app)
    Dir.glob(File.join(app, '**', '*')).select do |path|
      next false unless File.file?(path)
      MACHO_MAGICS.include?(File.binread(path, 4).unpack1('H*'))
    end
  end

  def self.portable_dependencies!(app)
    executable = File.join(app, 'Contents', 'MacOS', 'BlueBubbleClub')
    machos(app).each do |path|
      dependencies = capture('/usr/bin/otool', '-L', path).lines.map do |line|
        match = line.match(/^\s+(\S+)\s+\(compatibility version /)
        match && match[1]
      end.compact
      dependencies.each do |dependency|
        next if dependency.start_with?('/System/Library/', '/usr/lib/')
        if dependency.start_with?('@executable_path/', '@loader_path/')
          base = dependency.start_with?('@loader_path/') ? File.dirname(path) : File.dirname(executable)
          resolved = File.expand_path(dependency.sub(/\A@(?:executable|loader)_path\//, ''), base)
          next if resolved.start_with?(app + '/') && File.file?(resolved) && File.realpath(resolved).start_with?(app + '/')
        end
        if dependency.start_with?('@rpath/')
          embedded = File.join(app, 'Contents', 'Frameworks', dependency.delete_prefix('@rpath/'))
          next if File.file?(embedded) && File.realpath(embedded).start_with?(app + '/')
        end
        # OS Swift runtime dependencies resolve from /usr/lib/swift. Other
        # @rpath imports need an explicit embedding/rpath review before release.
        if dependency.match?(%r{\A@rpath/libswift[^/]+\.dylib\z})
          sdk = capture('xcrun', '--sdk', 'macosx', '--show-sdk-path')
          next if File.file?(File.join(sdk, 'usr', 'lib', 'swift', File.basename(dependency, '.dylib') + '.tbd'))
        end
        raise Failure, "Nonportable or unresolved dependency in #{File.basename(path)}: #{dependency}"
      end
    end
  end

  def self.sign!(app, signing_identity, entitlements)
    sign = ['/usr/bin/codesign', '--force', '--sign', signing_identity, '--options', 'runtime', '--timestamp']
    # Mach-O leaves, then nested resource bundles, then the enclosing app.
    machos(app).sort_by { |path| -path.count('/') }.each { |path| run(*sign, path) }
    Dir.glob(File.join(app, 'Contents', 'Resources', '*.bundle')).each { |path| run(*sign, path) }
    run(*sign, '--entitlements', entitlements, app)
    machos(app).each do |path|
      run('/usr/bin/codesign', '--verify', '--strict', path)
      xml = capture('/usr/bin/codesign', '-d', '--entitlements', ':-', path, sensitive: true)
      next if xml.empty?
      entitlements = JSON.parse(capture('/usr/bin/plutil', '-convert', 'json', '-o', '-', '-', input: xml))
      raise Failure, 'get-task-allow entitlement is forbidden in a release' if entitlements.key?('com.apple.security.get-task-allow')
    end
    run('/usr/bin/codesign', '--verify', '--strict', app)
  end

  def self.package!(root, working, version, commit)
    env = {'BBC_CONFIG' => 'release', 'BBC_ARCH' => 'arm64', 'BBC_SYSTEM_SQLITE' => '1'}
    # Avoid inheriting a local Homebrew sqlite.pc that links its private dylib.
    pkgconfig = File.join(working, 'pkgconfig')
    FileUtils.mkdir_p(pkgconfig)
    env['PKG_CONFIG_PATH'] = pkgconfig
    env['PKG_CONFIG_LIBDIR'] = pkgconfig
    run('/bin/bash', File.join(root, 'script', 'prepare_native.sh'), env: env)
    run('/bin/bash', File.join(root, 'script', 'prepare_bridge.sh'))
    run('/bin/bash', File.join(root, 'script', 'prepare_icon.sh'))
    binary = capture('swift', 'build', '--package-path', File.join(root, 'NativeMessages'), '-c', 'release', '--arch', 'arm64', '--show-bin-path', env: env)
    app = File.join(working, APP_NAME)
    resources = File.join(app, 'Contents', 'Resources')
    frameworks = File.join(app, 'Contents', 'Frameworks')
    executables = File.join(app, 'Contents', 'MacOS')
    [resources, frameworks, executables].each { |directory| FileUtils.mkdir_p(directory) }
    FileUtils.cp(File.join(binary, 'BlueBubbleClub'), executables)
    run('/usr/bin/lipo', '-verify_arch', 'arm64', File.join(executables, 'BlueBubbleClub'))
    architectures = capture('/usr/bin/lipo', '-archs', File.join(executables, 'BlueBubbleClub'))
    raise Failure, 'Expected an arm64-only application executable' unless architectures == 'arm64'
    %w[BBCMessagesActions_BBCMessagesActions FluidAudio_FluidAudio].each do |bundle|
      origin = File.join(binary, bundle + '.bundle')
      raise Failure, "Missing resource bundle #{bundle}" unless File.directory?(origin)
      FileUtils.cp_r(origin, resources)
    end
    %w[LICENSE NOTICE LICENSES].each { |name| FileUtils.cp_r(File.join(root, name), resources) }
    %w[AppIcon.icns Assets.car].each { |name| FileUtils.cp(File.join(root, 'build', 'AppIcon', name), resources) }
    FileUtils.cp(File.join(root, 'build', 'NativeBridge', 'BBCMessagesBridge.dylib'), frameworks)
    # Keep build-machine paths out of the distribution dylib's identity.
    run('/usr/bin/install_name_tool', '-id', '@rpath/BBCMessagesBridge.dylib', File.join(frameworks, 'BBCMessagesBridge.dylib'))
    plist = File.join(app, 'Contents', 'Info.plist')
    File.write(plist, <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>BlueBubbleClub</string>
      <key>CFBundleIdentifier</key><string>club.bluebubble.app</string>
      <key>CFBundleName</key><string>Blue Bubble Club</string>
      <key>CFBundleIconFile</key><string>AppIcon</string>
      <key>CFBundleIconName</key><string>AppIcon</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>#{version.fetch('version')}</string>
      <key>CFBundleVersion</key><string>#{version.fetch('build')}</string>
      <key>BBCSourceCommit</key><string>#{commit}</string>
      <key>LSMinimumSystemVersion</key><string>26.0</string>
      <key>NSPrincipalClass</key><string>NSApplication</string>
      <key>LSUIElement</key><true/>
      <key>NSAppleEventsUsageDescription</key><string>Blue Bubble Club sends messages through your local Messages account when an authorized API client requests it.</string>
      </dict></plist>
    XML
    portable_dependencies!(app)
    app
  end

  def self.release_platform!
    raise Failure, 'Release packaging requires macOS on Apple Silicon' unless RUBY_PLATFORM.include?('darwin') && capture('/usr/bin/uname', '-m') == 'arm64'
  end

  def self.release(root, options, environment = ENV)
    version = BBCVersion.read(root)
    tag = options[:tag] || "v#{version.fetch('version')}"
    commit = source(root, version, tag)
    if options[:draft]
      notes = File.join(root, 'docs', 'releases', "#{tag}.md")
      raise Failure, "Add release notes at docs/releases/#{tag}.md before creating a draft" unless File.file?(notes)
      remote_tag!(tag, commit)
    end
    release_platform!
    signing_identity = identity(environment['BBC_RELEASE_SIGNING_IDENTITY'])
    profile = environment['BBC_NOTARY_PROFILE']
    raise Failure, 'Set BBC_NOTARY_PROFILE to a configured notarytool keychain profile' if profile.to_s.empty?
    notary_keychain = environment['BBC_NOTARY_KEYCHAIN']
    keychain_arguments = notary_keychain.to_s.empty? ? [] : ['--keychain', notary_keychain]
    capture('xcrun', 'notarytool', 'history', '--keychain-profile', profile, *keychain_arguments, '--output-format', 'json', sensitive: true)
    # Expose no identity/profile values in prerequisite output.
    puts "Release prerequisites passed for #{tag} (arm64)."
    return if options[:check]
    output_root = File.join(root, 'build', 'release')
    final = File.join(output_root, tag)
    raise Failure, 'Release output already exists; refusing to overwrite artifacts' if File.exist?(final)
    FileUtils.mkdir_p(output_root)
    Dir.mktmpdir('.release-', output_root) do |working|
      app = package!(root, working, version, commit)
      sign!(app, signing_identity, File.join(root, 'Config', 'BBCMessagesActions.entitlements'))
      submission = File.join(working, 'notarization.zip')
      run('/usr/bin/ditto', '-c', '-k', '--keepParent', app, submission)
      notarization = JSON.parse(capture('xcrun', 'notarytool', 'submit', submission, '--keychain-profile', profile, *keychain_arguments, '--wait', '--timeout', '30m', '--output-format', 'json', sensitive: true))
      raise Failure, 'Apple did not accept this notarization submission; no release artifacts were produced' unless notarization['status'] == 'Accepted' && notarization['id'].is_a?(String) && notarization['id'].match?(/\A[0-9a-fA-F-]{36}\z/)
      run('xcrun', 'stapler', 'staple', app)
      run('xcrun', 'stapler', 'validate', app)
      run('/usr/bin/codesign', '--verify', '--strict', app)
      run('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', app)
      # Require Developer ID in the actual artifact too, not merely its input selection.
      # codesign emits display metadata on stderr, so inspect it separately.
      _, metadata, status = Open3.capture3('/usr/bin/codesign', '-d', '--verbose=4', app)
      raise Failure, 'Cannot inspect release signature' unless status.success?
      raise Failure, 'Artifact is not Developer ID signed' unless metadata.lines.any? { |line| line.start_with?('Authority=Developer ID Application: ') }
      team = metadata[/^TeamIdentifier=(.+)$/, 1]
      raise Failure, 'Missing signer Team ID' if team.to_s.empty? || team == 'not set'
      artifacts = File.join(working, 'artifacts')
      FileUtils.mkdir_p(artifacts)
      filename = "BlueBubbleClub-#{version.fetch('version')}-macos-arm64.zip"
      archive = File.join(artifacts, filename)
      run('/usr/bin/ditto', '-c', '-k', '--keepParent', app, archive)
      manifest = {
        'version' => version.fetch('version'), 'build' => version.fetch('build'), 'tag' => tag,
        'commit' => commit, 'architecture' => 'arm64', 'minimum_macos' => '26.0',
        'xcode' => capture('xcodebuild', '-version'), 'sdk' => capture('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
        'signer_team_id' => team, 'notary_submission_id' => notarization.fetch('id'),
        'notarized' => true, 'archive' => filename, 'created_at' => Time.now.utc.iso8601
      }
      if environment['GITHUB_ACTIONS'] == 'true'
        manifest['runner_image'] = {'os' => environment.fetch('ImageOS'), 'version' => environment.fetch('ImageVersion')}
      end
      File.write(File.join(artifacts, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")
      sums = [filename, 'manifest.json'].map { |name| "#{Digest::SHA256.file(File.join(artifacts, name)).hexdigest}  #{name}\n" }.join
      File.write(File.join(artifacts, 'SHA256SUMS'), sums)
      # Do not claim clean provenance if any tracked input changed while building.
      raise Failure, 'Source changed during release; discarding artifacts' unless source(root, version, tag) == commit
      File.rename(artifacts, final)
    end
    puts "Verified notarized artifacts: #{final}"
    return unless options[:draft]
    remote_tag!(tag, commit)
    # --verify-tag prevents gh from creating an unreviewed source tag implicitly.
    run('gh', 'release', 'create', tag, '--repo', REPOSITORY, '--verify-tag', '--draft', '--title', "Blue Bubble Club #{version.fetch('version')}", '--notes-file', notes,
        *Dir.glob(File.join(final, '*')).sort)
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |args|
    args.banner = 'Usage: script/release.rb [--check] [--tag vX.Y.Z] [--draft]'
    args.on('--check', 'Validate source, distribution identity and notary credentials only') { options[:check] = true }
    args.on('--tag TAG', 'Existing source tag (defaults to VERSION)') { |value| options[:tag] = value }
    args.on('--draft', 'Upload verified artifacts as a GitHub draft release') { options[:draft] = true }
    args.on('--notarize', 'Normal release path (always enabled; there is no preview fallback)') {}
    args.on('-h', '--help') { puts args; exit }
  end
  begin
    parser.parse!
    raise BBCRelease::Failure, 'Unexpected arguments' unless ARGV.empty?
    BBCRelease.release(File.expand_path('..', __dir__), options)
  rescue BBCRelease::Failure, ArgumentError, JSON::ParserError, Errno::ENOENT, OptionParser::ParseError => error
    warn "Release stopped: #{error.message}"
    exit 1
  end
end
