use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::rc::Rc;
use std::sync::Arc;
use crate::ast::Expr;

// ── Value types ────────────────────────────────────────────────────

#[derive(Clone)]
pub enum Value {
    Int(i64),
    Str(Arc<str>),
    Symbol(Arc<str>),
    Record(Arc<HashMap<Arc<str>, Value>>),
    Closure {
        param: Arc<str>,
        body: Arc<Expr>,
        env: FrameId,
    },
    Builtin {
        name: Arc<str>,
        arity: usize,
        args: Vec<Value>,
        func: BuiltinFn,
    },
    Derivation(Arc<DerivState>),
    Thunk(Arc<ThunkState>),
}

pub type BuiltinFn = Rc<dyn Fn(&[Value], &mut Evaluator) -> Value>;

pub struct DerivState {
    pub spec: Value,
    pub cached: RefCell<Option<Value>>,
    pub hash: RefCell<Option<String>>,
}

pub struct ThunkState {
    pub expr: Arc<Expr>,
    pub env: RefCell<FrameId>,
    pub free: HashSet<Arc<str>>,
    pub cached: RefCell<Option<Value>>,
    pub hash: RefCell<Option<String>>,
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Value::Int(n) => write!(f, "{}", n),
            Value::Str(s) => write!(f, "{:?}", s),
            Value::Symbol(s) => write!(f, ":{}", s),
            Value::Record(fields) => {
                write!(f, "{{")?;
                for (i, (k, v)) in fields.iter().enumerate() {
                    if i > 0 { write!(f, "; ")?; }
                    write!(f, "{} = {:?}", k, v)?;
                }
                write!(f, "}}")
            }
            Value::Closure { param, .. } => write!(f, "<fn \\{}>", param),
            Value::Builtin { name, .. } => write!(f, "<fn {}>", name),
            Value::Derivation(d) => {
                if let Some(cached) = d.cached.borrow().as_ref() {
                    write!(f, "{:?}", cached)
                } else {
                    write!(f, "<derivation>")
                }
            }
            Value::Thunk(t) => {
                if let Some(cached) = t.cached.borrow().as_ref() {
                    write!(f, "{:?}", cached)
                } else {
                    write!(f, "<thunk>")
                }
            }
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

impl Value {
    pub fn kind_name(&self) -> &'static str {
        match self {
            Value::Int(_) => "int",
            Value::Str(_) => "str",
            Value::Symbol(_) => "symbol",
            Value::Record(_) => "record",
            Value::Closure { .. } | Value::Builtin { .. } => "fn",
            Value::Derivation(_) => "derivation",
            Value::Thunk(_) => "thunk",
        }
    }
}

impl std::cmp::PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Value::Int(a), Value::Int(b)) => a == b,
            (Value::Str(a), Value::Str(b)) => a.as_ref() == b.as_ref(),
            (Value::Symbol(a), Value::Symbol(b)) => a.as_ref() == b.as_ref(),
            (Value::Record(a), Value::Record(b)) => {
                a.len() == b.len() && a.iter().all(|(k, v)| b.get(k) == Some(v))
            }
            _ => false,
        }
    }
}

// ── Environment frames ─────────────────────────────────────────────

pub type FrameId = usize;

pub struct EnvFrame {
    pub bindings: HashMap<Arc<str>, Value>,
    pub parent: Option<FrameId>,
}

impl EnvFrame {
    pub fn new(bindings: HashMap<Arc<str>, Value>, parent: Option<FrameId>) -> Self {
        EnvFrame { bindings, parent }
    }
}

// ── Evaluator (forward declaration for the value module) ──────────

// We need to use Evaluator inside BuiltinFn closures, so this type
// is forward-referenced. The actual Evaluator struct is in eval.rs.
pub struct Evaluator {
    pub frames: Vec<EnvFrame>,
    pub cache: HashMap<String, Value>,
    pub current_frame: FrameId,
    pub store_path: Option<String>,
    pub true_val: Value,
    pub false_val: Value,
    pub nil_val: Value,
}
