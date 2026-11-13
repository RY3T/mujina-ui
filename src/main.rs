mod config;
mod logs;
mod mujina;
mod server;

use std::sync::Arc;

use anyhow::Result;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let cfg = Arc::new(config::Config::from_env());
    tracing::info!(
        version = env!("MUJINA_UI_VERSION"),
        listen = %cfg.listen,
        api = %cfg.mujina_api_url,
        log_path = %cfg.log_path,
        "starting mujina-ui"
    );

    let state = server::AppState {
        mujina: Arc::new(mujina::Client::new(cfg.mujina_api_url.clone())),
        cfg: cfg.clone(),
    };
    let app = server::router(state);

    let listener = TcpListener::bind(&cfg.listen).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
