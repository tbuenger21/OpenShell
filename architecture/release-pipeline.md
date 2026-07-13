# Release Pipeline

OpenShell container images are released from a trusted Linux release host.
GitHub Actions is not part of this image-release path.

## Artifact Flow

`tasks/scripts/release-images.sh` is the canonical command:

1. It builds and pushes multi-platform gateway, supervisor, and cluster images
   under `sha-<commit>`.
2. The Buildx build attaches OCI source labels, provenance, and an SBOM to each
   pushed image.
3. The command runs Python, Rust, and gateway-resume E2E suites against the
   published candidate cluster image.
4. When `--promote <tag>` is specified, it resolves the exact candidate
   digests, signs them with the local Cosign key, then moves that one alias.

The command has no default alias. `dev`, a semantic version, and `latest` are
all explicit operator choices made only after E2E succeeds. Deployments should
use a semantic version or a digest, not a moving alias.

The candidate tag is always exactly `sha-<full checked-out commit>`. The
release command refuses to replace an existing candidate or a version alias.
The registry must also prohibit replacement/deletion of candidate and version
tags, because a client-side preflight cannot close a concurrent registry-write
race. `dev`, `latest`, `edge`, and `nightly` are deliberately moving aliases
and can be changed only by the top-level release command after E2E and signing.

## Release Host

The release host must be an isolated machine with Docker, Buildx support for
`linux/amd64,linux/arm64`, `mise`, `uv`, Cargo, an SSH client, and authenticated
registry access. Alias promotion additionally requires `cosign` plus a protected
`COSIGN_KEY`; its password must come from the host's secret mechanism rather
than a repository file.

The release registry needs a policy that prevents ordinary writers from
replacing or deleting candidate and version tags.

Run the command from a clean checkout:

```bash
COSIGN_KEY=/etc/openshell/release/cosign.key \
tasks/scripts/release-images.sh --promote dev
```

If the registry package is private, also provide
`OPENSHELL_REGISTRY_USERNAME` and `OPENSHELL_REGISTRY_PASSWORD` from the host
secret mechanism. The E2E cluster needs those credentials to pull the published
gateway candidate inside Kubernetes.

Omit `--promote` to publish and test a candidate without moving an alias. The
candidate tag is derived from the exact Git commit, so a downstream appliance
can use that tag as an immutable gateway/supervisor input.

## Lower-Level Publisher

`tasks/scripts/docker-publish-multiarch.sh` builds candidate images only. It
rejects a mutable primary tag and refuses alias tags unless the operator sets an
explicit development escape hatch. Do not use that escape hatch for releases;
use `tasks/scripts/release-images.sh` instead.
