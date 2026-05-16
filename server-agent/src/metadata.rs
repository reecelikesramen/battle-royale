use anyhow::{Context, Result};
use serde::Deserialize;
use std::time::{Duration, Instant};

const HOST: &str = "http://metadata.google.internal";

#[derive(Debug)]
pub struct Metadata {
    pub project_id: String,
    pub zone: String,
    /// Numeric instance id — what the Cloud Monitoring `gce_instance` resource
    /// schema actually uses for its `instance_id` label.
    pub instance_id: String,
    /// Human-readable instance name. Used for `instances.stop` API calls.
    pub instance_name: String,
}

impl Metadata {
    pub fn fetch() -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()?;
        Ok(Self {
            project_id: get(&client, "/computeMetadata/v1/project/project-id")?,
            zone: get(&client, "/computeMetadata/v1/instance/zone")?
                .rsplit('/')
                .next()
                .unwrap_or("")
                .to_string(),
            instance_id: get(&client, "/computeMetadata/v1/instance/id")?,
            instance_name: get(&client, "/computeMetadata/v1/instance/name")?,
        })
    }
}

fn get(client: &reqwest::blocking::Client, path: &str) -> Result<String> {
    let resp = client
        .get(format!("{HOST}{path}"))
        .header("Metadata-Flavor", "Google")
        .send()
        .with_context(|| format!("GET {path}"))?
        .error_for_status()?;
    Ok(resp.text()?.trim().to_string())
}

#[derive(Deserialize)]
struct TokenResp {
    access_token: String,
    expires_in: u64,
}

#[derive(Default)]
pub struct AccessToken {
    token: Option<String>,
    expires_at: Option<Instant>,
}

impl AccessToken {
    pub fn value(&self) -> &str {
        self.token.as_deref().unwrap_or("")
    }

    pub fn refresh_if_needed(&mut self, client: &reqwest::blocking::Client) -> Result<()> {
        let now = Instant::now();
        if let Some(expires_at) = self.expires_at {
            if now < expires_at {
                return Ok(());
            }
        }
        let url = format!("{HOST}/computeMetadata/v1/instance/service-accounts/default/token");
        let resp: TokenResp = client
            .get(&url)
            .header("Metadata-Flavor", "Google")
            .send()
            .context("metadata token request")?
            .error_for_status()?
            .json()
            .context("parse token response")?;
        self.token = Some(resp.access_token);
        // Renew 60s early.
        self.expires_at = Some(now + Duration::from_secs(resp.expires_in.saturating_sub(60)));
        Ok(())
    }
}
