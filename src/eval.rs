use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::cell::RefCell;

use crate::ast::Expr;
use crate::lexer::{Lexer};
use crate::parser::Parser;
use crate::value::*;
pub use crate::value::Evaluator;
pub use crate::value::Value;

// ── Evaluator ──────────────────────────────────────────────────────

impl Evaluator {
    pub fn new(store_path: Option<String>) -> Self {
        if let Some(ref p) = store_path {
            let _ = std::fs::create_dir_all(p);
        }
        let true_val = Value::Record(Arc::new({
            let mut m = HashMap::new();
            m.insert(Arc::from("tag"), Value::Symbol(Arc::from("true")));
            m
        }));
        let false_val = Value::Record(Arc::new({
            let mut m = HashMap::new();
            m.insert(Arc::from("tag"), Value::Symbol(Arc::from("false")));
            m
        }));
        let nil_val = Value::Record(Arc::new({
            let mut m = HashMap::new();
            m.insert(Arc::from("tag"), Value::Symbol(Arc::from("nil")));
            m
        }));

        let mut frames = vec![EnvFrame::new(HashMap::new(), None)];

        // Build the primitive environment
        let mut b: HashMap<Arc<str>, Value> = HashMap::new();

        // Helper: wrap a closure as a BuiltinFn
        fn mk_builtin<F>(f: F) -> Rc<dyn Fn(&[Value], &mut Evaluator) -> Value>
        where
            F: Fn(&[Value], &mut Evaluator) -> Value + 'static,
        {
            Rc::new(f)
        }

        macro_rules! builtin {
            ($name:expr, $arity:expr, $fn:expr) => {
                b.insert(Arc::from($name), Value::Builtin {
                    name: Arc::from($name),
                    arity: $arity,
                    args: Vec::new(),
                    func: mk_builtin($fn),
                });
            };
        }

        // ── int arithmetic ──
        builtin!("int-add", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let a = match ev.int_val(&args[0]) { Ok(n) => n, Err(e) => return e };
            let b = match ev.int_val(&args[1]) { Ok(n) => n, Err(e) => return e };
            Value::Int(a + b)
        });

