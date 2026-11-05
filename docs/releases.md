# Downloadable releases

BBC's distribution lane builds an optimized Apple Silicon app, signs it with Developer ID, submits it to Apple's notarization service, staples the accepted ticket, and checks Gatekeeper before producing downloadable artifacts. It never falls back to development signing or an unnotarized preview.

The ordinary [local build](setup.md) keeps its Apple Development signing identity and `dist/` location. Distribution does not read `Config/LocalSigning.env`, replace the installed app, launch Messages, or change SIP, library validation or quarantine. The GitHub lane uses a temporary signing Keychain on its disposable runner; local builds leave Keychain policy alone.

## Prerequisites

- An Apple Silicon Mac with the Xcode version required by [setup](setup.md).
- The reviewed source merged into `main`, a clean checkout, and an existing tag matching `VERSION`.
- A valid **Developer ID Application** certificate and its private key in the build user's Keychain. An Apple Development certificate cannot substitute for this certificate.
- A working `notarytool` Keychain profile. Configure it interactively with `xcrun notarytool store-credentials`, or use an App Store Connect API key according to Apple's tool help. Keep private keys and credentials outside this public repository. Do not put passwords in source files, workflow logs or release assets. For local setup, prefer interactive prompts over command arguments. The isolated CI import exception is described below.
- GitHub release write access if uploading a draft with the script.

Only an authorized Apple Developer account holder can arrange the distribution certificate. A missing certificate or notarization credential blocks publication; it is not a reason to disable verification. Apple may reject a private-API bridge during notarization. That rejection is also a release blocker, not permission to publish a preview instead.

## Version and source

`VERSION` is strict JSON containing the marketing version and positive integer build number:

```json
{"version":"0.1.0","build":1}
```

Both local app packaging and distribution packaging read it. Update it through the normal reviewed source change, incrementing the version/build for a new release. The release tag is `v` plus the marketing version. The release script requires:

- No modified tracked files or untracked source files.
- `HEAD` equal to that tag's commit.
- The tagged commit already reachable from `origin/main`.

Fetch the current `origin/main` and tags before building. Do not retag a published release. The app's `BBCSourceCommit` and the release manifest record the exact commit; source is checked again after building. Generated output under ignored `build/` does not affect source cleanliness.

## Build and notarize

Set the selected Developer ID identity (certificate fingerprint or exact name) and the existing Keychain profile name in the shell environment:

```sh
export BBC_RELEASE_SIGNING_IDENTITY='<Developer ID Application certificate fingerprint>'
export BBC_NOTARY_PROFILE='<notarytool Keychain profile>'
bash script/release.sh --check
bash script/release.sh
```

`--check` validates source, architecture, the distribution identity and notary credentials without signing or submitting an app. It still requires clean tagged source. `--tag v0.1.0` can select the tag explicitly; it must match `VERSION`. There is no preview flag.

The build uses `BBC_CONFIG=release`, `BBC_ARCH=arm64` and `BBC_SYSTEM_SQLITE=1`, with isolated pkg-config paths so a local Homebrew SQLite is not linked into the download. It checks Mach-O dependencies and refuses non-system/unresolved dylibs. The app executable is arm64-only; the embedded bridge retains its required Mac Catalyst slices without implying Intel app support. The accepted Icon Composer asset and the app's entitlements are retained.

Code is signed from the inside out with hardened runtime and secure timestamps: Mach-O code, resource bundles, and the enclosing app. The script does not use deep signing. It rejects `get-task-allow`, requires Apple's accepted notarization result, validates the stapled ticket, and runs signature and Gatekeeper checks. A failed step leaves no final release directory. Temporary submission files are removed; output from a successful run is never overwritten.

The final directory is `build/release/v0.1.0/` (using the selected version) and contains:

- `BlueBubbleClub-0.1.0-macos-arm64.zip`, made after stapling.
- `manifest.json`, including version/build, source SHA, architecture, Xcode/SDK, signer Team ID, notarization submission ID and `notarized: true`.
- `SHA256SUMS`, covering the archive and manifest.

This describes the build recipe. End-to-end notarization and installation acceptance have not yet been verified with distribution credentials. Check the actual release assets and manifest before claiming a release is notarized.

## Verify the download and publish

Before publication, download/extract the exact archive into a separate location, check its checksum, and verify the app signature, stapled ticket and Gatekeeper assessment. Check that bundled resources load without a source checkout or `.build` directory. Use a separate clean Mac account for installation acceptance when available. Do not send messages as part of packaging validation.

```sh
shasum -a 256 -c SHA256SUMS
codesign --verify --strict 'Blue Bubble Club.app'
xcrun stapler validate 'Blue Bubble Club.app'
spctl --assess --type execute --verbose=2 'Blue Bubble Club.app'
```

Add reviewed notes at `docs/releases/v0.1.0.md` and push the matching tag before using the upload option:

```sh
bash script/release.sh --draft
```

`--draft` builds and validates the artifacts, then creates a draft GitHub release with `--verify-tag`; it does not create a tag or publish a release implicitly. If artifacts already exist, do not rebuild or overwrite them: upload those verified files with `gh release create --draft --verify-tag` and the matching notes, then publish that same draft after reviewing its assets. Publishing an already reviewed draft is `gh release edit <tag> --draft=false`. Check that the published tag, manifest commit and checksum still match. Never replace assets of a published version; issue a new version for a changed build.

