use std::env;

pub struct Config {
    pub listen: String,
    pub mujina_api_url: String,
    pub log_path: String,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            listen: env::var("MUJINA_UI_LISTEN").unwrap_or_else(|_| "0.0.0.0:7782".into()),
            mujina_api_url: env::var("MUJINA_API_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:7785".into()),
            log_path: env::var("MUJINA_UI_LOG_PATH")
                .unwrap_or_else(|_| "/var/log/mujina-minerd.log".into()),
        }
    }
}
