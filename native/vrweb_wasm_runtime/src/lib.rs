use std::collections::HashMap;
use std::fs;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use wasmtime::component::{Component, Instance, Linker, Val};
use wasmtime::{Config, Engine, Store, StoreLimits, StoreLimitsBuilder};

const RUNTIME_VERSION: &str = "wasmtime-46.0.1";
const DEFAULT_FUEL: u64 = 1_000_000;
const MAX_FUEL: u64 = 50_000_000;
const MAX_MEMORY_BYTES: usize = 16 * 1024 * 1024;
const MAX_TABLE_ELEMENTS: usize = 10_000;
const EPOCH_TICK_MS: u64 = 10;
const CALL_DEADLINE_TICKS: u64 = 5;
const MAX_HOST_CALLS: u32 = 64;
const MAX_GUEST_ERROR_BYTES: usize = 8 * 1024;

struct HostState {
    limits: StoreLimits,
    log_codes: Vec<i32>,
    guest_error: Option<String>,
    host_calls: u32,
    max_host_calls: u32,
    fuel: u64,
    deadline_ticks: u64,
    host_callback: Option<Callable>,
}

#[derive(Clone, Copy)]
struct RuntimeLimits {
    fuel: u64,
    memory_bytes: usize,
    deadline_ticks: u64,
    host_calls: u32,
    instances: usize,
    tables: usize,
    memories: usize,
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            fuel: DEFAULT_FUEL,
            memory_bytes: MAX_MEMORY_BYTES,
            deadline_ticks: CALL_DEADLINE_TICKS,
            host_calls: MAX_HOST_CALLS,
            instances: 16,
            tables: 16,
            memories: 8,
        }
    }
}

impl RuntimeLimits {
    fn bounded(
        fuel: i64,
        memory_bytes: i64,
        deadline_ms: i64,
        host_calls: i64,
        instances: i64,
        tables: i64,
        memories: i64,
    ) -> wasmtime::Result<Self> {
        fn value(name: &str, requested: i64, maximum: u64) -> wasmtime::Result<u64> {
            let requested = u64::try_from(requested)
                .map_err(|_| wasmtime::Error::msg(format!("{name} limit must be positive")))?;
            if requested == 0 || requested > maximum {
                return Err(wasmtime::Error::msg(format!(
                    "{name} limit must be between 1 and {maximum}"
                )));
            }
            Ok(requested)
        }

        let deadline_ms = value(
            "deadline_ms",
            deadline_ms,
            EPOCH_TICK_MS * CALL_DEADLINE_TICKS,
        )?;
        Ok(Self {
            fuel: value("fuel", fuel, MAX_FUEL)?,
            memory_bytes: value("memory_bytes", memory_bytes, MAX_MEMORY_BYTES as u64)? as usize,
            deadline_ticks: deadline_ms.div_ceil(EPOCH_TICK_MS),
            host_calls: value("host_calls", host_calls, MAX_HOST_CALLS as u64)? as u32,
            instances: value("instances", instances, 16)? as usize,
            tables: value("tables", tables, 16)? as usize,
            memories: value("memories", memories, 8)? as usize,
        })
    }
}

struct GuestInstance {
    module_id: String,
    guest_id: i32,
    store: Store<HostState>,
    instance: Instance,
    mounted: bool,
}

#[derive(GodotClass)]
#[class(base = RefCounted)]
struct VrwebWasmRuntime {
    base: Base<RefCounted>,
    engine: Option<Engine>,
    components: HashMap<String, Component>,
    instances: HashMap<String, GuestInstance>,
    completed_logs: HashMap<String, Vec<i32>>,
    last_error: String,
    live_stores: i64,
    epoch_stop: Arc<AtomicBool>,
    epoch_thread: Option<JoinHandle<()>>,
}

#[godot_api]
impl IRefCounted for VrwebWasmRuntime {
    fn init(base: Base<RefCounted>) -> Self {
        let mut config = Config::new();
        config.wasm_component_model(true);
        config.consume_fuel(true);
        config.epoch_interruption(true);
        let (engine, last_error) = match Engine::new(&config) {
            Ok(engine) => (Some(engine), String::new()),
            Err(error) => (None, format!("failed to initialize Wasmtime: {error:#}")),
        };
        let epoch_stop = Arc::new(AtomicBool::new(false));
        let epoch_thread = engine.as_ref().map(|engine| {
            let engine = engine.clone();
            let stop = epoch_stop.clone();
            thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    thread::sleep(Duration::from_millis(EPOCH_TICK_MS));
                    engine.increment_epoch();
                }
            })
        });
        Self {
            base,
            engine,
            components: HashMap::new(),
            instances: HashMap::new(),
            completed_logs: HashMap::new(),
            last_error,
            live_stores: 0,
            epoch_stop,
            epoch_thread,
        }
    }
}

