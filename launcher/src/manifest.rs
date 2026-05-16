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
    let sig_bytes: [u8; 64] = signature_bytes
        .try_into()
        .context("signature is not 64 bytes")?;
    let sig = Signature::from_bytes(&sig_bytes);
    key.verify(manifest_bytes, &sig)
        .context("manifest signature verification failed")?;
    Ok(())
}

pub fn parse(bytes: &[u8]) -> Result<Manifest> {
    let m: Manifest = serde_json::from_slice(bytes).context("parse versions-v2.json")?;
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