        builtin!("int-sub", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let a = match ev.int_val(&args[0]) { Ok(n) => n, Err(e) => return e };
            let b = match ev.int_val(&args[1]) { Ok(n) => n, Err(e) => return e };
            Value::Int(a - b)
        });

        builtin!("int-mul", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let a = match ev.int_val(&args[0]) { Ok(n) => n, Err(e) => return e };
            let b = match ev.int_val(&args[1]) { Ok(n) => n, Err(e) => return e };
            Value::Int(a * b)
        });

        builtin!("int-div", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let a = match ev.int_val(&args[0]) { Ok(n) => n, Err(e) => return e };
            let b = match ev.int_val(&args[1]) { Ok(n) => n, Err(e) => return e };
            if b == 0 { return mk_error("div-by-zero", "division by zero"); }
            Value::Int(a / b)
        });

        builtin!("int-cmp", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let a = match ev.int_val(&args[0]) { Ok(n) => n, Err(e) => return e };
            let b = match ev.int_val(&args[1]) { Ok(n) => n, Err(e) => return e };
            Value::Int(if a < b { -1 } else if a > b { 1 } else { 0 })
        });

        // ── string operations ──
        builtin!("str-append", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let a = match ev.str_val(&args[0]) { Ok(s) => s, Err(e) => return e };
            let b = match ev.str_val(&args[1]) { Ok(s) => s, Err(e) => return e };
            Value::Str(Arc::from(format!("{}{}", a, b)))
        });

        builtin!("str-length", 1, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let s = match ev.str_val(&args[0]) { Ok(s) => s, Err(e) => return e };
            Value::Int(s.len() as i64)
        });

        builtin!("int-to-str", 1, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let n = match ev.int_val(&args[0]) { Ok(n) => n, Err(e) => return e };
            Value::Str(Arc::from(n.to_string()))
        });

        builtin!("str-to-int", 1, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let s = match ev.str_val(&args[0]) { Ok(s) => s, Err(e) => return e };
            match s.parse::<i64>() {
                Ok(n) => Value::Int(n),
                Err(_) => mk_error("parse", &format!("cannot parse as int: {}", s)),
            }
        });

        // ── semantics ──
        builtin!("eq?", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            ev.eq_value(args[0].clone(), args[1].clone())
        });

        builtin!("type-of", 1, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let v = ev.force_pure(args[0].clone());
            match &v {
                Value::Int(_) => Value::Symbol(Arc::from("int")),
                Value::Str(_) => Value::Symbol(Arc::from("str")),
                Value::Symbol(_) => Value::Symbol(Arc::from("symbol")),
                Value::Record(fields) => {
                    if let Some(tag) = fields.get("tag") {
                        let tag = ev.force_pure(tag.clone());
                        if let Value::Symbol(s) = tag {
                            return Value::Symbol(s);
                        }
                    }
                    Value::Symbol(Arc::from("record"))
                }
                Value::Closure { .. } | Value::Builtin { .. } => Value::Symbol(Arc::from("fn")),
                Value::Derivation(_) => Value::Symbol(Arc::from("derivation")),
                Value::Thunk(_) => Value::Symbol(Arc::from("thunk")),
            }
        });

        builtin!("error", 2, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            let kind = match &args[0] {
                Value::Symbol(s) => s.clone(),
                _ => return mk_error("type", "error kind must be a symbol"),
            };
            let msg = match &args[1] {
                Value::Str(s) => s.clone(),
                _ => return mk_error("type", "error message must be a string"),
            };
            mk_error(&kind, &msg)
        });

        // ── effects ──
        builtin!("exec", 1, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            match &args[0] {
                Value::Record(_) => Value::Derivation(Arc::new(DerivState {
                    spec: args[0].clone(),
                    cached: RefCell::new(None),
                    hash: RefCell::new(None),
                })),
                _ => mk_error("type", "exec expects a record"),
            }
        });

        // realize: forces a derivation
        builtin!("realize", 1, |args: &[Value], ev: &mut Evaluator| -> Value {
            if let Some(e) = propagate_error(args, ev) { return e; }
            match &args[0] {
                Value::Derivation(d) => realize_deriv(d.clone(), ev),
                v => v.clone(),
            }
        });

        // Sentinels
        b.insert(Arc::from("true"), true_val.clone());
        b.insert(Arc::from("false"), false_val.clone());
        b.insert(Arc::from("nil"), nil_val.clone());

        frames[0] = EnvFrame::new(b, None);

        Evaluator {
            frames,
            cache: HashMap::new(),
            current_frame: 0,
            store_path,
            true_val,
            false_val,
            nil_val,
        }
    }

    // ── helpers ─────────────────────────────────────────────────
    pub fn int_val(&mut self, v: &Value) -> Result<i64, Value> {
        let v = self.force_pure(v.clone());
        match v {
            Value::Int(n) => Ok(n),
            _ => Err(mk_error("type", &format!("expected int, got {}", v.kind_name()))),
        }
    }

    pub fn str_val(&mut self, v: &Value) -> Result<Arc<str>, Value> {
        let v = self.force_pure(v.clone());
        match v {
            Value::Str(s) => Ok(s),
            _ => Err(mk_error("type", &format!("expected str, got {}", v.kind_name()))),
        }
    }

    fn eq_value(&mut self, a: Value, b: Value) -> Value {
        let a = self.force_pure(a);
        let b = self.force_pure(b);
        if is_error(&a) { return a; }
        if is_error(&b) { return b; }
        match (&a, &b) {
            (Value::Int(a), Value::Int(b)) => self.bool_val(a == b),
            (Value::Str(a), Value::Str(b)) => self.bool_val(a == b),
            (Value::Symbol(a), Value::Symbol(b)) => self.bool_val(Arc::ptr_eq(a, b) || a.as_ref() == b.as_ref()),
            (Value::Record(a), Value::Record(b)) => {
                if a.len() != b.len() { return self.false_val.clone(); }
                for (k, av) in a.iter() {
                    match b.get(k) {
                        Some(bv) => {
                            let eq = self.eq_value(av.clone(), bv.clone());
                            if is_error(&eq) { return eq; }
                            if self.is_false_val(&eq) { return self.false_val.clone(); }
                        }
                        None => return self.false_val.clone(),
                    }
                }
                self.true_val.clone()
            }
            (Value::Closure { .. }, Value::Closure { .. }) => self.bool_val(false),
            (Value::Builtin { name: a_name, .. }, Value::Builtin { name: b_name, .. }) => self.bool_val(a_name == b_name),
            (Value::Derivation(a), Value::Derivation(b)) => {
                self.eq_value(a.spec.clone(), b.spec.clone())
            }
            _ => self.false_val.clone(),
        }
    }

    fn bool_val(&self, b: bool) -> Value {
        if b { self.true_val.clone() } else { self.false_val.clone() }
    }

    fn is_false_val(&self, v: &Value) -> bool {
        match v {
            Value::Record(fields) => {
                fields.get("tag").map_or(false, |tag| match tag {
                    Value::Symbol(s) => s.as_ref() == "false",
                    _ => false,
                })
            }
            _ => false,
        }
    }

    // ── environment ───────────────────────────────────────────
    fn alloc_frame(&mut self, bindings: HashMap<Arc<str>, Value>, parent: Option<FrameId>) -> FrameId {
        let id = self.frames.len();
        self.frames.push(EnvFrame::new(bindings, parent));
        id
    }

    pub fn lookup(&self, name: &str, frame_id: FrameId) -> Option<Value> {
        let frame = &self.frames[frame_id];
        if let Some(v) = frame.bindings.get(name) {
            return Some(v.clone());
        }
        if let Some(parent_id) = frame.parent {
            return self.lookup(name, parent_id);
        }
        None
    }

    // ── forcing ───────────────────────────────────────────────
    pub fn force_pure(&mut self, v: Value) -> Value {
        let mut current = v;
        loop {
            let next = match &current {
                Value::Thunk(t) => {
                    let cached = t.cached.borrow();
                    if let Some(c) = cached.as_ref() {
                        Some(c.clone())
                    } else {
                        drop(cached);
                        Some(force_thunk(t.clone(), self))
                    }
                }
                _ => None,
            };
            match next {
                Some(v) => current = v,
                None => break,
            }
        }
        current
    }

    pub fn force_all(&mut self, v: Value) -> Value {
        let v = self.force_pure(v);
        if let Value::Derivation(d) = &v {
            realize_deriv(d.clone(), self)
        } else {
            v
        }
    }

    // ── entry ─────────────────────────────────────────────────
    pub fn run(&mut self, bindings: &[(String, Expr)], expr: Option<&Expr>) -> Option<Value> {
        if !bindings.is_empty() {
            let root_frame = 0; // primitive frame
            let mut created: Vec<(String, Arc<ThunkState>)> = Vec::new();
            let mut mutual = root_frame;
            for (name, val_expr) in bindings {
                let free = free_vars(val_expr);
                let thunk = Arc::new(ThunkState {
                    expr: Arc::new(val_expr.clone()),
                    env: RefCell::new(0), // temporary
                    free,
                    cached: RefCell::new(None),
                    hash: RefCell::new(None),
                });
                let mut bindings = HashMap::new();
                bindings.insert(Arc::from(name.as_str()), Value::Thunk(thunk.clone()));
                let frame_id = self.alloc_frame(bindings, Some(mutual));
                created.push((name.clone(), thunk));
                mutual = frame_id;
            }
            for (_, thunk) in &created {
                thunk.env.replace(mutual);
            }
            self.current_frame = mutual;
        }
        if let Some(e) = expr {
            let val = self.eval(e, self.current_frame);
            Some(self.force_pure(val))
        } else {
            None
        }
    }

    // ── eval ──────────────────────────────────────────────────
    pub fn eval(&mut self, expr: &Expr, frame_id: FrameId) -> Value {
        match expr {
            Expr::Name(name) => {
                match self.lookup(name, frame_id) {
                    Some(v) => v,
                    None => mk_error("name", &format!("undefined: {}", name)),
                }
            }
            Expr::IntLit(n) => Value::Int(*n),
            Expr::StrLit(s) => Value::Str(Arc::from(s.as_str())),
            Expr::SymLit(s) => Value::Symbol(Arc::from(s.as_str())),
            Expr::Lambda { param, body } => Value::Closure {
                param: Arc::from(param.as_str()),
                body: Arc::new(body.as_ref().clone()),
                env: frame_id,
            },
            Expr::Pipe { left, right } => {
                let ap = Expr::Apply { func: right.clone(), arg: left.clone() };
                self.eval(&ap, frame_id)
            }
            Expr::Apply { func, arg } => {
                let f_val = self.eval(func, frame_id);
                let f = self.force_pure(f_val);
                if is_error(&f) { return f; }

                match &f {
                    Value::Closure { param, body, env } => {
                        let subbed = substitute(body, param, arg);
                        self.eval(&subbed, *env)
                    }
                    Value::Builtin { arity, args, func: builtin_func, .. } => {
                        let arg_thunk = Value::Thunk(Arc::new(ThunkState {
                            expr: Arc::new(arg.as_ref().clone()),
                            env: RefCell::new(frame_id),
                            free: free_vars(arg),
                            cached: RefCell::new(None),
                            hash: RefCell::new(None),
                        }));
                        let forced_arg = self.force_pure(arg_thunk);
                        if is_error(&forced_arg) { return forced_arg; }
                        let new_args: Vec<Value> = {
                            let mut a = args.clone();
                            a.push(forced_arg);
                            a
                        };
                        if new_args.len() >= *arity {
                            builtin_func(&new_args, self)
                        } else {
                            let name = match &f {
                                Value::Builtin { name, .. } => name.clone(),
                                _ => Arc::from("?"),
                            };
                            Value::Builtin {
                                name,
                                arity: *arity,
                                args: new_args,
                                func: builtin_func.clone(),
                            }
                        }
                    }
                    _ => mk_error("type", &format!("cannot apply {}", f.kind_name())),
                }
            }
            Expr::If { cond, then, elze } => {
                let c_val = self.eval(cond, frame_id);
                let c = self.force_pure(c_val);
                if is_error(&c) { return c; }
                let is_false = match &c {
                    Value::Record(fields) => {
                        fields.get("tag").map_or(false, |v| {
                            let v = self.force_pure(v.clone());
                            match v {
                                Value::Symbol(ref s) => s.as_ref() == "false",
                                _ => false,
                            }
                        })
                    }
                    _ => false,
                };
                self.eval(if is_false { elze } else { then }, frame_id)
            }
            Expr::Record(fields) => {
                let mut m = HashMap::new();
                for (name, field_expr) in fields {
                    let thunk = Value::Thunk(Arc::new(ThunkState {
                        expr: Arc::new(field_expr.clone()),
                        env: RefCell::new(frame_id),
                        free: free_vars(field_expr),
                        cached: RefCell::new(None),
                        hash: RefCell::new(None),
                    }));
                    m.insert(Arc::from(name.as_str()), thunk);
                }
                Value::Record(Arc::new(m))
            }
            Expr::ListLit(items) => {
                // [a, b, c] desugars to cons a (cons b (cons c nil))
                let mut result = Expr::Name("nil".into());
                for item in items.iter().rev() {
                    result = Expr::Apply {
                        func: Box::new(Expr::Apply {
                            func: Box::new(Expr::Name("cons".into())),
                            arg: Box::new(item.clone()),
                        }),
                        arg: Box::new(result),
                    };
                }
                self.eval(&result, frame_id)
            }
            Expr::Field { record, name } => {
                let r_val = self.eval(record, frame_id);
                let r = self.force_pure(r_val);
                if is_error(&r) { return r; }
                match &r {
                    Value::Record(fields) => {
                        match fields.get(name.as_str()) {
                            Some(v) => self.force_pure(v.clone()),
                            None => mk_error("name", &format!("no field '{}'", name)),
                        }
                    }
                    _ => mk_error("type", "field access on non-record"),
                }
            }
        }
    }
}

