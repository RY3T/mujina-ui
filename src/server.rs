//! HTTP server: static index + JSON proxy + SSE log stream + commands.

use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures::stream::Stream;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio_stream::StreamExt;
use tokio_stream::wrappers::ReceiverStream;

use crate::config::Config;
use crate::logs;
use crate::mujina::Client as Mujina;

const INDEX_HTML: &str = include_str!("../assets/index.html");

#[derive(Clone)]
pub struct AppState {
    pub mujina: Arc<Mujina>,
    pub cfg: Arc<Config>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/api/state", get(get_state))
        .route("/api/info", get(get_info))
        .route("/api/control/pause", post(pause))
        .route("/api/control/resume", post(resume))
        .route("/api/logs", get(stream_logs))
        .with_state(state)
}

async fn index() -> Response {
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        "text/html; charset=utf-8".parse().unwrap(),
    );
    (StatusCode::OK, headers, INDEX_HTML).into_response()
}

/// Aggregated snapshot the UI polls. We return whatever mujina sends
/// back wrapped in a thin envelope that distinguishes "mujina is
/// reachable" from "mujina returned this state."
async fn get_state(State(s): State<AppState>) -> Json<Value> {
    match s.mujina.get_miner().await {
        Ok(snapshot) => Json(json!({
            "ok": true,
            "snapshot": snapshot,
        })),
        Err(e) => Json(json!({
            "ok": false,
            "error": e.to_string(),
        })),
    }
}

/// Static info about *this* UI instance -- so the frontend can show
/// what mujina URL it's proxying to and where the log file lives.
async fn get_info(State(s): State<AppState>) -> Json<Value> {
    Json(json!({
        "mujina_api_url": s.cfg.mujina_api_url,
        "log_path": s.cfg.log_path,
        "version": env!("MUJINA_UI_VERSION"),
    }))
}

#[derive(Deserialize, Default)]
struct EmptyBody {}

async fn pause(State(s): State<AppState>, _body: Option<Json<EmptyBody>>) -> Json<Value> {
    set_paused(&s, true).await
}

async fn resume(State(s): State<AppState>, _body: Option<Json<EmptyBody>>) -> Json<Value> {
    set_paused(&s, false).await
}

async fn set_paused(s: &AppState, paused: bool) -> Json<Value> {
    match s.mujina.set_paused(paused).await {
        Ok(v) => Json(json!({ "ok": true, "snapshot": v })),
        Err(e) => Json(json!({ "ok": false, "error": e.to_string() })),
    }
}

/// Server-Sent Events endpoint that backfills the tail of the log file
/// and then streams newly-appended lines as they're written.
async fn stream_logs(
    State(s): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let rx = logs::spawn(&s.cfg.log_path);
    let stream = ReceiverStream::new(rx).map(|line| Ok(Event::default().data(line)));
    Sse::new(stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("keepalive"),
    )
}
