/// BLiveManager

use serde::{Deserialize, Serialize};
use crate::core::biliapi::{self, LiveClient, StartLiveResult};
use crate::core::error::AppError;
use crate::log;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum LiveMode {
    #[serde(rename = "auto")] Auto,
    #[serde(rename = "manual")] Manual,
}

impl Default for LiveMode { fn default() -> Self { Self::Auto } }

impl std::str::FromStr for LiveMode {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "auto" => Ok(Self::Auto),
            "manual" => Ok(Self::Manual),
            _ => Err(format!("Invalid live_mode: '{}'", s)),
        }
    }
}

/// 单发 startLive 的结果分类
pub enum StartOutcome {
    Started { rtmp_url: String, stream_key: String, client: LiveClient },
    AuthRequired { face_auth_url: Option<String> },
    Failed { code: i64, message: String },
}

/// 打一发 startLive(electron 优先, 失败 fallback livehime), 按结果分类返回。
/// 单发: 60024/60043 只报 AuthRequired, 重试由状态机 + 人脸 watcher 驱动。
pub async fn try_start_live(cookie: &str, room_id: u64, area_v2: &str, title: Option<&str>) -> StartOutcome {
    let client = match create_http_client(cookie) {
        Ok(c) => c,
        Err(e) => { log!(error, "Bili:Live: {}", e); return StartOutcome::Failed { code: -1, message: e.to_string() }; }
    };
    let csrf = match parse_cookies(cookie) {
        Ok((_, c)) => c,
        Err(e) => return StartOutcome::Failed { code: -1, message: e.to_string() },
    };
    let uid = get_uid(cookie);

    // electron 优先 -> 失败 fallback livehime; 60024/60043(人脸)交状态机, 不 fallback
    let mut chosen = LiveClient::Electron;
    let mut result = biliapi::start_live_electron(&client, cookie, &csrf, uid.as_deref(), room_id, area_v2, title).await;
    let need_fallback = match &result {
        Ok(StartLiveResult::Success { .. }) => false,
        Ok(StartLiveResult::Failed { code, .. }) if *code == 60024 || *code == 60043 => false,
        _ => true,
    };
    if need_fallback {
        match &result {
            Ok(StartLiveResult::Failed { code, message, .. }) =>
                log!(warn, "Bili:Live: {} - Electron 失败, fallback Livehime", AppError::bili_api("StartLive", *code as i64, message.clone())),
            Err(e) => log!(warn, "Bili:Live: Electron error - {} - fallback Livehime", e),
            _ => {}
        }
        chosen = LiveClient::Livehime;
        result = biliapi::start_live_livehime(&client, cookie, &csrf, uid.as_deref(), room_id, area_v2, title).await;
    }

    match result {
        Ok(StartLiveResult::Success { rtmp_url, stream_key }) =>
            StartOutcome::Started { rtmp_url, stream_key, client: chosen },
        Ok(StartLiveResult::Failed { code, message: _, face_auth_url }) if code == 60043 || code == 60024 => {
            print_auth_info(code, &face_auth_url);
            StartOutcome::AuthRequired { face_auth_url }
        }
        Ok(StartLiveResult::Failed { code, message, face_auth_url: _ }) => {
            log!(error, "Bili:Live: {}", AppError::bili_api("StartLive", code as i64, message.clone()));
            StartOutcome::Failed { code: code as i64, message }
        }
        Err(e) => {
            log!(error, "Bili:Live: StartLive error - {}", e);
            let (code, message) = parse_api_error(&e.to_string());
            StartOutcome::Failed { code, message }
        }
    }
}

/// 关播。按开播时的 client 配对(electron 纯 csrf / livehime 签名)。Ok = 成功; Err((code, message)) = 失败
pub async fn try_stop_live(cookie: &str, room_id: u64, client_id: LiveClient) -> Result<(), (i64, String)> {
    let client = match create_http_client(cookie) {
        Ok(c) => c,
        Err(e) => { log!(error, "Bili:Live: {}", e); return Err((-1, e.to_string())); }
    };
    let csrf = match parse_cookies(cookie) {
        Ok((_, c)) => c,
        Err(e) => return Err((-1, e.to_string())),
    };
    let result = match client_id {
        LiveClient::Electron => biliapi::stop_live_electron(&client, cookie, &csrf, room_id).await,
        LiveClient::Livehime => biliapi::stop_live_livehime(&client, cookie, &csrf, room_id).await,
    };
    match result {
        Ok(_) => Ok(()),
        Err(e) => {
            log!(error, "Bili:Live: StopLive error - {}", e);
            Err(parse_api_error(&e.to_string()))
        }
    }
}

// ── 基础设施 ──

fn create_http_client(cookie: &str) -> Result<reqwest::Client, AppError> {
    let _ = parse_cookies(cookie)?; // 校验 cookie 完整; Cookie 由 biliapi::client_headers 手动注入
    Ok(reqwest::Client::builder().build()?)
}

fn parse_cookies(cookie: &str) -> Result<(String, String), AppError> {
    let mut sessdata = String::new();
    let mut bili_jct = String::new();
    for pair in cookie.split(';') {
        if let Some((k, v)) = pair.trim().split_once('=') {
            match k.trim() { "SESSDATA" => sessdata = v.trim().into(), "bili_jct" => bili_jct = v.trim().into(), _ => {} }
        }
    }
    if sessdata.is_empty() || bili_jct.is_empty() { Err("Missing SESSDATA or bili_jct".into()) } else { Ok((sessdata, bili_jct)) }
}

fn get_uid(cookie: &str) -> Option<String> {
    cookie.split(';').filter_map(|p| p.trim().split_once('='))
        .find(|(k, _)| k.trim() == "DedeUserID")
        .map(|(_, v)| v.trim().to_string())
}

fn parse_api_error(err: &str) -> (i64, String) {
    if let Some(pos) = err.find("BiliAPI (") {
        let rest = &err[pos + 8..];
        if let Some(comma) = rest.find(',')
            && let Ok(code) = rest[..comma].parse::<i64>()
        {
            let msg = rest.find(" — ").map(|p| &rest[p + 3..]).unwrap_or(rest);
            return (code, msg.to_string());
        }
    }
    (-1, err.to_string())
}

fn print_auth_info(code: i32, face_auth_url: &Option<String>) {
    if let Some(url) = face_auth_url {
        crate::luci::set("qr_url", url);
        log!(warn, "Bili:Live: {}", AppError::bili_api("StartLive", code as i64, crate::core::error::start_live_error(code as i64, "需要验证")));
        eprintln!("  人脸验证链接: {}", url);
        eprintln!("  验证完成后自动开播");
        #[cfg(feature = "cli")]
        { print_face_auth_qrcode(url); }
    }
}

/// 打印人脸验证二维码到终端
#[cfg(feature = "cli")]
fn print_face_auth_qrcode(url: &str) {
    use qrcode::QrCode;
    match QrCode::new(url) {
        Ok(code) => {
            let image = code.render::<qrcode::render::unicode::Dense1x2>()
                .dark_color(qrcode::render::unicode::Dense1x2::Light)
                .light_color(qrcode::render::unicode::Dense1x2::Dark).build();
            println!("\n人脸验证二维码:\n{}", image);
        }
        Err(e) => { log!(warn, "Bili:Live: 二维码生成失败: {}", e); }
    }
}