// ── Error helpers ──────────────────────────────────────────────────

pub fn is_error(v: &Value) -> bool {
    match v {
        Value::Record(fields) => {
            fields.get("tag").map_or(false, |tag| {
                match tag {
                    Value::Symbol(s) => s.as_ref() == "error",
                    _ => false,
                }
            })
        }
        _ => false,
    }
}

pub fn mk_error(kind: &str, msg: &str) -> Value {
    let mut m = HashMap::new();
    m.insert(Arc::from("tag"), Value::Symbol(Arc::from("error")));
    m.insert(Arc::from("kind"), Value::Symbol(Arc::from(kind)));
    m.insert(Arc::from("message"), Value::Str(Arc::from(msg)));
    Value::Record(Arc::new(m))
}

pub fn propagate_error(args: &[Value], ev: &mut Evaluator) -> Option<Value> {
    for a in args {
        let a = ev.force_pure(a.clone());
        if is_error(&a) { return Some(a); }
    }
    None
}

// ── Thunk / Derivation forcing ────────────────────────────────────

fn force_thunk(t: Arc<ThunkState>, ev: &mut Evaluator) -> Value {
    // Compute hash if needed — release borrow before compute (avoids cycles)
    let need_hash = t.hash.borrow().is_none();
    if need_hash {
        let h = compute_thunk_hash(&t, ev);
        *t.hash.borrow_mut() = Some(h);
    }
    let h = t.hash.borrow().clone().unwrap();

    // Check memory cache
    if let Some(cached) = ev.cache.get(&h) {
        return cached.clone();
    }

    // Check disk cache
    if let Some(ref store_path) = ev.store_path {
        if let Some(loaded) = load_from_store(&h, store_path) {
            ev.cache.insert(h.clone(), loaded.clone());
            *t.cached.borrow_mut() = Some(loaded.clone());
            return loaded;
        }
    }

    // Evaluate
    let result = ev.eval(&t.expr, *t.env.borrow());
    let result = ev.force_pure(result);
    ev.cache.insert(h.clone(), result.clone());
    *t.cached.borrow_mut() = Some(result.clone());

    // Save to disk
    if let Some(ref store_path) = ev.store_path {
        save_to_store(&h, &result, store_path);
    }

    result
}

