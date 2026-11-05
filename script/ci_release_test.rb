#!/usr/bin/env ruby
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require_relative 'ci_release'
require_relative 'ci_release_sign'

class CIReleaseTests < Minitest::Test
  def setup
    @root = Dir.mktmpdir('bbc-ci-test-')
    @tag = 'v0.1.0'
    @commit = 'a' * 40
  end

  def teardown
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def artifact_fixture
    archive = 'BlueBubbleClub-0.1.0-macos-arm64.zip'
    app = File.join(@root, 'Blue Bubble Club.app')
    FileUtils.mkdir_p(app)
    File.write(File.join(app, 'Info.plist'), 'synthetic test app, not signed')
    Dir.chdir(@root) { raise 'zip fixture failed' unless system('/usr/bin/zip', '-qr', archive, 'Blue Bubble Club.app') }
    FileUtils.remove_entry(app)
    manifest = {'version' => '0.1.0', 'build' => 1, 'tag' => @tag, 'commit' => @commit, 'architecture' => 'arm64', 'archive' => archive, 'notarized' => true}
    File.write(File.join(@root, 'manifest.json'), JSON.generate(manifest))
    checksum_fixture(archive)
    archive
  end

  def checksum_fixture(archive)
    names = [archive, 'manifest.json']
    File.write(File.join(@root, 'SHA256SUMS'), names.map { |name| "#{Digest::SHA256.file(File.join(@root, name)).hexdigest}  #{name}\n" }.join)
  end

  def test_context_is_main_manual_dispatch_only
    base = {'GITHUB_REPOSITORY' => 'lucasilverentand/BBC', 'GITHUB_REF' => 'refs/heads/main', 'GITHUB_EVENT_NAME' => 'workflow_dispatch', 'GITHUB_SHA' => @commit}
    assert_equal @commit, BBCReleaseCI.context!(base)
    [{'GITHUB_REPOSITORY' => 'fork/BBC'}, {'GITHUB_REF' => 'refs/heads/feature'}, {'GITHUB_EVENT_NAME' => 'pull_request_target'}].each do |change|
      assert_raises(BBCRelease::Failure) { BBCReleaseCI.context!(base.merge(change)) }
    end
  end

  def test_tag_input_rejects_options_and_shell_syntax
    ['--all', 'v1.2.3; echo unsafe', 'v1.2.3/../../other', 'v01.2.3', '1.2.3'].each do |tag|
      assert_raises(BBCRelease::Failure) { BBCReleaseCI.tag!(tag) }
    end
  end

  def source_fixture(version = '0.1.0')
    BBCReleaseCI.capture('git', '-C', @root, 'init', '-q')
    BBCReleaseCI.capture('git', '-C', @root, 'config', 'user.name', 'Release Fixture')
    BBCReleaseCI.capture('git', '-C', @root, 'config', 'user.email', 'fixture@example.invalid')
    FileUtils.mkdir_p(File.join(@root, 'docs/releases'))
    File.write(File.join(@root, 'VERSION'), JSON.generate('version' => version, 'build' => 1))
    File.write(File.join(@root, 'docs/releases', "#{@tag}.md"), 'Synthetic release notes')
    BBCReleaseCI.capture('git', '-C', @root, 'add', '.')
    BBCReleaseCI.capture('git', '-C', @root, 'commit', '-qm', 'Synthetic tagged source')
    BBCReleaseCI.capture('git', '-C', @root, 'tag', @tag)
    commit = BBCReleaseCI.capture('git', '-C', @root, 'rev-parse', 'HEAD')
    BBCReleaseCI.capture('git', '-C', @root, 'commit', '--allow-empty', '-qm', 'Synthetic reviewed main')
    [commit, BBCReleaseCI.capture('git', '-C', @root, 'rev-parse', 'HEAD')]
  end

  def test_source_guard_binds_tag_to_main_and_exact_checkout
    commit, main = source_fixture
    assert_equal commit, BBCReleaseCI.verify_source(@root, @tag, main)
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.verify_source(@root, @tag, main, 'b' * 40) }
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.verify_source(@root, @tag, main, commit, checkout: true) }
    BBCReleaseCI.capture('git', '-C', @root, 'checkout', '--detach', commit)
    assert_equal commit, BBCReleaseCI.verify_source(@root, @tag, main, commit, checkout: true)
    File.write(File.join(@root, 'unreviewed'), 'Synthetic dirty source')
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.verify_source(@root, @tag, main, commit, checkout: true) }
  end

  def test_source_guard_rejects_version_mismatch
    _, main = source_fixture('0.2.0')
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.verify_source(@root, @tag, main) }
  end

  def test_source_guard_rejects_a_tag_outside_trusted_main_history
    source_fixture
    tree = BBCReleaseCI.capture('git', '-C', @root, 'rev-parse', 'HEAD^{tree}')
    unrelated = BBCReleaseCI.capture('git', '-C', @root, 'commit-tree', tree, '-m', 'Synthetic unrelated history')
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.verify_source(@root, @tag, unrelated) }
  end

  def test_verified_artifact_is_accepted
    archive = artifact_fixture
    assert_equal archive, BBCReleaseCI.validate_artifacts(@root, @tag, @commit)
  end

  def test_modified_archive_is_rejected
    archive = artifact_fixture
    File.open(File.join(@root, archive), 'a') { |file| file.write('changed') }
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.validate_artifacts(@root, @tag, @commit) }
  end

  def test_unnotarized_or_wrong_source_manifest_is_rejected_even_with_valid_checksums
    archive = artifact_fixture
    original = JSON.parse(File.read(File.join(@root, 'manifest.json')))
    [{'notarized' => false}, {'commit' => 'b' * 40}, {'archive' => '../elsewhere.zip'}, {'version' => '0.2.0'}].each do |change|
      File.write(File.join(@root, 'manifest.json'), JSON.generate(original.merge(change)))
      checksum_fixture(archive)
      assert_raises(BBCRelease::Failure) { BBCReleaseCI.validate_artifacts(@root, @tag, @commit) }
    end
  end

  def test_extra_artifacts_are_rejected
    artifact_fixture
    File.write(File.join(@root, 'credentials.p12'), 'synthetic')
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.validate_artifacts(@root, @tag, @commit) }
  end

  def test_symlink_artifact_is_rejected
    artifact_fixture
    path = File.join(@root, 'manifest.json')
    outside = File.join(@root, 'outside')
    File.rename(path, outside)
    File.symlink(outside, path)
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.validate_artifacts(@root, @tag, @commit) }
  end

  def test_duplicate_checksum_entries_are_rejected
    artifact_fixture
    path = File.join(@root, 'SHA256SUMS')
    first = File.readlines(path).first
    File.write(path, first + first)
    assert_raises(BBCRelease::Failure) { BBCReleaseCI.validate_artifacts(@root, @tag, @commit) }
  end

  def test_archive_traversal_is_rejected
    artifact_fixture
    BBCReleaseCI.stub(:capture, "Blue Bubble Club.app/../../outside\n") do
      assert_raises(BBCRelease::Failure) { BBCReleaseCI.validate_artifacts(@root, @tag, @commit) }
    end
  end

  def test_signing_cleanup_does_not_delete_other_directories
    previous = ENV['RUNNER_TEMP']
    ENV['RUNNER_TEMP'] = @root
    unrelated = File.join(@root, 'unrelated')
    FileUtils.mkdir_p(unrelated)
    assert_raises(BBCRelease::Failure) { BBCReleaseSigning.cleanup(unrelated) }
    assert File.directory?(unrelated)
  ensure
    ENV['RUNNER_TEMP'] = previous
  end

  def test_signing_cleanup_restores_search_list_and_removes_owned_private_files
    previous = ENV['RUNNER_TEMP']
    ENV['RUNNER_TEMP'] = @root
    directory = Dir.mktmpdir('bbc-release-signing-', @root)
    File.write(File.join(directory, 'state.json'), JSON.generate('default' => '/fixture/login.keychain-db', 'search' => ['/fixture/login.keychain-db']))
    File.write(File.join(directory, 'signing.keychain-db'), 'synthetic keychain')
    File.write(File.join(directory, 'certificate.p12'), 'synthetic private file')
    commands = []
    BBCReleaseSigning.stub(:private_command, ->(*args) { commands << args; '' }) { BBCReleaseSigning.cleanup(directory) }
    refute File.exist?(directory)
    assert_equal ['default-keychain', 'list-keychains', 'delete-keychain'], commands.map { |args| args[1] }
  ensure
    ENV['RUNNER_TEMP'] = previous
  end

  def test_signing_cleanup_attempts_all_steps_after_a_restore_failure
    previous = ENV['RUNNER_TEMP']
    ENV['RUNNER_TEMP'] = @root
    directory = Dir.mktmpdir('bbc-release-signing-', @root)
    File.write(File.join(directory, 'state.json'), JSON.generate('default' => '/fixture/login.keychain-db', 'search' => ['/fixture/login.keychain-db']))
    File.write(File.join(directory, 'signing.keychain-db'), 'synthetic keychain')
    File.write(File.join(directory, 'notary-key.p8'), 'synthetic private file')
    commands = []
    BBCReleaseSigning.stub(:private_command, lambda { |*args|
      commands << args
      raise BBCRelease::Failure, 'Synthetic restore failure' if args[1] == 'default-keychain'
      ''
    }) { assert_raises(BBCRelease::Failure) { BBCReleaseSigning.cleanup(directory) } }
    assert_equal ['default-keychain', 'list-keychains', 'delete-keychain'], commands.map { |args| args[1] }
    refute File.exist?(directory)
  ensure
    ENV['RUNNER_TEMP'] = previous
  end
end