Release notes must identify Apple Silicon/macOS requirements, installation and upgrade steps, notable changes, signing/notarization state, source commit and known capability limits. Native functionality still needs the separately chosen host configuration in [setup](setup.md#native-messaging); notarization does not change that contract or prove live private-API compatibility.

A downloadable Developer ID build has a different signing requirement from a locally built Apple Development app. Replacing one with the other may require granting Full Disk Access and Messages Automation again. Keep the previous app for rollback and preserve the local data stores and keys. The release script itself does not install the download over a local development app.

## Protected GitHub Actions release

[The manual release workflow](../.github/workflows/release.yml) runs only from this repository's `main` branch. It does not run for pull requests or tag pushes. Merge the reviewed source, matching `VERSION`, and `docs/releases/vX.Y.Z.md` first, then push the existing release tag. The workflow checks that the tag is an ancestor of the exact reviewed `main` commit that supplied the workflow. It checks the tag again before using credentials and before creating the draft.

The three jobs have separate permissions and approval gates:

1. **Verify** runs on Ubuntu with read-only repository access and no Apple secrets. It validates the tag, source ancestry, version, release notes and source cleanliness.
2. **Sign** requires approval through the `release` environment. It uses a fresh GitHub-hosted Apple Silicon `macos-26` VM, read-only repository access, and Xcode at `/Applications/Xcode_27.2.app`. An unavailable runner architecture or Xcode installation stops the release before credential access. The published hosted-image inventory currently does not include Xcode 27.2, so this gate remains blocked until a supported toolchain is validated and deliberately selected.
3. **Publish** requires a separate approval through `release-publish`. It has repository write access and no Apple secrets. It checks an exact file allowlist, checksums, manifest version/commit/notarization state, ZIP paths and the remote tag, then creates a **draft** release with the notes from the verified source commit.

Configure both environments to allow only `main`, require the owner's approval, and disable administrator bypass. A solo maintainer can allow self-review: this confirms intent, not independent review. Protect `main` and release tags, and review workflow and release-script changes through the repository's ownership rules. Actions are pinned by commit SHA; routine CI has no release credentials or publication permission.

The ordinary validation workflow includes an unsigned Xcode 26.6 compatibility lane on `macos-26`. It builds from a fresh checkout and pinned dependencies, runs the SDK, bridge and app fixtures, checks exported bridge symbols and Mac Catalyst slices, and records binary platform/minimum-OS requirements and icon outputs. Compare its icon output with the Xcode 27.2 lane before changing the release requirement. This lane has no signing credentials and its existence does not establish compatibility; its actual run and artifact evidence must pass first.

### Apple credentials

Only the `release` environment receives these secrets:

| Secret | Value |
| --- | --- |
| `BBC_DEVELOPER_ID_P12_BASE64` | Base64-encoded PKCS#12 export containing the Developer ID Application certificate and its private key. |
| `BBC_DEVELOPER_ID_P12_PASSWORD` | Password protecting that export. |
| `BBC_ASC_KEY_P8` | App Store Connect API private key text, including its PEM delimiters. |
| `BBC_ASC_KEY_ID` | The API key ID. |
| `BBC_ASC_ISSUER_ID` | The API issuer ID. |

The Apple Developer account holder must create/export these credentials and enter them through GitHub's protected environment secret settings. Prefer a dedicated team API key with only the role needed for notarization. Do not paste private material into chat, issues, repository files or release notes. The workflow does not provision Apple credentials, and none are required for ordinary tests.

The signing helper creates a random-password Keychain and private files under `RUNNER_TEMP` with restrictive permissions. It imports only the selected certificate, restricts key access to signing tools, and stores a validated notary profile in that Keychain. Apple's headless `security import -P` interface places the export password in process arguments; this is accepted only on the fresh, single-job hosted VM. Commands and their credential-bearing arguments are never printed. Do not run this helper on a shared or self-hosted machine.

The helper removes raw credential files and secret environment variables before building. It restores the previous Keychain search list/default, deletes the signing Keychain and private files on completion or failure, and has a separate always-run cleanup step. Abrupt VM termination is covered by disposal of the hosted VM. No Keychain, private file, notary log or build cache is uploaded; the artifact contains only the final ZIP, manifest and checksums.

Approval trusts **all code executed in the signing job**, including the reviewed workflow, helpers, build scripts and dependencies. Removing secret environment variables does not prevent trusted job code from using the unlocked signing Keychain. Review those inputs before approval. A signing identity change may require macOS permission grants again as described above. If credentials leak, revoke the certificate and API key in Apple's portals and replace the environment secrets.

### Run and publish

After those prerequisites are ready:

```sh
gh workflow run release.yml --ref main -f tag=v0.1.0
```

Review and approve the signing job, then approve the separate draft-creation job after inspecting its run and artifact provenance. A failed notarization never becomes a preview release. Download the draft's exact archive and complete the installation checks above before publishing that same draft:

```sh
gh release edit v0.1.0 --draft=false
```

The workflow has not yet completed a credentialed end-to-end run. A draft, successful unit tests, or valid YAML alone does not establish Apple's acceptance or installation compatibility.

## Secret-free checks

Run `/usr/bin/ruby script/test_release.rb` and `/usr/bin/ruby script/ci_release_test.rb`. They use disposable repositories, synthetic metadata and archives, and mocked Keychain cleanup commands. They check source guards, artifact rejection and cleanup behavior without signing or contacting Apple's service. Syntax checks do not establish notarization or installation acceptance.
