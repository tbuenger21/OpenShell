# Release Signatures

OpenShell release candidates and promoted image tags are signed with Cosign.
The public verification key is
[`openshell-release-cosign.pub`](./openshell-release-cosign.pub). The private
key and its password are stored only on the trusted release VM and the local
release workstation; neither belongs in Git.

Verify a digest-pinned OpenShell image before deployment:

```bash
cosign verify \
  --key docs/security/openshell-release-cosign.pub \
  ghcr.io/tbuenger21/openshell/gateway@sha256:<digest>
```

Image signing is provenance evidence until the deployment path performs this
verification before starting the image.
