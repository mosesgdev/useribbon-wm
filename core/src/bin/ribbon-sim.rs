//! Replay a JSON array of events; print one plan JSON per line.
//! Usage: ribbon-sim [--config config.json] [events.json]   (stdin if no file)

use std::io::Read;

use ribbon_core::engine::Engine;
use ribbon_core::model::{Config, Event};

fn main() {
    let mut args = std::env::args().skip(1);
    let (mut cfg_path, mut file) = (None, None);
    while let Some(a) = args.next() {
        if a == "--config" {
            cfg_path = args.next();
        } else {
            file = Some(a);
        }
    }
    let read = |p: &str| std::fs::read_to_string(p).unwrap_or_else(|e| die(&format!("{p}: {e}")));
    let cfg: Config = cfg_path.map_or_else(Config::default, |p| {
        serde_json::from_str(&read(&p)).unwrap_or_else(|e| die(&format!("config: {e}")))
    });
    let input = match file {
        Some(p) => read(&p),
        None => {
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s).unwrap_or_else(|e| die(&e.to_string()));
            s
        }
    };
    let events: Vec<Event> = serde_json::from_str(&input).unwrap_or_else(|e| die(&format!("events: {e}")));
    let mut engine = Engine::new(cfg);
    for ev in events {
        println!("{}", serde_json::to_string(&engine.handle(ev)).expect("plan serializes"));
    }
}

fn die(msg: &str) -> ! {
    eprintln!("ribbon-sim: {msg}");
    std::process::exit(2)
}