fn realize_deriv(d: Arc<DerivState>, ev: &mut Evaluator) -> Value {
    // Compute hash
    let h = {
        let mut hash = d.hash.borrow_mut();
        if hash.is_none() {
            *hash = Some(compute_deriv_hash(&d, ev));
        }
        hash.clone().unwrap()
    };

    if let Some(cached) = ev.cache.get(&h) {
        return cached.clone();
    }

    let result = run_derivation(&d, ev);
    ev.cache.insert(h.clone(), result.clone());
    *d.cached.borrow_mut() = Some(result.clone());

    if let Some(ref store_path) = ev.store_path {
        save_to_store(&h, &result, store_path);
    }

    result
}

fn run_derivation(d: &DerivState, ev: &mut Evaluator) -> Value {
    let spec = ev.force_pure(d.spec.clone());
    let fields = match &spec {
        Value::Record(f) => f,
        _ => return mk_error("type", "derivation spec must be a record"),
    };

    // Get kind
    let kind = fields.get("kind").and_then(|v| {
        let v = ev.force_pure(v.clone());
        match v {
            Value::Symbol(s) => Some(s),
            _ => None,
        }
    });

    // ── import derivation ──
    if kind.as_ref().map_or(false, |s| s.as_ref() == "import") {
        let path = fields.get("path").and_then(|v| {
            let v = ev.force_pure(v.clone());
            match v {
                Value::Str(s) => Some(s.to_string()),
                _ => None,
            }
        });
        let path = match path {
            Some(p) => p,
            None => return mk_error("type", "import derivation needs path string"),
        };
        return import_module(&path, ev);
    }

    // ── WASM derivation ──
    let module = fields.get("module").and_then(|v| {
        let v = ev.force_pure(v.clone());
        match v {
            Value::Str(s) => Some(s.to_string()),
            _ => None,
        }
    });
    let module = match module {
        Some(m) => m,
        None => return mk_error("type", "WASM derivation needs module string"),
    };

    let args: Vec<String> = fields.get("args")
        .map(|v| cons_to_py_list(v.clone(), ev))
        .unwrap_or_default();

    let outputs: Vec<String> = fields.get("outputs")
        .map(|v| cons_to_py_list(v.clone(), ev))
        .unwrap_or_default();

    let mut input_files: HashMap<String, Vec<u8>> = HashMap::new();
    if let Some(inputs) = fields.get("inputs") {
        collect_inputs(inputs.clone(), &mut input_files, ev);
    }

    // Run WASM
    match crate::wasm::run_wasm(&module, &args, &input_files, &outputs) {
        Ok(result) => {
            let mut rfields: HashMap<Arc<str>, Value> = HashMap::new();
            rfields.insert(Arc::from("stdout"), Value::Str(Arc::from(result.stdout)));
            rfields.insert(Arc::from("stderr"), Value::Str(Arc::from(result.stderr)));
            rfields.insert(Arc::from("exit-code"), Value::Int(result.exit_code));
            if !result.outputs.is_empty() {
                let mut ofields: HashMap<Arc<str>, Value> = HashMap::new();
                for (k, v) in result.outputs {
                    let content = String::from_utf8_lossy(&v).to_string();
                    ofields.insert(Arc::from(k), Value::Str(Arc::from(content)));
                }
                rfields.insert(Arc::from("outputs"), Value::Record(Arc::new(ofields)));
            }
            Value::Record(Arc::new(rfields))
        }
        Err(e) => mk_error("exec", &format!("WASM execution failed: {}", e)),
    }
}