#[godot_api]
impl VrwebWasmRuntime {
    #[func]
    fn is_available(&self) -> bool {
        self.engine.is_some()
    }

    #[func]
    fn runtime_version(&self) -> GString {
        RUNTIME_VERSION.into()
    }

    #[func]
    fn get_last_error(&self) -> GString {
        self.last_error.as_str().into()
    }

    #[func]
    fn component_count(&self) -> i64 {
        self.components.len() as i64
    }

    #[func]
    fn component_imports(&self, module_id: GString) -> PackedStringArray {
        let mut result = PackedStringArray::new();
        let Some(engine) = self.engine.as_ref() else {
            return result;
        };
        let Some(component) = self.components.get(&module_id.to_string()) else {
            return result;
        };
        for (name, _) in component.component_type().imports(engine) {
            let value = GString::from(name);
            result.push(&value);
        }
        result
    }

    #[func]
    fn component_exports(&self, module_id: GString) -> PackedStringArray {
        let mut result = PackedStringArray::new();
        let Some(engine) = self.engine.as_ref() else {
            return result;
        };
        let Some(component) = self.components.get(&module_id.to_string()) else {
            return result;
        };
        for (name, _) in component.component_type().exports(engine) {
            let value = GString::from(name);
            result.push(&value);
        }
        result
    }

    #[func]
    fn live_store_count(&self) -> i64 {
        self.live_stores + self.instances.len() as i64
    }

    #[func]
    fn prepare_component(&mut self, module_id: GString, absolute_path: GString) -> bool {
        self.last_error.clear();
        let Some(engine) = self.engine.as_ref() else {
            self.last_error = "Wasmtime engine unavailable".to_string();
            return false;
        };
        let module_id = module_id.to_string();
        if module_id.is_empty() {
            self.last_error = "module id is empty".to_string();
            return false;
        }
        let bytes = match fs::read(absolute_path.to_string()) {
            Ok(bytes) => bytes,
            Err(error) => {
                self.last_error = format!("failed to read component: {error}");
                return false;
            }
        };
        match Component::new(engine, bytes) {
            Ok(component) => {
                self.components.insert(module_id, component);
                true
            }
            Err(error) => {
                self.last_error = format!("invalid WebAssembly component: {error:#}");
                false
            }
        }
    }

    #[func]
    fn promote_component(&mut self, candidate_id: GString, module_id: GString) -> bool {
        self.last_error.clear();
        let candidate_id = candidate_id.to_string();
        let module_id = module_id.to_string();
        let Some(component) = self.components.remove(&candidate_id) else {
            self.last_error = "reload candidate component was not prepared".to_string();
            return false;
        };
        self.components.insert(module_id, component);
        true
    }

    #[func]
    fn drop_component(&mut self, module_id: GString) -> bool {
        let module_id = module_id.to_string();
        let instance_ids: Vec<String> = self
            .instances
            .iter()
            .filter(|(_, instance)| instance.module_id == module_id)
            .map(|(id, _)| id.clone())
            .collect();
        for instance_id in instance_ids {
            self.unmount_instance(GString::from(&instance_id));
        }
        self.components.remove(&module_id).is_some()
    }

    #[func]
    fn clear_components(&mut self) {
        let instance_ids: Vec<String> = self.instances.keys().cloned().collect();
        for instance_id in instance_ids {
            self.unmount_instance(GString::from(&instance_id));
        }
        self.components.clear();
        self.completed_logs.clear();
    }

    #[func]
    fn instantiate_lifecycle(&mut self, module_id: GString, instance_id: GString) -> bool {
        self.instantiate_lifecycle_internal(module_id, instance_id, None, RuntimeLimits::default())
    }

    #[func]
    fn instantiate_lifecycle_with_host(
        &mut self,
        module_id: GString,
        instance_id: GString,
        host_callback: Callable,
    ) -> bool {
        self.instantiate_lifecycle_internal(
            module_id,
            instance_id,
            Some(host_callback),
            RuntimeLimits::default(),
        )
    }

