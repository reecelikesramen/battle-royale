# Manifest signing keys

The launcher (Sprint 3+) verifies the integrity of `versions.json` by checking
an ed25519 signature against a public key compiled into the launcher binary.

## Key custody

- **Private key**: lives only in GCP Secret Manager (`manifest-signing-key`).
  Never committed to git. Only the Cloud Build runtime SA can read it.
- **Public key**: 32 raw bytes, committed to this repo at
  `manifest_pub.ed25519`. Embedded into the launcher at compile time via
  `include_bytes!`.

## Generating a fresh keypair

Run the generator script. It writes the public key into this directory,
prints the private PEM to stdout, and tells you the gcloud command to
upload it to Secret Manager.

```bash
./generate-signing-key.sh
```

The script never writes the private key to disk. Paste the PEM into the
`gcloud secrets versions add ...` command it suggests, then close your
terminal. Once the private key is in Secret Manager, commit the new
`manifest_pub.ed25519` and tag a release.

## Rotation

To rotate: re-run the generator. The launcher binary built after rotation
embeds the new pubkey; old launcher binaries on disk will not be able to
verify manifests signed with the new key, so plan rotations to coincide
with launcher self-update releases. (See Sprint 4 for the
self-update flow.)

The previous Secret Manager version is preserved by GCP — disable it but
don't destroy it for a grace period.

## Format details

- `manifest_pub.ed25519`: 32 bytes, raw ed25519 public key (NOT PEM).
- Secret Manager value: PEM-encoded PKCS8 ed25519 private key.
- Signature output: 64-byte raw ed25519 signature, base64-encoded? No —
  raw bytes. Stored at `gs://<bucket>/versions.json.sig`.
