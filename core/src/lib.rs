//! Ribbon core: a pure scrolling-layout engine behind a one-function C ABI.
//! Only this file contains `unsafe`.

pub mod engine;
pub mod layout;
pub mod model;

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use engine::Engine;
use model::{Config, Plan};

/// Opaque handle given to C.
pub struct RibbonEngine(Engine);

/// Parse leniently: every key falls back to its default on its own, so one bad value keeps the rest.
fn parse_config(json: &str) -> Config {
    let v: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
    let d = Config::default();
    let field = |k: &str| v.get(k).cloned();
    macro_rules! pick {
        ($k:literal, $d:expr) => {
            field($k).and_then(|x| serde_json::from_value(x).ok()).unwrap_or($d)
        };
    }
    Config {
        gap: pick!("gap", d.gap),
        outer_gap: pick!("outer_gap", d.outer_gap),
        default_width: pick!("default_width", d.default_width),
        width_presets: pick!("width_presets", d.width_presets),
        new_window: pick!("new_window", d.new_window),
        scroll: pick!("scroll", d.scroll),
        app_widths: pick!("app_widths", d.app_widths),
    }
}

fn to_c(plan: &Plan) -> *mut c_char {
    let json = serde_json::to_string(plan).unwrap_or_else(|_| {
        r#"{"frames":[],"focus":null,"changed":[],"map":{"columns":[],"viewport":{"start":0.0,"end":1.0},"focused_index":null},"show_map":false,"error":"serialize failed"}"#.into()
    });
    // JSON never contains raw NUL bytes (they are escaped), so this cannot fail.
    CString::new(json).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn panic_msg(p: Box<dyn std::any::Any + Send>) -> String {
    let m = p.downcast_ref::<&str>().map(|s| s.to_string()).or_else(|| p.downcast_ref::<String>().cloned());
    format!("internal panic: {}", m.unwrap_or_default())
}

/// Create an engine. NULL, empty or invalid `config_json` yields the default config.
///
/// # Safety
/// `config_json` must be NULL or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ribbon_engine_new(config_json: *const c_char) -> *mut RibbonEngine {
    let r = catch_unwind(|| {
        let cfg = if config_json.is_null() {
            Config::default()
        } else {
            CStr::from_ptr(config_json).to_str().map(parse_config).unwrap_or_default()
        };
        Box::into_raw(Box::new(RibbonEngine(Engine::new(cfg))))
    });
    r.unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `e` must be NULL or a pointer from `ribbon_engine_new` not yet freed.
#[no_mangle]
pub unsafe extern "C" fn ribbon_engine_free(e: *mut RibbonEngine) {
    if !e.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(e))));
    }
}

/// Handle one event; returns a Plan JSON string to release with `ribbon_string_free`.
/// Panics and bad input produce a plan with `error` set and no frames.
///
/// # Safety
/// `e` must be a live engine pointer and `event_json` a valid NUL-terminated string (or NULL).
#[no_mangle]
pub unsafe extern "C" fn ribbon_engine_handle(e: *mut RibbonEngine, event_json: *const c_char) -> *mut c_char {
    let plan = catch_unwind(AssertUnwindSafe(|| {
        if e.is_null() || event_json.is_null() {
            return Plan::error("null engine or event");
        }
        match CStr::from_ptr(event_json).to_str() {
            Ok(s) => (*e).0.handle_json(s),
            Err(_) => Plan::error("event is not valid UTF-8"),
        }
    }))
    .unwrap_or_else(|p| Plan::error(panic_msg(p)));
    to_c(&plan)
}

/// # Safety
/// `s` must be NULL or a string returned by `ribbon_engine_handle`, freed at most once.
#[no_mangle]
pub unsafe extern "C" fn ribbon_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// Which edition this core was built as: "plus" with the `plus` feature (pinning and the other Plus features), else "free".
/// The app checks it against its own edition, so a build never links a core of the other one.
#[no_mangle]
pub extern "C" fn ribbon_core_edition() -> *const c_char {
    let s: &'static CStr = if cfg!(feature = "plus") { c"plus" } else { c"free" };
    s.as_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edition_names_the_build() {
        let s = unsafe { CStr::from_ptr(ribbon_core_edition()) }.to_str().unwrap();
        assert_eq!(s, if cfg!(feature = "plus") { "plus" } else { "free" });
    }

    unsafe fn call(e: *mut RibbonEngine, json: &str) -> Plan {
        let c = CString::new(json).unwrap();
        let out = ribbon_engine_handle(e, c.as_ptr());
        let plan = serde_json::from_str(CStr::from_ptr(out).to_str().unwrap()).unwrap();
        ribbon_string_free(out);
        plan
    }

    #[test]
    fn ffi_roundtrip_and_errors() {
        unsafe {
            let e = ribbon_engine_new(std::ptr::null());
            assert!(!e.is_null());
            let p = call(e, r#"{"type":"display","id":1,"frame":{"x":0,"y":0,"w":1000,"h":800}}"#);
            assert!(p.error.is_none());
            let p = call(e, r#"{"type":"window_added","id":7,"pid":1,"app":"A","title":"t","frame":{"x":0,"y":0,"w":1,"h":1},"floating":false}"#);
            assert_eq!(p.frames.len(), 1);
            assert_eq!(p.focus, Some(7));
            let p = call(e, "not json");
            assert!(p.error.is_some() && p.frames.is_empty());
            let p = call(std::ptr::null_mut(), r#"{"type":"query"}"#);
            assert!(p.error.is_some());
            ribbon_engine_free(e);
            let cfg = CString::new(r#"{"gap": 4"#).unwrap(); // invalid -> defaults
            let e = ribbon_engine_new(cfg.as_ptr());
            assert!(!e.is_null());
            ribbon_engine_free(e);
        }
    }

    #[test]
    fn config_parses_per_field() {
        let c = parse_config(r#"{"gap": 4, "scroll": "Center", "outer_gap": "x", "default_width": 0.667}"#);
        assert_eq!((c.gap, c.outer_gap, c.default_width), (4.0, 12.0, 0.667));
        assert_eq!(c.scroll, model::ScrollMode::KeepVisible);
        assert_eq!(parse_config("[1]"), Config::default());
        assert_eq!(parse_config(r#"{"gap": 4"#), Config::default());
    }

    #[test]
    fn panic_message_is_reported() {
        let r = catch_unwind(|| panic!("boom")).unwrap_err();
        assert_eq!(panic_msg(r), "internal panic: boom");
    }
}