    #[func]
    #[allow(clippy::too_many_arguments)]
    fn instantiate_lifecycle_with_host_limits(
        &mut self,
        module_id: GString,
        instance_id: GString,
        host_callback: Callable,
        fuel: i64,
        memory_bytes: i64,
        deadline_ms: i64,
        host_calls: i64,
        instances: i64,
        tables: i64,
        memories: i64,
    ) -> bool {
        self.last_error.clear();
        let limits = match RuntimeLimits::bounded(
            fuel,
            memory_bytes,
            deadline_ms,
            host_calls,
            instances,
            tables,
            memories,
        ) {
            Ok(limits) => limits,
            Err(error) => {
                self.last_error = format!("invalid runtime limits: {error}");
                return false;
            }
        };
        self.instantiate_lifecycle_internal(module_id, instance_id, Some(host_callback), limits)
    }

    fn instantiate_lifecycle_internal(
        &mut self,
        module_id: GString,
        instance_id: GString,
        host_callback: Option<Callable>,
        limits: RuntimeLimits,
    ) -> bool {
        self.last_error.clear();
        let module_id = module_id.to_string();
        let instance_id = instance_id.to_string();
        if self.instances.contains_key(&instance_id) {
            self.last_error = "duplicate lifecycle instance id".to_string();
            return false;
        }
        self.completed_logs.remove(&instance_id);
        let Some(engine) = self.engine.as_ref() else {
            self.last_error = "Wasmtime engine unavailable".to_string();
            return false;
        };
        let Some(component) = self.components.get(&module_id) else {
            self.last_error = "module is not prepared".to_string();
            return false;
        };
        let result = (|| -> wasmtime::Result<GuestInstance> {
            let mut linker = Linker::<HostState>::new(engine);
            let mut core = linker.instance("vrweb:core/host@1.0.0")?;
            core.func_wrap("log-code", |mut store, (code,): (i32,)| {
                let state = store.data_mut();
                state.host_calls += 1;
                if state.host_calls > state.max_host_calls {
                    return Err(wasmtime::Error::msg("host call budget exceeded"));
                }
                state.log_codes.push(code);
                Ok(())
            })?;
            core.func_wrap("report-error", |mut store, (message,): (String,)| {
                let state = store.data_mut();
                state.host_calls += 1;
                if state.host_calls > state.max_host_calls {
                    return Err(wasmtime::Error::msg("host call budget exceeded"));
                }
                let mut end = message.len().min(MAX_GUEST_ERROR_BYTES);
                while !message.is_char_boundary(end) {
                    end -= 1;
                }
                state.guest_error = Some(message[..end].to_string());
                Ok(())
            })?;
            Self::link_scene_host(&mut linker)?;
            Self::link_portable_hosts(&mut linker)?;
            let mut store = Self::new_store(engine, host_callback, limits)?;
            let instance = linker.instantiate(&mut store, component)?;
            let guest_id = Self::call_s32(&instance, &mut store, "create", &[])?;
            let status = Self::call_s32(&instance, &mut store, "mount", &[Val::S32(guest_id)])?;
            if status != 0 {
                return Err(wasmtime::Error::msg("mount returned non-zero status"));
            }
            Ok(GuestInstance {
                module_id,
                guest_id,
                store,
                instance,
                mounted: true,
            })
        })();
        match result {
            Ok(instance) => {
                self.instances.insert(instance_id, instance);
                true
            }
            Err(error) => {
                self.last_error = format!("lifecycle instantiation failed: {error:#}");
                false
            }
        }
    }

    #[func]
    fn deliver_event_code(&mut self, instance_id: GString, code: i32) -> bool {
        self.deliver_event_value(instance_id, Val::S32(code))
    }

    #[func]
    fn deliver_event_bytes(&mut self, instance_id: GString, envelope: PackedByteArray) -> bool {
        if envelope.len() > MAX_MEMORY_BYTES {
            self.last_error = "event envelope exceeds memory limit".to_string();
            return false;
        }
        let value = Val::List(envelope.as_slice().iter().copied().map(Val::U8).collect());
        self.deliver_event_value(instance_id, value)
    }

