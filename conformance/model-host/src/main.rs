use anyhow::{Context, Result, anyhow, bail};
use std::path::PathBuf;
use wasmtime::component::{Component, HasSelf, Linker};
use wasmtime::{Config, Engine, Store};

wasmtime::component::bindgen!({
    path: "../../sdk/wit",
    world: "module",
});

#[derive(Default)]
struct ModelHost {
    log_codes: Vec<i32>,
    trace: Vec<&'static str>,
    light: bool,
}

impl vrweb::core::host::Host for ModelHost {
    fn log_code(&mut self, code: i32) {
        self.log_codes.push(code);
    }

    fn report_error(&mut self, _message: String) {}
}

impl vrweb::scene::host::Host for ModelHost {
    fn query(&mut self, _target: u64, request: Vec<u8>) -> Result<Vec<u8>, String> {
        self.trace.push("scene.query");
        if request == br#"{"op":"root"}"# {
            Ok(b"1".to_vec())
        } else {
            Err("unsupported model query".into())
        }
    }

    fn mutate(&mut self, _transaction: u64, _command: Vec<u8>) -> Result<(), String> {
        self.trace.push("scene.mutate");
        Ok(())
    }

    fn commit(&mut self, _transaction: u64) -> Result<Vec<u8>, String> {
        self.trace.push("scene.commit");
        Ok(br#"{"applied":1,"created":{}}"#.to_vec())
    }

    fn call(
        &mut self,
        _target: u64,
        _method: String,
        _args: Vec<Vec<u8>>,
    ) -> Result<Vec<u8>, String> {
        Err("scene.call is outside this fixture".into())
    }

    fn subscribe(&mut self, _target: u64, _signal: String) -> Result<u64, String> {
        Err("scene.subscribe is outside this fixture".into())
    }

    fn unsubscribe(&mut self, _subscription: u64) {}
}

impl vrweb::state::host::Host for ModelHost {
    fn read(&mut self, key: String) -> Result<Vec<u8>, String> {
        self.trace.push("state.read");
        if key == "light" {
            Ok(if self.light { b"true".as_slice() } else { b"false".as_slice() }.to_vec())
        } else {
            Err("unknown state key".into())
        }
    }

    fn command(&mut self, request: Vec<u8>) -> Result<(), String> {
        self.trace.push("state.command");
        if request == br#"{"key":"light","command":"set","value":true}"# {
            self.light = true;
            Ok(())
        } else {
            Err("unsupported model command".into())
        }
    }

    fn subscribe(&mut self, _key: String) -> Result<u64, String> {
        Err("state.subscribe is outside this fixture".into())
    }

    fn unsubscribe(&mut self, _subscription: u64) {}
}

impl vrweb::assets::host::Host for ModelHost {
    fn lookup(&mut self, _name: String) -> Result<Vec<u8>, String> {
        Err("assets are outside this fixture".into())
    }
}

impl vrweb::timers::host::Host for ModelHost {
    fn start(&mut self, _delay_ms: u32, _repeat: bool) -> Result<u64, String> {
        Err("timers are outside this fixture".into())
    }

    fn cancel(&mut self, _timer: u64) {}
}

impl vrweb::input::host::Host for ModelHost {
    fn enable(&mut self, _kind: String, _enabled: bool) -> Result<(), String> {
        Err("input is outside this fixture".into())
    }
}

impl vrweb::features::host::Host for ModelHost {
    fn has(&mut self, capability: String) -> bool {
        matches!(capability.as_str(), "scene" | "state")
    }
}

impl vrweb::log::host::Host for ModelHost {
    fn write(&mut self, _request: Vec<u8>) -> Result<(), String> {
        Ok(())
    }
}

fn main() -> Result<()> {
    let mut arguments = std::env::args_os().skip(1);
    let component_path = arguments
        .next()
        .map(PathBuf::from)
        .context("usage: vrweb-model-host <component.wasm> <expected.json>")?;
    let expected_path = arguments
        .next()
        .map(PathBuf::from)
        .context("usage: vrweb-model-host <component.wasm> <expected.json>")?;
    if arguments.next().is_some() {
        bail!("usage: vrweb-model-host <component.wasm> <expected.json>");
    }
    let expected: serde_json::Value = serde_json::from_slice(
        &std::fs::read(&expected_path)
            .with_context(|| format!("cannot read {}", expected_path.display()))?,
    )?;
    let expected_logs: Vec<i32> = serde_json::from_value(expected["log_codes"].clone())?;
    let expected_trace: Vec<String> = serde_json::from_value(expected["host_trace"].clone())?;

    let mut config = Config::new();
    config.wasm_component_model(true);
    let engine = Engine::new(&config).map_err(|error| anyhow!(error.to_string()))?;
    let component = Component::from_file(&engine, &component_path)
        .map_err(|error| anyhow!(error.to_string()))
        .with_context(|| format!("cannot load {}", component_path.display()))?;
    let mut linker = Linker::new(&engine);
    Module::add_to_linker::<_, HasSelf<_>>(&mut linker, |host| host)
        .map_err(|error| anyhow!(error.to_string()))?;
    let mut store = Store::new(&engine, ModelHost::default());
    let bindings = Module::instantiate(&mut store, &component, &linker)
        .map_err(|error| anyhow!(error.to_string()))?;

    let instance = bindings.call_create(&mut store)
        .map_err(|error| anyhow!(error.to_string()))?;
    if bindings.call_mount(&mut store, instance)
        .map_err(|error| anyhow!(error.to_string()))? != 0
        || bindings.call_event(&mut store, instance, br#"{"type":"test"}"#)
            .map_err(|error| anyhow!(error.to_string()))? != 0
        || bindings.call_unmount(&mut store, instance)
            .map_err(|error| anyhow!(error.to_string()))? != 0
    {
        bail!("guest lifecycle returned a non-zero status");
    }

    let host = store.data();
    if host.log_codes != expected_logs {
        bail!("log trace mismatch: {:?}", host.log_codes);
    }
    if host.trace != expected_trace {
        bail!("host trace mismatch: {:?}", host.trace);
    }
    println!("vrweb model host: PASS logs={:?} trace={:?}", host.log_codes, host.trace);
    Ok(())
}
