# Releasing Codex Away

Codex Away releases are universal macOS archives signed with Developer ID,
submitted to Apple's notary service, and attached to a GitHub release. A tag
matching `vMAJOR.MINOR.PATCH` starts the release workflow.

## Required GitHub secrets

Configure these repository secrets before creating the first tag:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` containing the Developer ID Application certificate and private key |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_NOTARY_KEY_BASE64` | Base64-encoded App Store Connect **team** API private key (`.p8`) |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |

Individual App Store Connect API keys do not support `notarytool`; use a team
key. Never commit a `.p12`, `.p8`, password, or encoded credential.

Export the Developer ID Application identity and its private key together from
Keychain Access as a password-protected `.p12`. Send files to GitHub secrets
without printing their contents:

```sh
base64 < DeveloperIDApplication.p12 |
  gh secret set APPLE_DEVELOPER_ID_CERTIFICATE_BASE64

gh secret set APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD

base64 < AuthKey_KEYID.p8 |
  gh secret set APPLE_NOTARY_KEY_BASE64

gh secret set APPLE_NOTARY_KEY_ID
gh secret set APPLE_NOTARY_ISSUER_ID
```

The remaining commands prompt for their values. Do not place secret values in
shell history.

## Create a release

Confirm `main` is clean and current, then create and push an annotated tag:

```sh
git tag -a v0.1.0 -m "Codex Away v0.1.0"
git push origin v0.1.0
```

The workflow runs the test suite, imports the signing identity into a temporary
keychain, builds both architectures, signs the universal executable, submits a
ZIP of the payload to Apple, and publishes these assets only after notarization
succeeds:

```text
codex-away-macos-universal.tar.gz
codex-away-macos-universal.tar.gz.sha256
```

## Validate a published release

On a clean Mac with standalone Codex configured, run:

```sh
curl -fsSL https://raw.githubusercontent.com/akibrhast/codex-away/main/install.sh | sh
```

Verify the LaunchAgent and installed version:

```sh
launchctl print "gui/$(id -u)/com.akibrhast.codex-away"
cat "$HOME/Library/Application Support/CodexAway/VERSION"
```