fn import_module(path: &str, ev: &mut Evaluator) -> Value {
    let resolved = resolve_path(path);
    let resolved = match resolved {
        Some(p) => p,
        None => return mk_error("import", &format!("module not found: {}", path)),
    };
    let src = match std::fs::read_to_string(&resolved) {
        Ok(s) => s,
        Err(e) => return mk_error("import", &format!("reading {}: {}", resolved.display(), e)),
    };
    let tokens = match Lexer::new(&src).tokenize() {
        Ok(t) => t,
        Err(e) => return mk_error("parse", &format!("in module {}: {}", path, e)),
    };
    let (bindings, expr) = match Parser::new(tokens).parse() {
        Ok(b) => b,
        Err(e) => return mk_error("parse", &format!("in module {}: {}", path, e)),
    };
    let mut fields: HashMap<Arc<str>, Value> = HashMap::new();
    let mut child = Evaluator::new(ev.store_path.clone());
    // Share the primitive frame
    child.frames[0] = EnvFrame::new(ev.frames[0].bindings.clone(), None);
    child.cache = HashMap::new(); // TODO: share cache
    let bindings: Vec<(String, Expr)> = bindings.into_iter().collect();
    let _ = child.run(&bindings, expr.as_ref());
    for (name, _) in &bindings {
        if let Some(v) = child.lookup(name, child.current_frame) {
            fields.insert(Arc::from(name.as_str()), v);
        }
    }
    Value::Record(Arc::new(fields))
}