    fn deliver_event_value(&mut self, instance_id: GString, value: Val) -> bool {
        self.last_error.clear();
        let Some(instance) = self.instances.get_mut(&instance_id.to_string()) else {
            self.last_error = "lifecycle instance not found".to_string();
            return false;
        };
        if !instance.mounted {
            self.last_error = "lifecycle instance is stopped".to_string();
            return false;
        }
        instance.store.data_mut().guest_error = None;
        let result = Self::call_s32(
            &instance.instance,
            &mut instance.store,
            "event",
            &[Val::S32(instance.guest_id), value],
        );
        match result {
            Ok(0) => true,
            Ok(_) => {
                instance.mounted = false;
                self.last_error = "event returned non-zero status".to_string();
                false
            }
            Err(error) => {
                instance.mounted = false;
                let guest_error = instance.store.data().guest_error.as_deref().unwrap_or("");
                self.last_error = if guest_error.is_empty() {
                    format!("event failed: {error:#}")
                } else {
                    format!("event failed: {guest_error}\n{error:#}")
                };
                false
            }
        }
    }

    #[func]
    fn unmount_instance(&mut self, instance_id: GString) -> bool {
        self.last_error.clear();
        let instance_id = instance_id.to_string();
        let Some(mut instance) = self.instances.remove(&instance_id) else {
            return false;
        };
        if !instance.mounted {
            self.completed_logs
                .insert(instance_id, instance.store.data().log_codes.clone());
            return true;
        }
        instance.mounted = false;
        let result = match Self::call_s32(
            &instance.instance,
            &mut instance.store,
            "unmount",
            &[Val::S32(instance.guest_id)],
        ) {
            Ok(0) => true,
            Ok(_) => {
                self.last_error = "unmount returned non-zero status".to_string();
                false
            }
            Err(error) => {
                self.last_error = format!("unmount failed: {error:#}");
                false
            }
        };
        self.completed_logs
            .insert(instance_id, instance.store.data().log_codes.clone());
        result
    }

    #[func]
    fn instance_log_codes(&self, instance_id: GString) -> PackedInt32Array {
        let mut result = PackedInt32Array::new();
        let instance_id = instance_id.to_string();
        if let Some(instance) = self.instances.get(&instance_id) {
            for code in &instance.store.data().log_codes {
                result.push(*code);
            }
        } else if let Some(codes) = self.completed_logs.get(&instance_id) {
            for code in codes {
                result.push(*code);
            }
        }
        result
    }

    #[func]
    fn call_i32(&mut self, module_id: GString, export_name: GString) -> i64 {
        self.last_error.clear();
        let Some(engine) = self.engine.as_ref() else {
            self.last_error = "Wasmtime engine unavailable".to_string();
            return 0;
        };
        let Some(component) = self.components.get(&module_id.to_string()) else {
            self.last_error = "module is not prepared".to_string();
            return 0;
        };

        self.live_stores += 1;
        let result = (|| -> wasmtime::Result<i32> {
            let linker = Linker::<HostState>::new(engine);
            let mut store = Self::new_store(engine, None, RuntimeLimits::default())?;
            let instance = linker.instantiate(&mut store, component)?;
            let function = instance
                .get_func(&mut store, &export_name.to_string())
                .ok_or_else(|| wasmtime::Error::msg("component export not found"))?;
            let mut results = [Val::S32(0)];
            function.call(&mut store, &[], &mut results)?;
            match results[0] {
                Val::S32(value) => Ok(value),
                _ => Err(wasmtime::Error::msg("component export must return s32")),
            }
        })();
        self.live_stores -= 1;

        match result {
            Ok(value) => i64::from(value),
            Err(error) => {
                self.last_error = format!("component call failed: {error:#}");
                0
            }
        }
    }

    fn new_store(
        engine: &Engine,
        host_callback: Option<Callable>,
        runtime_limits: RuntimeLimits,
    ) -> wasmtime::Result<Store<HostState>> {
        let limits = StoreLimitsBuilder::new()
            .memory_size(runtime_limits.memory_bytes)
            .table_elements(MAX_TABLE_ELEMENTS)
            .instances(runtime_limits.instances)
            .tables(runtime_limits.tables)
            .memories(runtime_limits.memories)
            .build();
        let mut store = Store::new(
            engine,
            HostState {
                limits,
                log_codes: Vec::new(),
                guest_error: None,
                host_calls: 0,
                max_host_calls: runtime_limits.host_calls,
                fuel: runtime_limits.fuel,
                deadline_ticks: runtime_limits.deadline_ticks,
                host_callback,
            },
        );
        store.limiter(|state| &mut state.limits);
        store.set_fuel(runtime_limits.fuel)?;
        store.set_epoch_deadline(runtime_limits.deadline_ticks);
        store.epoch_deadline_trap();
        Ok(store)
    }

