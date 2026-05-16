use anyhow::{Context, Result, bail};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::Deserialize;
use std::collections::BTreeMap;

use crate::keys::{MANIFEST_PUBKEY, is_placeholder_key};

#[derive(Debug, Deserialize, Clone)]
pub struct Manifest {
    pub schema: u32,
    pub latest: String,
    pub versions: BTreeMap<String, VersionEntry>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct VersionEntry {
    pub released_at: Option<String>,
    pub platforms: BTreeMap<String, PlatformEntry>,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct PlatformEntry {
    pub launcher: Option<Component>,
    #[serde(default)]
    pub launcher_updater: Option<Component>,
    pub game_binary: Option<Component>,
    pub rust_lib: Option<Component>,
    pub pck_base: Option<Component>,
    pub pck_patch: Option<Component>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Component {
    pub url: String,
    pub sha256: String,
    pub size: u64,
    #[serde(default)]
    pub installed_name: Option<String>,
    #[serde(default)]
    pub delta: Option<Delta>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Delta {
    pub url: String,
    pub sha256: String,
    pub size: u64,
    pub from: String,
    pub algo: String,
}

fn dev_skip_enabled() -> bool {
    matches!(std::env::var("BR_DEV_SKIP_SIG").as_deref(), Ok("1"))
}

pub fn verify_signature(manifest_bytes: &[u8], signature_bytes: &[u8]) -> Result<()> {
    if dev_skip_enabled() {
        if is_placeholder_key() {
            eprintln!("warning: BR_DEV_SKIP_SIG set; skipping signature verification (placeholder pubkey)");
        } else {
            eprintln!("warning: BR_DEV_SKIP_SIG set; skipping signature verification");
        }
        return Ok(());
    }
    if is_placeholder_key() {
        bail!(
            "launcher was built with the all-zero placeholder pubkey. \
             Generate keys with infrastructure/keys/generate-signing-key.sh \
             and rebuild, or set BR_DEV_SKIP_SIG=1 for development."
        );
    }

    let key = VerifyingKey::from_bytes(&MANIFEST_PUBKEY)
        .context("embedded pubkey is not a valid ed25519 verifying key")?;
    verify_signature_with_key(&key, manifest_bytes, signature_bytes)
}

/// Same crypto as `verify_signature` but takes an explicit pubkey. Used by
/// tests to exercise the verification path with a generated keypair instead
/// of the binary-embedded production key.
pub fn verify_signature_with_key(
    key: &VerifyingKey,
    manifest_bytes: &[u8],
    signature_bytes: &[u8],
) -> Result<()> {
    let sig_bytes: [u8; 64] = signature_bytes
        .try_into()
        .context("signature is not 64 bytes")?;
    let sig = Signature::from_bytes(&sig_bytes);
    key.verify(manifest_bytes, &sig)
        .context("manifest signature verification failed")?;
    Ok(())
}

pub fn parse(bytes: &[u8]) -> Result<Manifest> {
    let m: Manifest = serde_json::from_slice(bytes).context("parse versions.json")?;
    if m.schema != 2 {
        bail!("unsupported manifest schema: {}", m.schema);
    }
    Ok(m)
}

/// Returns the version entry for the platform `current` -> `target` upgrade.
/// `current` may not exist in the manifest (e.g., the user installed a snapshot
/// not listed); in that case we just return the latest.
pub fn target_platform<'a>(m: &'a Manifest, platform: &str) -> Result<&'a PlatformEntry> {
    let latest = m
        .versions
        .get(&m.latest)
        .with_context(|| format!("latest version {} missing from manifest.versions", m.latest))?;
    latest
        .platforms
        .get(platform)
        .with_context(|| format!("no entry for platform {platform} in manifest"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn fixture_manifest_bytes() -> Vec<u8> {
        // Minimal but realistic v2 manifest with one platform + one component.
        // Matches the schema launcher code expects to parse.
        br#"{
          "schema": 2,
          "latest": "v1.0.0",
          "versions": {
            "v1.0.0": {
              "released_at": "2026-05-15T00:00:00Z",
              "platforms": {
                "linux": {
                  "game_binary": {
                    "url": "https://example.test/game",
                    "sha256": "abc",
                    "size": 123
                  }
                }
              }
            }
          }
        }"#.to_vec()
    }

    fn keypair() -> SigningKey {
        // Deterministic per-test, but not a real production key.
        SigningKey::from_bytes(&[0x42; 32])
    }

    #[test]
    fn signature_roundtrip_verifies() {
        let bytes = fixture_manifest_bytes();
        let sk = keypair();
        let sig = sk.sign(&bytes).to_bytes();
        verify_signature_with_key(&sk.verifying_key(), &bytes, &sig)
            .expect("freshly-signed manifest must verify");
    }

    #[test]
    fn signature_rejects_tampered_payload() {
        let bytes = fixture_manifest_bytes();
        let sk = keypair();
        let sig = sk.sign(&bytes).to_bytes();
        // Flip one byte of the manifest after signing. Real attacker scenario:
        // bucket object swapped, signature unchanged.
        let mut tampered = bytes.clone();
        tampered[0] ^= 0x01;
        assert!(
            verify_signature_with_key(&sk.verifying_key(), &tampered, &sig).is_err(),
            "tampered manifest must NOT verify"
        );
    }

    #[test]
    fn signature_rejects_wrong_key() {
        let bytes = fixture_manifest_bytes();
        let sk = keypair();
        let sig = sk.sign(&bytes).to_bytes();
        let other = SigningKey::from_bytes(&[0x99; 32]);
        assert!(
            verify_signature_with_key(&other.verifying_key(), &bytes, &sig).is_err(),
            "signature made by one key must not verify against another"
        );
    }

    #[test]
    fn signature_rejects_truncated() {
        let bytes = fixture_manifest_bytes();
        let sk = keypair();
        let mut sig = sk.sign(&bytes).to_bytes().to_vec();
        sig.pop(); // 63 bytes — should be rejected before crypto runs
        assert!(verify_signature_with_key(&sk.verifying_key(), &bytes, &sig).is_err());
    }

    #[test]
    fn parse_accepts_v2() {
        let m = parse(&fixture_manifest_bytes()).expect("v2 manifest must parse");
        assert_eq!(m.schema, 2);
        assert_eq!(m.latest, "v1.0.0");
    }

    #[test]
    fn parse_rejects_wrong_schema() {
        let bad = br#"{"schema": 1, "latest": "v1", "versions": {}}"#;
        assert!(parse(bad).is_err(), "must refuse v1 schema");
    }

    #[test]
    fn parse_rejects_garbage() {
        assert!(parse(b"not json").is_err());
        assert!(parse(b"").is_err());
    }

    #[test]
    fn target_platform_missing_platform_errors() {
        let m = parse(&fixture_manifest_bytes()).unwrap();
        assert!(
            target_platform(&m, "amiga").is_err(),
            "unknown platform must error rather than silently fall through"
        );
    }
}