// ── Helpers ───────────────────────────────────────────────────────

fn cons_to_py_list(v: Value, ev: &mut Evaluator) -> Vec<String> {
    let mut result = Vec::new();
    let mut current = v;
    loop {
        current = ev.force_pure(current);
        match &current {
            Value::Record(fields) => {
                let tag = fields.get("tag").and_then(|t| {
                    let t = ev.force_pure(t.clone());
                    match t { Value::Symbol(s) => Some(s), _ => None }
                });
                if tag.as_ref().map_or(true, |s| s.as_ref() != "cons") { break; }
                if let Some(head) = fields.get("head") {
                    let h = ev.force_pure(head.clone());
                    if let Value::Str(s) = h {
                        result.push(s.to_string());
                    }
                }
                current = fields.get("tail").cloned().unwrap_or(Value::Record(Arc::new(HashMap::new())));
            }
            _ => break,
        }
    }
    result
}

fn collect_inputs(v: Value, into: &mut HashMap<String, Vec<u8>>, ev: &mut Evaluator) {
    let mut current = v;
    loop {
        current = ev.force_pure(current);
        match &current {
            Value::Record(fields) => {
                let tag = fields.get("tag").and_then(|t| {
                    let t = ev.force_pure(t.clone());
                    match t { Value::Symbol(s) => Some(s), _ => None }
                });
                if tag.as_ref().map_or(true, |s| s.as_ref() != "cons") { break; }
                if let Some(head) = fields.get("head") {
                    let h = ev.force_pure(head.clone());
                    if let Value::Record(hfields) = h {
                        if let (Some(name), Some(content)) = (hfields.get("name"), hfields.get("content")) {
                            let name = ev.force_pure(name.clone());
                            let content = ev.force_pure(content.clone());
                            if let (Value::Str(n), Value::Str(c)) = (name, content) {
                                into.insert(n.to_string(), c.as_bytes().to_vec());
                            }
                        }
                    }
                }
                current = fields.get("tail").cloned().unwrap_or(Value::Record(Arc::new(HashMap::new())));
            }
            _ => break,
        }
    }
}

fn resolve_path(path: &str) -> Option<PathBuf> {
    if Path::new(path).exists() {
        return Some(PathBuf::from(path));
    }
    // Try relative to the executable
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let alt = dir.join(path);
            if alt.exists() { return Some(alt); }
        }
    }
    None
}

// ── Hashing ───────────────────────────────────────────────────────

fn compute_thunk_hash(t: &ThunkState, ev: &mut Evaluator) -> String {
    use sha2::{Sha256, Digest};
    let mut h = Sha256::new();
    h.update(b"thunk\x00");
    h.update(hash_expr(&t.expr).as_bytes());
    h.update(b"\x00");
    let mut free_sorted: Vec<&Arc<str>> = t.free.iter().collect();
    free_sorted.sort();
    for name in free_sorted {
        if let Some(val) = ev.lookup(name, *t.env.borrow()) {
            h.update(name.as_bytes());
            h.update(b"=");
            h.update(hash_value(&val, ev).as_bytes());
        }
    }
    format!("sha256:{:x}", h.finalize())
}

fn compute_deriv_hash(d: &DerivState, ev: &mut Evaluator) -> String {
    use sha2::{Sha256, Digest};
    let mut h = Sha256::new();
    h.update(b"deriv\x00");
    h.update(hash_value(&d.spec, ev).as_bytes());
    format!("sha256:{:x}", h.finalize())
}

