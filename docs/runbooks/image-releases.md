# Image Releases

OpenShell image releases run on the trusted Linux release VM, not GitHub
Actions. `tasks/scripts/release-images.sh` publishes source-SHA candidates for
the gateway, supervisor, and cluster, runs the published-image E2E suites,
signs their immutable digests, and only then promotes an optional version and
moving aliases.

The candidate tag is always `sha-<full-checked-out-commit>`. A version such as
`v0.1.3` is a fixed compatibility label; `latest` is a moving alias. Deployment
authority is the digest-pinned `release.env`, never a tag. See
[release signatures](../security/release-signatures.md) for the public Cosign
verification key and verification command.

## Requirements

The release VM needs Docker Buildx with `linux/amd64` and `linux/arm64` support,
`mise`, `uv`, Cargo, Helm, SSH, Cosign, a clean OpenShell checkout, and registry
write authentication. The encrypted Cosign key and its password remain outside
the repository in the release host's owner-only secret files.

## Release A Changed OpenShell Revision

Use this procedure only when the selected OpenShell source revision has changed
or lacks a tested published source-SHA candidate. A downstream potatostew-only
release reuses the existing OpenShell candidate and does not require this
procedure.

```bash
cd /home/azureadmin/OpenShell
OPEN_SHELL_SHA="$(git rev-parse HEAD)"
OPEN_SHELL_RELEASE_ROOT="$HOME/.local/share/openshell/releases"
source "$HOME/.config/potatostew/release/openshell.env"

tasks/scripts/release-images.sh \
  --output-dir "$OPEN_SHELL_RELEASE_ROOT/sha-${OPEN_SHELL_SHA}" \
  --version v<next-version> \
  --alias latest
```

The command creates the candidate record at
`$OPEN_SHELL_RELEASE_ROOT/sha-<commit>/release.env` and, after successful E2E,
creates the equivalent versioned record at
`$OPEN_SHELL_RELEASE_ROOT/v<version>/release.env` before signing and tag
promotion. Do not rely only on the default `dist/releases/` output because it
is part of a disposable build checkout.

The record contains the exact pinned gateway, supervisor, cluster, and external
sandbox image digests. Keep it with the deployment configuration. Do not source
it as a shell script; deployment tooling must parse and validate it as strict
data.

## Downstream Use

Potatostew consumes an explicit `sha-<OpenShell commit>` image tag when building
its appliance. Select a published OpenShell candidate and ensure the clean
sibling checkout used by potatostew is at that exact commit. Do not use
`latest`, `dev`, or another moving alias as the appliance input.

If a release stops after candidates are published, rerun the same command with
`--resume` and the same `--output-dir`. It retests the saved candidate manifest
and only promotes tags that still match the tested digests.
