# Release Pipeline

OpenShell container images are released from a trusted Linux release host.
GitHub Actions is not part of this image-release path.

## Artifact Flow

`tasks/scripts/release-images.sh` is the canonical command:

1. It builds and pushes multi-platform gateway, supervisor, and cluster images
   under `sha-<commit>`.
2. The Buildx build attaches OCI source labels, provenance, and an SBOM to each
   pushed image.
3. It snapshots all three published manifest digests into
   `dist/releases/sha-<commit>/release.env`, then runs Python, Rust, and
   gateway-resume E2E with the exact cluster and gateway digest refs.
4. After E2E passes, `--version <version>` creates its versioned deployment
   record from that exact candidate manifest.
5. When `--version <version>` or `--alias <tag>` is specified, it signs those
   exact candidate digests, then promotes every requested tag from the same
   manifest. Each promoted tag is checked against the expected digest.

The command has no default release tag. A Docker-compatible semantic version
such as `v0.1.0` or `v1.2.3-rc.1` is
a fixed release label in this release protocol; `dev` and `latest` are explicit
moving aliases made only after E2E succeeds. Deployments use the digest refs in
the release manifest, not any tag.
SemVer build metadata (`+build`) is not accepted because OCI tags cannot
contain `+`.

The candidate tag is always exactly `sha-<full checked-out commit>`. The
release command refuses to rebuild an existing candidate. Fixed release tags
are idempotent: an existing tag is accepted only when it already resolves to
the tested digest; a different digest fails. OCI tag writes are not atomic
across images, and GHCR does not provide a container-tag immutability control,
so the digest manifest is the authority. `dev`, `latest`, `edge`, and `nightly`
are deliberately moving aliases and can be changed only by the top-level
release command after E2E and signing.

## Release Host

The release host must be an isolated machine with Docker, Buildx support for
`linux/amd64,linux/arm64`, `mise`, `uv`, Cargo, an SSH client, and authenticated
registry access. Alias promotion additionally requires `cosign` plus a protected
`COSIGN_KEY`; its password must come from the host's secret mechanism rather
than a repository file.

Restrict registry write access to the release host. If a future registry offers
immutable OCI tags, enable that as additional protection; do not rely on a tag
for reproducible deployment.

Run the command from a clean checkout:

```bash
source "$HOME/.config/potatostew/release/cosign.env"
tasks/scripts/release-images.sh --version v0.1.0 --alias latest
```

If the registry package is private, also provide
`OPENSHELL_REGISTRY_USERNAME` and `OPENSHELL_REGISTRY_PASSWORD` from the host
secret mechanism. The E2E cluster needs those credentials to pull the published
gateway candidate inside Kubernetes.

`--alias` may be repeated and accepts only `dev`, `latest`, `edge`, or
`nightly`. Omit both `--version` and `--alias` to publish and test a candidate
without moving any release tag. If E2E or promotion is interrupted, rerun the
same command with `--resume`; it loads the saved digest manifest, retests the
same artifacts, and completes only tags that already match or can be promoted
from that manifest. The candidate tag is derived from the exact Git commit and
is a build input, while the saved digest manifest is the deployable record.

Release manifests are strict data records, not shell scripts. The release
command rejects missing, duplicate, unknown, or malformed keys and never
sources a manifest while release credentials are loaded.

## Lower-Level Publisher

`tasks/scripts/docker-publish-multiarch.sh` builds candidate images only. It
rejects a mutable primary tag and refuses alias tags unless the operator sets an
explicit development escape hatch. Do not use that escape hatch for releases;
use `tasks/scripts/release-images.sh` instead.