    fn link_scene_host(linker: &mut Linker<HostState>) -> wasmtime::Result<()> {
        let mut host = linker.instance("vrweb:scene/host@1.0.0")?;
        host.func_wrap("query", |mut store, (target, request): (u64, Vec<u8>)| {
            let result =
                Self::call_host_bytes(store.data_mut(), "scene.query", target, request, None)?;
            Ok((result,))
        })?;
        host.func_wrap(
            "mutate",
            |mut store, (transaction, command): (u64, Vec<u8>)| {
                let result =
                    Self::call_host_unit(store.data_mut(), "scene.mutate", transaction, command)?;
                Ok((result,))
            },
        )?;
        host.func_wrap("commit", |mut store, (transaction,): (u64,)| {
            let result = Self::call_host_bytes(
                store.data_mut(),
                "scene.commit",
                transaction,
                Vec::new(),
                None,
            )?;
            Ok((result,))
        })?;
        host.func_wrap(
            "call",
            |mut store, (target, method, args): (u64, String, Vec<Vec<u8>>)| {
                let result = Self::call_host_bytes(
                    store.data_mut(),
                    "scene.call",
                    target,
                    method.into_bytes(),
                    Some(args),
                )?;
                Ok((result,))
            },
        )?;
        host.func_wrap("subscribe", |mut store, (target, signal): (u64, String)| {
            let result = Self::call_host_u64(
                store.data_mut(),
                "scene.subscribe",
                target,
                signal.into_bytes(),
            )?;
            Ok((result,))
        })?;
        host.func_wrap("unsubscribe", |mut store, (subscription,): (u64,)| {
            Self::call_host_void(store.data_mut(), "scene.unsubscribe", subscription)?;
            Ok(())
        })?;
        Ok(())
    }

    fn link_portable_hosts(linker: &mut Linker<HostState>) -> wasmtime::Result<()> {
        let mut state = linker.instance("vrweb:state/host@1.0.0")?;
        state.func_wrap("read", |mut store, (key,): (String,)| {
            let value =
                Self::call_host_bytes(store.data_mut(), "state.read", 0, key.into_bytes(), None)?;
            Ok((value,))
        })?;
        state.func_wrap("command", |mut store, (request,): (Vec<u8>,)| {
            let value = Self::call_host_unit(store.data_mut(), "state.command", 0, request)?;
            Ok((value,))
        })?;
        state.func_wrap("subscribe", |mut store, (key,): (String,)| {
            let value =
                Self::call_host_u64(store.data_mut(), "state.subscribe", 0, key.into_bytes())?;
            Ok((value,))
        })?;
        state.func_wrap("unsubscribe", |mut store, (subscription,): (u64,)| {
            Self::call_host_void(store.data_mut(), "state.unsubscribe", subscription)?;
            Ok(())
        })?;

        linker.instance("vrweb:assets/host@1.0.0")?.func_wrap(
            "lookup",
            |mut store, (name,): (String,)| {
                let value = Self::call_host_bytes(
                    store.data_mut(),
                    "assets.lookup",
                    0,
                    name.into_bytes(),
                    None,
                )?;
                Ok((value,))
            },
        )?;

        let mut timers = linker.instance("vrweb:timers/host@1.0.0")?;
        timers.func_wrap("start", |mut store, (delay_ms, repeat): (u32, bool)| {
            let mut payload = delay_ms.to_le_bytes().to_vec();
            payload.push(u8::from(repeat));
            let value = Self::call_host_u64(store.data_mut(), "timers.start", 0, payload)?;
            Ok((value,))
        })?;
        timers.func_wrap("cancel", |mut store, (timer,): (u64,)| {
            Self::call_host_void(store.data_mut(), "timers.cancel", timer)?;
            Ok(())
        })?;

        linker.instance("vrweb:input/host@1.0.0")?.func_wrap(
            "enable",
            |mut store, (kind, enabled): (String, bool)| {
                let mut payload = vec![u8::from(enabled)];
                payload.extend_from_slice(kind.as_bytes());
                let value = Self::call_host_unit(store.data_mut(), "input.enable", 0, payload)?;
                Ok((value,))
            },
        )?;

        linker.instance("vrweb:features/host@1.0.0")?.func_wrap(
            "has",
            |mut store, (capability,): (String,)| {
                let value = Self::call_host_bool(
                    store.data_mut(),
                    "features.has",
                    capability.into_bytes(),
                )?;
                Ok((value,))
            },
        )?;

        linker.instance("vrweb:log/host@1.0.0")?.func_wrap(
            "write",
            |mut store, (request,): (Vec<u8>,)| {
                let value = Self::call_host_unit(store.data_mut(), "log.write", 0, request)?;
                Ok((value,))
            },
        )?;
        Ok(())
    }

