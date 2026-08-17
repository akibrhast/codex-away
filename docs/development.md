# Developing Codex Away

Codex Away is a Swift package:

```text
Sources/
├── RemoteDevCore/       State, policy, and policy evaluation
├── RemoteDevServices/   Managed services and system boundaries
└── RemoteDevDaemon/     macOS events and service control

Tests/
├── RemoteDevCoreTests/      Core policy tests
└── RemoteDevServicesTests/  Service and reconciliation tests
```

Internal Swift target names remain unchanged. They do not affect the public
product identity.

## Test

```sh
swift test
```

## Build

Build the release executable without installing it:

```sh
swift build --configuration release --product codex-away
```

## Install from source

Install the current source checkout for local development:

```sh
./scripts/install-source.sh
```

End users should use the signed release installer documented in the README
instead of installing from source.

## Release

Create a signed universal release bundle:

```sh
CODEX_AWAY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-release.sh v0.1.0
```

Release maintainers should follow [Releasing Codex Away](releasing.md) to
configure signing and notarization secrets and publish versioned artifacts.
