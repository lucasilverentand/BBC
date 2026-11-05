#!/usr/bin/env ruby
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative 'release'

class ReleaseGuardTests < Minitest::Test
  def setup
    @root = Dir.mktmpdir('bbc-release-test-')
    git('init', '-q')
    git('config', 'user.name', 'Release fixture')
    git('config', 'user.email', 'release@example.test')
    File.write(File.join(@root, 'VERSION'), '{"version":"0.1.0","build":1}')
    git('add', 'VERSION')
    git('commit', '-qm', 'fixture')
    git('update-ref', 'refs/remotes/origin/main', 'HEAD')
    git('tag', 'v0.1.0')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(*arguments)
    BBCRelease.capture('git', '-C', @root, *arguments)
  end

  def test_clean_tagged_main_source_is_accepted
    assert_equal git('rev-parse', 'HEAD'), BBCRelease.source(@root, BBCVersion.read(@root), 'v0.1.0')
  end

  def test_untracked_or_modified_source_cannot_be_released
    File.write(File.join(@root, 'unexpected'), 'not reviewed')
    error = assert_raises(BBCRelease::Failure) { BBCRelease.source(@root, BBCVersion.read(@root), 'v0.1.0') }
    assert_match(/clean/, error.message)
    File.delete(File.join(@root, 'unexpected'))
    File.write(File.join(@root, 'VERSION'), '{"version":"0.1.0","build":2}')
    assert_raises(BBCRelease::Failure) { BBCRelease.source(@root, BBCVersion.read(@root), 'v0.1.0') }
  end

  def test_tag_and_version_must_match
    assert_raises(BBCRelease::Failure) { BBCRelease.source(@root, BBCVersion.read(@root), 'v0.2.0') }
  end

  def test_tag_must_point_to_head
    File.write(File.join(@root, 'new'), 'new')
    git('add', 'new'); git('commit', '-qm', 'new change')
    assert_raises(BBCRelease::Failure) { BBCRelease.source(@root, BBCVersion.read(@root), 'v0.1.0') }
  end

  def test_unmerged_tag_cannot_be_released
    File.write(File.join(@root, 'new'), 'new')
    git('add', 'new'); git('commit', '-qm', 'not merged')
    git('tag', '-f', 'v0.1.0')
    assert_raises(BBCRelease::Failure) { BBCRelease.source(@root, BBCVersion.read(@root), 'v0.1.0') }
  end

  def test_version_file_is_data_and_has_strict_fields
    ["BBC_VERSION=0.1.0", '{"version":"0.1.0","build":0}', '{"version":"0.1.0","build":"1"}',
     '{"version":"0.1","build":1}', '{"version":"0.1.0","build":1,"extra":true}'].each do |value|
      File.write(File.join(@root, 'VERSION'), value)
      assert_raises(ArgumentError) { BBCVersion.read(@root) }
    end
  end

  def test_distribution_identity_is_required_before_any_signing
    error = assert_raises(BBCRelease::Failure) { BBCRelease.identity(nil) }
    assert_match(/Developer ID Application/, error.message)
  end

  def test_development_identity_is_rejected
    BBCRelease.stub(:capture, "  1) #{'A' * 40} \"Apple Development: Fixture\"\n") do
      error = assert_raises(BBCRelease::Failure) { BBCRelease.identity('A' * 40) }
      assert_match(/development\/ad-hoc signing is refused/, error.message)
    end
  end

  def test_exact_developer_id_identity_is_selected
    BBCRelease.stub(:capture, "  1) #{'A' * 40} \"Developer ID Application: Fixture\"\n") do
      assert_equal 'A' * 40, BBCRelease.identity('A' * 40)
    end
  end

  def test_remote_release_tag_must_match_artifact_source
    response = JSON.generate('object' => {'type' => 'commit', 'sha' => 'a' * 40})
    BBCRelease.stub(:capture, response) do
      BBCRelease.remote_tag!('v0.1.0', 'a' * 40)
      assert_raises(BBCRelease::Failure) { BBCRelease.remote_tag!('v0.1.0', 'b' * 40) }
    end
  end

  def test_remote_annotated_tag_is_dereferenced
    values = [JSON.generate('object' => {'type' => 'tag', 'sha' => 'a' * 40}), JSON.generate('object' => {'type' => 'commit', 'sha' => 'b' * 40})]
    BBCRelease.stub(:capture, ->(*_arguments) { values.shift }) do
      BBCRelease.remote_tag!('v0.1.0', 'b' * 40)
    end
    assert_empty values
  end

  def test_homebrew_dependency_is_rejected_before_signing
    app = File.join(@root, 'Example.app')
    FileUtils.mkdir_p(File.join(app, 'Contents', 'MacOS'))
    path = File.join(app, 'Contents', 'MacOS', 'BlueBubbleClub')
    File.binwrite(path, ['feedfacf'].pack('H*'))
    BBCRelease.stub(:capture, "binary:\n\t/opt/homebrew/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 9.0.0)\n") do
      assert_raises(BBCRelease::Failure) { BBCRelease.portable_dependencies!(app) }
    end
  end

  def test_system_dependency_is_accepted
    app = File.join(@root, 'Example.app')
    FileUtils.mkdir_p(File.join(app, 'Contents', 'MacOS'))
    path = File.join(app, 'Contents', 'MacOS', 'BlueBubbleClub')
    File.binwrite(path, ['feedfacf'].pack('H*'))
    BBCRelease.stub(:capture, "binary:\n\t/usr/lib/libsqlite3.dylib (compatibility version 9.0.0, current version 9.0.0)\n") do
      BBCRelease.portable_dependencies!(app)
    end
  end

  def test_loader_relative_symlink_cannot_escape_the_app
    app = File.join(@root, 'Example.app')
    directory = File.join(app, 'Contents', 'MacOS')
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, 'BlueBubbleClub'), ['feedfacf'].pack('H*'))
    external = File.join(@root, 'external.dylib')
    File.binwrite(external, ['feedfacf'].pack('H*'))
    File.symlink(external, File.join(directory, 'linked.dylib'))
    output = "binary:\n\t@loader_path/linked.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
    BBCRelease.stub(:capture, output) do
      assert_raises(BBCRelease::Failure) { BBCRelease.portable_dependencies!(app) }
    end
  end

  def with_stubs(values, &block)
    return block.call if values.empty?
    receiver, method, replacement = values.first
    receiver.stub(method, replacement) { with_stubs(values.drop(1), &block) }
  end

  # This checks orchestration only. Apple signing and Gatekeeper are not simulated evidence.
  def simulated_notarization(status)
    calls = []
    commit = 'a' * 40
    notes = File.join(@root, 'docs', 'releases')
    FileUtils.mkdir_p(notes)
    File.write(File.join(notes, 'v0.1.0.md'), 'Fixture release notes')
    capture = lambda do |*command, **_options|
      calls << command
      case command[0, 3]
      when ['xcrun', 'notarytool', 'history'] then '{}'
      when ['xcrun', 'notarytool', 'submit']
        JSON.generate('status' => status, 'id' => '00000000-0000-4000-8000-000000000001')
      else
        case command.first
        when 'xcodebuild' then 'Xcode 27.2'
        when 'xcrun' then '27.2'
        else raise "Unexpected capture #{command.first}"
        end
      end
    end
    run = lambda do |*command, **_options|
      calls << command
      File.write(command.last, 'fixture archive bytes') if command.first == '/usr/bin/ditto'
    end
    package = lambda do |_root, working, *_arguments|
      app = File.join(working, BBCRelease::APP_NAME)
      FileUtils.mkdir_p(app)
      app
    end
    success = Object.new
    def success.success?; true; end
    metadata = "Authority=Developer ID Application: Fixture\nTeamIdentifier=FIXTURE123\n"
    values = [
      [BBCRelease, :source, commit], [BBCRelease, :release_platform!, nil],
      [BBCRelease, :identity, 'A' * 40], [BBCRelease, :remote_tag!, nil],
      [BBCRelease, :capture, capture], [BBCRelease, :run, run],
      [BBCRelease, :package!, package], [BBCRelease, :sign!, nil],
      [Open3, :capture3, ['', metadata, success]]
    ]
    with_stubs(values) { yield calls }
  end

  def test_rejected_notarization_never_creates_final_assets_or_uploads
    simulated_notarization('Invalid') do |calls|
      assert_raises(BBCRelease::Failure) do
        BBCRelease.release(@root, {draft: true}, {'BBC_RELEASE_SIGNING_IDENTITY' => 'fixture', 'BBC_NOTARY_PROFILE' => 'fixture'})
      end
      refute File.exist?(File.join(@root, 'build', 'release', 'v0.1.0'))
      refute calls.any? { |command| command.first == 'gh' }
      refute calls.any? { |command| command[0, 2] == ['xcrun', 'stapler'] }
    end
  end

  def test_accepted_flow_checks_staple_gatekeeper_and_explicit_notary_keychain
    simulated_notarization('Accepted') do |calls|
      BBCRelease.release(@root, {draft: true}, {'BBC_RELEASE_SIGNING_IDENTITY' => 'fixture', 'BBC_NOTARY_PROFILE' => 'fixture', 'BBC_NOTARY_KEYCHAIN' => '/fixture/private.keychain-db'})
      notary_calls = calls.select { |command| command[0, 2] == ['xcrun', 'notarytool'] }
      assert_equal 2, notary_calls.size
      assert notary_calls.all? { |command| command.each_cons(2).include?(['--keychain', '/fixture/private.keychain-db']) }
      gatekeeper = calls.index { |command| command.first == '/usr/sbin/spctl' }
      upload = calls.index { |command| command.first == 'gh' }
      refute_nil gatekeeper
      refute_nil upload
      assert_operator gatekeeper, :<, upload
      assert calls.any? { |command| command[0, 3] == ['xcrun', 'stapler', 'validate'] }
      directory = File.join(@root, 'build', 'release', 'v0.1.0')
      manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
      assert_equal true, manifest.fetch('notarized')
      assert_equal 'a' * 40, manifest.fetch('commit')
      assert_equal 2, File.readlines(File.join(directory, 'SHA256SUMS')).length
    end
  end
end