fn hash_expr(e: &Expr) -> String {
    use sha2::{Sha256, Digest};
    let mut h = Sha256::new();
    match e {
        Expr::Name(n) => { h.update(b"name\x00"); h.update(n.as_bytes()); }
        Expr::IntLit(n) => { h.update(b"int\x00"); h.update(n.to_string().as_bytes()); }
        Expr::StrLit(s) => { h.update(b"str\x00"); h.update(s.as_bytes()); }
        Expr::SymLit(s) => { h.update(b"sym\x00"); h.update(s.as_bytes()); }
        Expr::Lambda { param, body } => {
            h.update(b"lam\x00"); h.update(param.as_bytes()); h.update(b"\x00");
            h.update(hash_expr(body).as_bytes());
        }
        Expr::Apply { func, arg } => {
            h.update(b"app\x00");
            h.update(hash_expr(func).as_bytes()); h.update(b"\x00");
            h.update(hash_expr(arg).as_bytes());
        }
        Expr::If { cond, then, elze } => {
            h.update(b"if\x00");
            h.update(hash_expr(cond).as_bytes()); h.update(b"\x00");
            h.update(hash_expr(then).as_bytes()); h.update(b"\x00");
            h.update(hash_expr(elze).as_bytes());
        }
        Expr::Record(fields) => {
            h.update(b"rec\x00");
            let mut sorted: Vec<&(String, Expr)> = fields.iter().collect();
            sorted.sort_by(|a, b| a.0.cmp(&b.0));
            for (name, fe) in sorted {
                h.update(name.as_bytes()); h.update(b"\x00");
                h.update(hash_expr(fe).as_bytes());
            }
        }
        Expr::Field { record, name } => {
            h.update(b"field\x00");
            h.update(hash_expr(record).as_bytes()); h.update(b"\x00");
            h.update(name.as_bytes());
        }
        Expr::Pipe { left, right } => {
            h.update(b"pipe\x00");
            h.update(hash_expr(left).as_bytes()); h.update(b"\x00");
            h.update(hash_expr(right).as_bytes());
        }
        Expr::ListLit(items) => {
            h.update(b"list\x00");
            for item in items {
                h.update(hash_expr(item).as_bytes());
            }
        }
    }
    format!("{:x}", h.finalize())
}

thread_local! {
    static HASHING_THUNKS: std::cell::RefCell<std::collections::HashSet<*const ThunkState>> = Default::default();
}

fn hash_value(v: &Value, ev: &mut Evaluator) -> String {
    use sha2::{Sha256, Digest};

    // Handle Thunks specially: hash their structure, don't force
    if let Value::Thunk(t) = v {
        let ptr = Arc::as_ptr(t) as *const ThunkState;
        if HASHING_THUNKS.with(|s| s.borrow().contains(&ptr)) {
            return "sha256:cycle".into();
        }
        HASHING_THUNKS.with(|s| s.borrow_mut().insert(ptr));
        let result = compute_thunk_hash(t, ev);
        HASHING_THUNKS.with(|s| s.borrow_mut().remove(&ptr));
        return result;
    }

    let v = ev.force_pure(v.clone());
    let mut h = Sha256::new();
    match &v {
        Value::Int(n) => { h.update(b"int\x00"); h.update(n.to_string().as_bytes()); }
        Value::Str(s) => { h.update(b"str\x00"); h.update(s.as_bytes()); }
        Value::Symbol(s) => { h.update(b"sym\x00"); h.update(s.as_bytes()); }
        Value::Record(fields) => {
            h.update(b"rec\x00");
            let mut keys: Vec<&Arc<str>> = fields.keys().collect();
            keys.sort();
            for k in keys {
                h.update(k.as_bytes()); h.update(b"\x00");
                h.update(hash_value(fields.get(k).unwrap(), ev).as_bytes());
            }
        }
        Value::Closure { param, body, .. } => {
            h.update(b"lam\x00"); h.update(param.as_bytes());
            h.update(b"\x00"); h.update(hash_expr(body).as_bytes());
        }
        Value::Builtin { name, .. } => {
            h.update(b"builtin\x00"); h.update(name.as_bytes());
        }
        Value::Derivation(d) => {
            h.update(b"deriv\x00");
            h.update(hash_value(&d.spec, ev).as_bytes());
        }
        Value::Thunk(_) => { h.update(b"thunk\x00"); }
    }
    format!("{:x}", h.finalize())
}

// ── Free variables ────────────────────────────────────────────────

fn free_vars(e: &Expr) -> HashSet<Arc<str>> {
    match e {
        Expr::Name(n) => { let mut s = HashSet::new(); s.insert(Arc::from(n.as_str())); s }
        Expr::IntLit(_) | Expr::StrLit(_) | Expr::SymLit(_) => HashSet::new(),
        Expr::Lambda { param, body } => {
            let mut fv = free_vars(body);
            fv.remove(param.as_str());
            fv
        }
        Expr::Apply { func, arg } => {
            let mut fv = free_vars(func);
            fv.extend(free_vars(arg));
            fv
        }
        Expr::If { cond, then, elze } => {
            let mut fv = free_vars(cond);
            fv.extend(free_vars(then));
            fv.extend(free_vars(elze));
            fv
        }
        Expr::Record(fields) => {
            let mut fv = HashSet::new();
            for (_, fe) in fields { fv.extend(free_vars(fe)); }
            fv
        }
        Expr::Field { record, .. } => free_vars(record),
        Expr::Pipe { left, right } => {
            let mut fv = free_vars(left);
            fv.extend(free_vars(right));
            fv
        }
        Expr::ListLit(items) => {
            let mut fv = HashSet::new();
            for item in items { fv.extend(free_vars(item)); }
            fv
        }
    }
}

