//! Thin client for mujina's REST API.
//!
//! We pass through the JSON essentially as-is -- the UI's job is to
//! display whatever mujina's API exposes, not interpret it. We use
//! `serde_json::Value` rather than typed structs so that schema
//! evolution upstream (new fields, renamed structs) doesn't break the
//! UI -- the frontend just renders what arrives.

use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::Value;

/// Default per-request timeout — snappy, for the frequent GET /miner polls.
const DEFAULT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
/// Pause/resume timeout. A resume CYCLES THE PSU RAIL and re-inits the chains,
/// which takes ~10 s (and mujina allows the PATCH up to 300 s), far longer than
/// the poll timeout. Without a longer bound here the client gives up at 5 s and
/// the UI reports the resume "failed" even though it completes moments later.
const CONTROL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

pub struct Client {
    http: reqwest::Client,
    base: String,
}

impl Client {
    pub fn new(base: String) -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(DEFAULT_TIMEOUT)
                .build()
                .expect("reqwest builder"),
            base,
        }
    }

    pub async fn get_miner(&self) -> Result<Value> {
        let url = format!("{}/api/v0/miner", self.base);
        let r = self
            .http
            .get(&url)
            .send()
            .await
            .context("GET /miner failed")?
            .error_for_status()?;
        Ok(r.json().await?)
    }

    pub async fn set_paused(&self, paused: bool) -> Result<Value> {
        #[derive(Serialize)]
        struct Body {
            paused: bool,
        }
        let url = format!("{}/api/v0/miner", self.base);
        let r = self
            .http
            .patch(&url)
            // Override the short poll timeout — a resume can legitimately block
            // ~10 s (rail cycle + re-init) and must not be reported as failed.
            .timeout(CONTROL_TIMEOUT)
            .json(&Body { paused })
            .send()
            .await
            .context("PATCH /miner failed")?
            .error_for_status()?;
        Ok(r.json().await?)
    }
}
