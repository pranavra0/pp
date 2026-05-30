#[derive(Debug, Clone, PartialEq)]
pub enum InterpPart {
    Literal(String),
    Expr(Box<Expr>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Name(String),
    IntLit(i64),
    StrLit(String),
    SymLit(String),
    Lambda { param: String, body: Box<Expr> },
    Apply { func: Box<Expr>, arg: Box<Expr> },
    If { cond: Box<Expr>, then: Box<Expr>, elze: Box<Expr> },
    Record(Vec<(String, Expr)>),
    Field { record: Box<Expr>, name: String },
    Pipe { left: Box<Expr>, right: Box<Expr> },
    ListLit(Vec<Expr>),
    InterpolatedStr(Vec<InterpPart>),
}