// ── Template substitution ─────────────────────────────────────────


fn substitute(body: &Expr, param: &str, arg: &Expr) -> Expr {
    match body {
        Expr::Name(n) if n == param => arg.clone(),
        Expr::Name(_) | Expr::IntLit(_) | Expr::StrLit(_) | Expr::SymLit(_) => body.clone(),
        Expr::Lambda { param: p, body: b } if p == param => body.clone(),
        Expr::Lambda { param: p, body: b } => Expr::Lambda {
            param: p.clone(),
            body: Box::new(substitute(b, param, arg)),
        },
        Expr::Apply { func, arg: a } => Expr::Apply {
            func: Box::new(substitute(func, param, arg)),
            arg: Box::new(substitute(a, param, arg)),
        },
        Expr::If { cond, then, elze } => Expr::If {
            cond: Box::new(substitute(cond, param, arg)),
            then: Box::new(substitute(then, param, arg)),
            elze: Box::new(substitute(elze, param, arg)),
        },
        Expr::Record(fields) => Expr::Record(
            fields.iter().map(|(n, fe)| (n.clone(), substitute(fe, param, arg))).collect()
        ),
        Expr::Field { record, name } => Expr::Field {
            record: Box::new(substitute(record, param, arg)),
            name: name.clone(),
        },
        Expr::Pipe { left, right } => Expr::Pipe {
            left: Box::new(substitute(left, param, arg)),
            right: Box::new(substitute(right, param, arg)),
        },
        Expr::ListLit(items) => Expr::ListLit(
            items.iter().map(|i| substitute(i, param, arg)).collect()
        ),
    }
}

// ── Serialization ─────────────────────────────────────────────────

use serde_json::Value as Json;

fn val_to_json(v: &Value) -> Option<Json> {
    match v {
        Value::Int(n) => Some(serde_json::json!({"t":"int","v":*n})),
        Value::Str(s) => Some(serde_json::json!({"t":"str","v":s.as_ref()})),
        Value::Symbol(s) => Some(serde_json::json!({"t":"sym","v":s.as_ref()})),
        Value::Record(fields) => {
            if is_error(v) {
                let kind = fields.get("tag").and_then(|t| match t { Value::Symbol(s) => Some(s.clone()), _ => None });
                let msg = fields.get("message").and_then(|m| match m { Value::Str(s) => Some(s.clone()), _ => None });
                return Some(serde_json::json!({"t":"error","k":kind.as_ref().unwrap_or(&Arc::from("?")).as_ref(), "m":msg.as_ref().unwrap_or(&Arc::from("")).as_ref()}));
            }
            let mut jfields = serde_json::Map::new();
            for (k, fv) in fields.iter() {
                let d = val_to_json(fv)?;
                jfields.insert(k.to_string(), d);
            }
            Some(Json::Object(serde_json::json!({"t":"rec","v":jfields}).as_object().unwrap().clone()))
        }
        _ => None,
    }
}

fn val_from_json(j: &Json) -> Option<Value> {
    let t = j.get("t")?.as_str()?;
    match t {
        "int" => Some(Value::Int(j.get("v")?.as_i64()?)),
        "str" => Some(Value::Str(Arc::from(j.get("v")?.as_str()?))),
        "sym" => Some(Value::Symbol(Arc::from(j.get("v")?.as_str()?))),
        "error" => {
            let k = j.get("k")?.as_str()?;
            let m = j.get("m")?.as_str()?;
            Some(mk_error(k, m))
        }
        "rec" => {
            let v = j.get("v")?.as_object()?;
            let mut fields = HashMap::new();
            for (k, jv) in v {
                fields.insert(Arc::from(k.as_str()), val_from_json(jv)?);
            }
            Some(Value::Record(Arc::new(fields)))
        }
        _ => None,
    }
}

fn save_to_store(h: &str, v: &Value, store_path: &str) {
    let j = match val_to_json(v) {
        Some(j) => j,
        None => return,
    };
    let body = h.strip_prefix("sha256:").unwrap_or(h);
    let dir = format!("{}/{}", store_path, &body[..2]);
    let _ = std::fs::create_dir_all(&dir);
    let path = format!("{}/{}.json", dir, body);
    if let Ok(s) = serde_json::to_string(&j) {
        let _ = std::fs::write(&path, s);
    }
}

fn load_from_store(h: &str, store_path: &str) -> Option<Value> {
    let body = h.strip_prefix("sha256:").unwrap_or(h);
    let path = format!("{}/{}/{}.json", store_path, &body[..2], body);
    let data = std::fs::read_to_string(&path).ok()?;
    let j: Json = serde_json::from_str(&data).ok()?;
    val_from_json(&j)
}
