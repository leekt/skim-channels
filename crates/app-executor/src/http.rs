//! A minimal HTTP/1.1 JSON-RPC server (POST, keep-alive, batches): one thread per
//! connection, one executor behind a lock, so execution is serialized.

use std::{
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, Mutex},
};

use serde_json::{Value, json};

use crate::{exec::Executor, rpc::dispatch};

pub fn serve(listener: TcpListener, ex: Arc<Mutex<Executor>>) {
    for stream in listener.incoming().flatten() {
        let ex = ex.clone();
        std::thread::spawn(move || {
            let _ = connection(stream, &ex);
        });
    }
}

fn connection(stream: TcpStream, ex: &Mutex<Executor>) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut out = stream;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Ok(());
        }
        let post = line.starts_with("POST");
        let mut len = 0usize;
        loop {
            let mut h = String::new();
            if reader.read_line(&mut h)? == 0 {
                return Ok(());
            }
            let h = h.trim_end();
            if h.is_empty() {
                break;
            }
            if let Some((k, v)) = h.split_once(':')
                && k.eq_ignore_ascii_case("content-length")
            {
                len = v.trim().parse().unwrap_or(0);
            }
        }
        let mut body = vec![0u8; len];
        reader.read_exact(&mut body)?;
        let reply = if post {
            handle(&body, ex)
        } else {
            json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32600, "message": "POST JSON-RPC"}})
        };
        let bytes = serde_json::to_vec(&reply).unwrap_or_default();
        write!(
            out,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: keep-alive\r\n\r\n",
            bytes.len()
        )?;
        out.write_all(&bytes)?;
    }
}

fn handle(body: &[u8], ex: &Mutex<Executor>) -> Value {
    let Ok(req) = serde_json::from_slice::<Value>(body) else {
        return json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "parse error"}});
    };
    match req {
        Value::Array(calls) => Value::Array(calls.iter().map(|c| one(c, ex)).collect()),
        c => one(&c, ex),
    }
}

fn one(c: &Value, ex: &Mutex<Executor>) -> Value {
    let id = c.get("id").cloned().unwrap_or(Value::Null);
    let method = c.get("method").and_then(|m| m.as_str()).unwrap_or_default();
    let params = c.get("params").cloned().unwrap_or(json!([]));
    let mut ex = ex.lock().unwrap_or_else(|p| p.into_inner());
    match dispatch(&mut ex, method, &params) {
        Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
        Err(e) => {
            let mut err = json!({"code": e.code, "message": e.message});
            if let Some(d) = e.data {
                err["data"] = d;
            }
            json!({"jsonrpc": "2.0", "id": id, "error": err})
        }
    }
}