    fn callback_result(
        state: &mut HostState,
        operation: &str,
        id: u64,
        payload: Vec<u8>,
        nested: Option<Vec<Vec<u8>>>,
    ) -> wasmtime::Result<Variant> {
        state.host_calls += 1;
        if state.host_calls > state.max_host_calls {
            return Err(wasmtime::Error::msg("host call budget exceeded"));
        }
        let callback = state
            .host_callback
            .as_ref()
            .ok_or_else(|| wasmtime::Error::msg("scene host is unavailable"))?;
        let packed: PackedByteArray = payload.into_iter().collect();
        let nested_array: VarArray = nested
            .unwrap_or_default()
            .into_iter()
            .map(|bytes| {
                let value: PackedByteArray = bytes.into_iter().collect();
                value.to_variant()
            })
            .collect();
        Ok(callback.callv(&varray![
            &GString::from(operation).to_variant(),
            &(id as i64).to_variant(),
            &packed.to_variant(),
            &nested_array.to_variant(),
        ]))
    }

    fn call_host_bytes(
        state: &mut HostState,
        operation: &str,
        id: u64,
        payload: Vec<u8>,
        nested: Option<Vec<Vec<u8>>>,
    ) -> wasmtime::Result<Result<Vec<u8>, String>> {
        let value = Self::callback_result(state, operation, id, payload, nested)?;
        if let Ok(bytes) = value.try_to::<PackedByteArray>() {
            return Ok(Ok(bytes.to_vec()));
        }
        if let Ok(error) = value.try_to::<GString>() {
            return Ok(Err(error.to_string()));
        }
        Err(wasmtime::Error::msg("scene host returned invalid result"))
    }

    fn call_host_unit(
        state: &mut HostState,
        operation: &str,
        id: u64,
        payload: Vec<u8>,
    ) -> wasmtime::Result<Result<(), String>> {
        Self::call_host_bytes(state, operation, id, payload, None).map(|result| result.map(|_| ()))
    }

    fn call_host_u64(
        state: &mut HostState,
        operation: &str,
        id: u64,
        payload: Vec<u8>,
    ) -> wasmtime::Result<Result<u64, String>> {
        let value = Self::callback_result(state, operation, id, payload, None)?;
        if let Ok(number) = value.try_to::<i64>() {
            return u64::try_from(number)
                .map(Ok)
                .map_err(|_| wasmtime::Error::msg("scene host returned negative handle"));
        }
        if let Ok(error) = value.try_to::<GString>() {
            return Ok(Err(error.to_string()));
        }
        Err(wasmtime::Error::msg("scene host returned invalid result"))
    }

    fn call_host_bool(
        state: &mut HostState,
        operation: &str,
        payload: Vec<u8>,
    ) -> wasmtime::Result<bool> {
        let value = Self::callback_result(state, operation, 0, payload, None)?;
        value
            .try_to::<bool>()
            .map_err(|_| wasmtime::Error::msg("host returned invalid boolean"))
    }

    fn call_host_void(state: &mut HostState, operation: &str, id: u64) -> wasmtime::Result<()> {
        let value = Self::callback_result(state, operation, id, Vec::new(), None)?;
        if value.is_nil() {
            Ok(())
        } else if let Ok(error) = value.try_to::<GString>() {
            Err(wasmtime::Error::msg(error.to_string()))
        } else {
            Err(wasmtime::Error::msg("scene host returned invalid result"))
        }
    }

