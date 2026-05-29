use std::collections::HashMap;
use std::fs;
use tempfile::TempDir;

pub struct WasmResult {
    pub stdout: String,
    pub stderr: String,
    pub exit_code: i64,
    pub outputs: HashMap<String, Vec<u8>>,
}

pub fn run_wasm(
    module: &str,
    args: &[String],
    input_files: &HashMap<String, Vec<u8>>,
    output_paths: &[String],
) -> Result<WasmResult, String> {
    let tmp = TempDir::new().map_err(|e| format!("temp dir: {}", e))?;

    for (fname, content) in input_files {
        let fpath = tmp.path().join(fname);
        if let Some(parent) = fpath.parent() {
            let _ = fs::create_dir_all(parent);
        }
        fs::write(&fpath, content).map_err(|e| format!("write {}: {}", fname, e))?;
    }

    let wasm_bytes = if module.ends_with(".wat") {
        let src = fs::read_to_string(module).map_err(|e| format!("read {}: {}", module, e))?;
        wat::parse_str(&src).map_err(|e| format!("compile {}: {}", module, e))?
    } else if module.ends_with(".wasm") {
        fs::read(module).map_err(|e| format!("read {}: {}", module, e))?
    } else {
        wat::parse_str(module).map_err(|e| format!("parse wat: {}", e))?
    };

    let stdout_path = tmp.path().join("__lc_stdout__");
    let stderr_path = tmp.path().join("__lc_stderr__");

    // Use the cap-std based WASI context builder from wasi-cap-std-sync
    let mut builder = wasi_cap_std_sync::WasiCtxBuilder::new();

    if !args.is_empty() {
        builder.args(args).map_err(|e| format!("args: {}", e))?;
    }

    // Preopen temp dir as "/"
    let cap_dir = cap_std::fs::Dir::open_ambient_dir(tmp.path(), cap_std::ambient_authority())
        .map_err(|e| format!("opendir: {}", e))?;
    builder
        .preopened_dir(cap_dir, "/")
        .map_err(|e| format!("preopen: {}", e))?;

    // Set up stdout/stderr capture
    let cap_stdout = cap_std::fs::File::from_std(
        fs::File::create(&stdout_path).map_err(|e| format!("stdout file: {}", e))?
    );
    let cap_stderr = cap_std::fs::File::from_std(
        fs::File::create(&stderr_path).map_err(|e| format!("stderr file: {}", e))?
    );
    builder.stdout(Box::new(wasi_cap_std_sync::file::File::from_cap_std(cap_stdout)));
    builder.stderr(Box::new(wasi_cap_std_sync::file::File::from_cap_std(cap_stderr)));

    let ctx = builder.build();

    let engine = wasmtime::Engine::default();
    let module = wasmtime::Module::new(&engine, &wasm_bytes).map_err(|e| format!("module: {}", e))?;
    let mut linker = wasmtime::Linker::new(&engine);
    let mut store = wasmtime::Store::new(&engine, ctx);

    wasmtime_wasi::add_to_linker(&mut linker, |s: &mut wasmtime_wasi::WasiCtx| s)
        .map_err(|e| format!("linker: {}", e))?;

    let instance = linker.instantiate(&mut store, &module).map_err(|e| format!("inst: {}", e))?;

    let exit_code = match instance.get_typed_func::<(), ()>(&mut store, "_start") {
        Ok(func) => match func.call(&mut store, ()) {
            Ok(()) => 0,
            Err(e) => {
                if let Some(exit) = e.downcast_ref::<wasmtime_wasi::I32Exit>() {
                    exit.0 as i64
                } else {
                    -1
                }
            }
        },
        Err(_) => 0,
    };

    drop(store);

    let stdout = fs::read_to_string(&stdout_path).unwrap_or_default();
    let stderr = fs::read_to_string(&stderr_path).unwrap_or_default();

    let mut outputs = HashMap::new();
    for opath in output_paths {
        let op = tmp.path().join(opath);
        if op.exists() {
            outputs.insert(opath.clone(), fs::read(&op).unwrap_or_default());
        }
    }

    Ok(WasmResult { stdout, stderr, exit_code, outputs })
}
