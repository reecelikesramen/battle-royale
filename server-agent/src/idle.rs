use anyhow::{Context, Result};
use std::time::{Duration, Instant};

use crate::metadata::{AccessToken, Metadata};

/// Tracks the last time we saw a non-zero player count. Idle == "we have
/// observed zero players continuously for >= threshold".
pub struct IdleTracker {
    last_active: Option<Instant>,
    threshold: Duration,
}

impl IdleTracker {
    pub fn new(threshold: Duration) -> Self {
        // Treat startup as "active" so a freshly-booted empty server isn't
        // shut down immediately. The first metric tick will refresh this.
        Self {
            last_active: Some(Instant::now()),
            threshold,
        }
    }

    pub fn note_active(&mut self, now: Instant) {
        self.last_active = Some(now);
    }

    pub fn note_idle(&mut self, _now: Instant) {
        // Leave last_active as-is; idle time accumulates from there.
        if self.last_active.is_none() {
            self.last_active = Some(_now);
        }
    }

    pub fn idle_for(&self, now: Instant) -> Option<Duration> {
        self.last_active.map(|t| now.duration_since(t))
    }

    pub fn should_shutdown(&self, now: Instant) -> bool {
        self.idle_for(now)
            .map(|d| d >= self.threshold)
            .unwrap_or(false)
    }
}

/// Read the latest value of the players_connected custom metric via the Cloud
/// Monitoring REST API. The metric is written every 30s by the game-side
/// `MetricsReporter` autoload. We fetch the most recent point in the last
/// 2 minutes; if there is no point, treat as 0 (idle).
pub fn current_players(
    client: &reqwest::blocking::Client,
    md: &Metadata,
    token: &AccessToken,
) -> Result<u32> {
    let metric_type = "custom.googleapis.com/battle_royale/players_connected";
    let filter = format!(
        "metric.type = \"{metric_type}\" AND resource.labels.instance_id = \"{}\"",
        md.instance_id
    );
    let now = chrono_secs();
    let url = format!(
        "https://monitoring.googleapis.com/v3/projects/{}/timeSeries\
?filter={filter}\
&interval.startTime={start}\
&interval.endTime={end}\
&aggregation.alignmentPeriod=60s\
&aggregation.perSeriesAligner=ALIGN_MAX",
        md.project_id,
        filter = urlencoding(&filter),
        start = rfc3339(now - 120),
        end = rfc3339(now),
    );

    let resp = client
        .get(&url)
        .bearer_auth(token.value())
        .send()
        .context("monitoring timeseries query")?;
    // 404 here means the custom metric descriptor doesn't exist yet — Cloud
    // Monitoring creates the descriptor lazily the first time MetricsReporter
    // writes a point. "Never written" is a stronger signal of zero players
    // than a transient network error, so count it as 0 rather than bailing
    // (which would otherwise force the agent into the defensive note_active
    // branch and prevent idle accumulation indefinitely).
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(0);
    }
    if !resp.status().is_success() {
        anyhow::bail!("monitoring query returned {}", resp.status());
    }
    let body: serde_json::Value = resp.json().context("parse timeseries response")?;

    // Response shape: { "timeSeries": [{ "points": [{ "value": { "int64Value": "N" } }, ...] }] }
    let Some(series) = body["timeSeries"].as_array() else {
        return Ok(0);
    };
    let mut max = 0u32;
    for s in series {
        if let Some(points) = s["points"].as_array() {
            for p in points {
                if let Some(v) = p["value"]["int64Value"].as_str() {
                    max = max.max(v.parse().unwrap_or(0));
                }
            }
        }
    }
    Ok(max)
}

fn chrono_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn rfc3339(secs: i64) -> String {
    // 1970-01-01 + secs. Tiny implementation avoiding chrono dep.
    let dt = unix_to_components(secs);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        dt.0, dt.1, dt.2, dt.3, dt.4, dt.5
    )
}

fn unix_to_components(mut secs: i64) -> (i32, u32, u32, u32, u32, u32) {
    let sec = (secs % 60) as u32;
    secs /= 60;
    let min = (secs % 60) as u32;
    secs /= 60;
    let hour = (secs % 24) as u32;
    let mut days = secs / 24;
    let mut year = 1970i32;
    loop {
        let dy = if is_leap(year) { 366 } else { 365 };
        if days < dy {
            break;
        }
        days -= dy;
        year += 1;
    }
    let months: [u32; 12] = [31, if is_leap(year) { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut month = 1u32;
    let mut d = days as u32;
    for m in months {
        if d < m {
            break;
        }
        d -= m;
        month += 1;
    }
    (year, month, d + 1, hour, min, sec)
}

fn is_leap(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn urlencoding(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}