    fn call_s32(
        instance: &Instance,
        store: &mut Store<HostState>,
        export_name: &str,
        params: &[Val],
    ) -> wasmtime::Result<i32> {
        let fuel = store.data().fuel;
        let deadline_ticks = store.data().deadline_ticks;
        store.set_fuel(fuel)?;
        store.set_epoch_deadline(deadline_ticks);
        store.epoch_deadline_trap();
        store.data_mut().host_calls = 0;
        let function = instance.get_func(&mut *store, export_name).ok_or_else(|| {
            wasmtime::Error::msg(format!("component export not found: {export_name}"))
        })?;
        let mut results = [Val::S32(0)];
        function.call(&mut *store, params, &mut results)?;
        match results[0] {
            Val::S32(value) => Ok(value),
            _ => Err(wasmtime::Error::msg("component export must return s32")),
        }
    }
}

impl Drop for VrwebWasmRuntime {
    fn drop(&mut self) {
        self.epoch_stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.epoch_thread.take() {
            let _ = thread.join();
        }
    }
}

struct VrwebWasmExtension;

#[gdextension]
unsafe impl ExtensionLibrary for VrwebWasmExtension {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answer_component_runs_repeatedly_without_persistent_stores() {
        let engine = Engine::default();
        let bytes = wat::parse_file("fixtures/answer.wat").expect("parse component WAT");
        let component = Component::new(&engine, bytes).expect("compile component");
        for _ in 0..100 {
            let linker = Linker::<()>::new(&engine);
            let mut store = Store::new(&engine, ());
            let instance = linker
                .instantiate(&mut store, &component)
                .expect("instantiate");
            let function = instance
                .get_func(&mut store, "answer")
                .expect("answer export");
            let mut results = [Val::S32(0)];
            function
                .call(&mut store, &[], &mut results)
                .expect("call answer");
            assert!(matches!(results[0], Val::S32(42)));
        }
    }

    #[test]
    fn invalid_component_is_rejected() {
        let engine = Engine::default();
        let bytes = fs::read("fixtures/invalid.wasm").expect("read invalid fixture");
        assert!(Component::new(&engine, bytes).is_err());
    }

    #[test]
    fn component_validator_survives_truncation_and_mutation_corpus() {
        let engine = Engine::default();
        let valid = wat::parse_file("fixtures/answer.wat").expect("parse component WAT");
        let mut truncated_rejected = 0;
        for length in 0..valid.len() {
            if Component::new(&engine, &valid[..length]).is_err() {
                truncated_rejected += 1;
            }
        }
        // A syntactically complete empty component prefix is valid; most partial encodings are not.
        assert!(
            truncated_rejected > valid.len() / 2,
            "truncation corpus did not exercise enough validator failures"
        );
        let mut rejected = 0;
        for index in 0..valid.len().min(512) {
            let mut mutated = valid.clone();
            mutated[index] ^= 0xff;
            if Component::new(&engine, mutated).is_err() {
                rejected += 1;
            }
        }
        assert!(
            rejected > 0,
            "mutation corpus did not exercise validator failures"
        );
    }

    #[test]
    fn component_validator_survives_seeded_property_campaign() {
        let engine = Engine::default();
        let valid = wat::parse_file("fixtures/answer.wat").expect("parse component WAT");
        let mut seed = std::env::var("VRWEB_FUZZ_SEED")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(0x5652_5745_4246_555a);
        let multiplier = std::env::var("VRWEB_FUZZ_MULTIPLIER")
            .ok()
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(1)
            .clamp(1, 100);
        let cases = 10_000 * multiplier;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let mut random_rejected = 0usize;
        let mut mutated_rejected = 0usize;
        for _case in 0..cases {
            let length = (next() as usize) % 4097;
            let mut random = vec![0u8; length];
            for byte in &mut random {
                *byte = next() as u8;
            }
            if Component::new(&engine, &random).is_err() {
                random_rejected += 1;
            }

            let mut mutated = valid.clone();
            let edits = 1 + (next() as usize % 16);
            for _ in 0..edits {
                let index = next() as usize % mutated.len();
                mutated[index] ^= (next() as u8) | 1;
            }
            if Component::new(&engine, &mutated).is_err() {
                mutated_rejected += 1;
            }
        }
        assert_eq!(
            random_rejected, cases,
            "random binary unexpectedly validated"
        );
        assert!(
            mutated_rejected > cases / 10,
            "seeded mutations did not exercise enough validator failures"
        );
    }
}
