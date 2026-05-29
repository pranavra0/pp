use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::Path;

use pp::eval::Evaluator;
use pp::lexer::Lexer;
use pp::parser::Parser;
use pp::value::Value;

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut store_path: Option<String> = None;
    let mut no_stdlib = false;
    let mut files = Vec::new();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--store" | "-s" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("Error: --store requires a directory path");
                    std::process::exit(1);
                }
                store_path = Some(args[i].clone());
            }
            "--no-stdlib" => no_stdlib = true,
            "--help" | "-h" => {
                println!("pp — lazy, content-addressed, graph-native evaluator\n");
                println!("Usage: pp [OPTIONS] [FILE...]\n");
                println!("Options:");
                println!("  --store DIR, -s DIR   Use DIR for disk cache");
                println!("  --no-stdlib            Do not load standard library");
                println!("  --help, -h             Show this help");
                return;
            }
            s if s.starts_with("--store=") => {
                store_path = Some(s[8..].to_string());
            }
            s if s.starts_with('-') => {
                eprintln!("Unknown option: {}", s);
                eprintln!("Use --help for usage.");
                std::process::exit(1);
            }
            _ => files.push(args[i].clone()),
        }
        i += 1;
    }

    if !files.is_empty() {
        for file in files {
            let code = run_file(&file, store_path.as_deref(), no_stdlib);
            if code != 0 {
                std::process::exit(code);
            }
        }
    } else {
        repl(store_path, no_stdlib);
    }
}

fn run_file(path: &str, store_path: Option<&str>, no_stdlib: bool) -> i32 {
    let src = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => { eprintln!("Error reading {}: {}", path, e); return 1; }
    };
    let mut ev = Evaluator::new(store_path.map(|s| s.to_string()));
    if !no_stdlib {
        load_stdlib(&mut ev);
    }
    match run_source(&src, &mut ev) {
        Ok(Some(v)) => { println!("{:?}", v); 0 }
        Ok(None) => 0,
        Err(e) => { eprintln!("{}", e); 1 }
    }
}

fn run_source(src: &str, ev: &mut Evaluator) -> Result<Option<Value>, String> {
    let tokens = Lexer::new(src).tokenize()?;
    let (bindings, expr) = Parser::new(tokens).parse()?;
    let bindings: Vec<(String, pp::ast::Expr)> = bindings;
    let result = ev.run(&bindings, expr.as_ref());
    Ok(result)
}

fn load_stdlib(ev: &mut Evaluator) {
    // Try to find std.pp relative to CWD or the executable
    let paths = [
        "stdlib/std.pp".to_string(),
        "pp/stdlib/std.pp".to_string(),
    ];
    for p in &paths {
        if Path::new(p).exists() {
            match fs::read_to_string(p) {
                Ok(src) => {
                    match run_source(&src, ev) {
                        Ok(_) => return,
                        Err(e) => eprintln!("Warning: stdlib load error: {}", e),
                    }
                }
                Err(_) => continue,
            }
        }
    }
}

fn repl(mut store_path: Option<String>, no_stdlib: bool) {
    let mut ev = Evaluator::new(store_path.clone());
    if !no_stdlib {
        load_stdlib(&mut ev);
    }
    println!("pp REPL  (store={})", store_path.as_deref().unwrap_or("off"));
    println!("  :help  :quit  :reset  :env  :store  :load");
    loop {
        print!("pp> ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        match io::stdin().read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let line = line.trim();
        if line.is_empty() { continue; }
        if line.starts_with(':') {
            let cmd = &line[1..].trim();
            match *cmd {
                "quit" | "q" | "exit" => break,
                "help" | "h" | "?" => println!(":quit :reset :env :store [PATH] :load FILE"),
                "reset" => {
                    ev = Evaluator::new(store_path.clone());
                    if !no_stdlib { load_stdlib(&mut ev); }
                    println!("Reset.");
                }
                "store" => println!("Store: {}", store_path.as_deref().unwrap_or("(none)")),
                s if s.starts_with("store ") => {
                    let p = s[6..].trim().to_string();
                    store_path = Some(p.clone());
                    ev = Evaluator::new(Some(p));
                    if !no_stdlib { load_stdlib(&mut ev); }
                    println!("Store: {}", store_path.as_deref().unwrap_or("(none)"));
                }
                s if s.starts_with("load ") => {
                    let fp = s[5..].trim();
                    match fs::read_to_string(fp) {
                        Ok(src) => {
                            match run_source(&src, &mut ev) {
                                Ok(Some(v)) => println!("{:?}", v),
                                Ok(None) => {},
                                Err(e) => eprintln!("{}", e),
                            }
                        }
                        Err(e) => println!("Error: {}", e),
                    }
                }
                "env" => {
                    // Print bindings from the root frame (frame 0)
                    let frame = &ev.frames[0];
                    for name in frame.bindings.keys() {
                        let v = &frame.bindings[name];
                        match v {
                            Value::Thunk(t) => {
                                if let Some(cached) = t.cached.borrow().as_ref() {
                                    println!("  {} = {:?}", name, cached);
                                } else {
                                    println!("  {} = <thunk>", name);
                                }
                            }
                            _ => println!("  {} = {:?}", name, v),
                        }
                    }
                }
                _ => println!("Unknown: {}", line),
            }
            continue;
        }
        match run_source(line, &mut ev) {
            Ok(Some(v)) => println!("{:?}", v),
            Ok(None) => {},
            Err(e) => eprintln!("{}", e),
        }
    }
}
