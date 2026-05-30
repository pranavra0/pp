use crate::ast::{Expr, InterpPart};
use crate::lexer::{Lexer, Token, TokenType};

pub struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    pub fn new(tokens: Vec<Token>) -> Self {
        Parser { tokens, pos: 0 }
    }

    fn peek(&self) -> Option<&TokenType> {
        self.tokens.get(self.pos).map(|t| &t.ty)
    }

    fn peek_token(&self) -> Option<&Token> {
        self.tokens.get(self.pos)
    }

    fn consume(&mut self, expected: TokenType, msg: &str) -> Result<Token, String> {
        if self.peek() == Some(&expected) {
            let tok = self.tokens[self.pos].clone();
            self.pos += 1;
            Ok(tok)
        } else {
            match self.peek_token() {
                Some(t) => Err(format!("{} at line {}, col {}", msg, t.line, t.col)),
                None => Err(format!("{} at end of input", msg)),
            }
        }
    }

    fn matches(&mut self, types: &[TokenType]) -> bool {
        if self.peek().map_or(false, |t| types.contains(t)) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn parse_interpolated_parts(&self, lexeme: &str, line: usize, col: usize) -> Result<Vec<InterpPart>, String> {
        let mut parts = Vec::new();
        let chars: Vec<char> = lexeme.chars().collect();
        let mut i = 0;
        let mut literal_start = 0;

        while i < chars.len() {
            if chars[i] == '{' {
                // Check for {{ (escaped brace -> literal {)
                if i + 1 < chars.len() && chars[i + 1] == '{' {
                    // Push literal text before this pair
                    if i > literal_start {
                        let lit: String = chars[literal_start..i].iter().collect();
                        parts.push(InterpPart::Literal(lit));
                    }
                    // {{ becomes a single { — push as literal
                    parts.push(InterpPart::Literal("{".to_string()));
                    i += 2;
                    literal_start = i;
                    continue;
                }

                // Push literal text before this expression
                if i > literal_start {
                    let lit: String = chars[literal_start..i].iter().collect();
                    parts.push(InterpPart::Literal(lit));
                }

                // Find matching }
                let expr_start = i + 1;
                let mut depth = 1;
                let mut expr_end = expr_start;
                while expr_end < chars.len() && depth > 0 {
                    if chars[expr_end] == '{' {
                        depth += 1;
                    } else if chars[expr_end] == '}' {
                        // Check for }} (escaped brace -> literal })
                        if depth == 1 && expr_end + 1 < chars.len() && chars[expr_end + 1] == '}' {
                            // }} inside expression is not valid — treat as closing brace
                            // Actually, }} inside the expression doesn't make sense as escape
                            depth -= 1;
                        } else {
                            depth -= 1;
                        }
                    }
                    if depth > 0 {
                        expr_end += 1;
                    }
                }

                if depth != 0 {
                    return Err(format!("Unterminated interpolation expression in string at line {}, col {}", line, col));
                }

                // Parse the expression
                let expr_text: String = chars[expr_start..expr_end].iter().collect();
                let sub_tokens = Lexer::new(&expr_text).tokenize()
                    .map_err(|e| format!("In interpolation expression: {}", e))?;
                let mut sub_parser = Parser::new(sub_tokens);
                let (_, expr) = sub_parser.parse()
                    .map_err(|e| format!("In interpolation expression: {}", e))?;
                match expr {
                    Some(e) => parts.push(InterpPart::Expr(Box::new(e))),
                    None => return Err("Empty interpolation expression".into()),
                }

                i = expr_end + 1; // skip past }
                literal_start = i;
            } else if chars[i] == '}' {
                // Check for }} (escaped brace -> literal })
                if i + 1 < chars.len() && chars[i + 1] == '}' {
                    if i > literal_start {
                        let lit: String = chars[literal_start..i].iter().collect();
                        parts.push(InterpPart::Literal(lit));
                    }
                    parts.push(InterpPart::Literal("}".to_string()));
                    i += 2;
                    literal_start = i;
                    continue;
                }
                // Lone } outside expression — treat as literal
                i += 1;
            } else {
                i += 1;
            }
        }

        // Trailing literal
        if literal_start < chars.len() {
            let lit: String = chars[literal_start..].iter().collect();
            parts.push(InterpPart::Literal(lit));
        }

        Ok(parts)
    }

    pub fn parse(&mut self) -> Result<(Vec<(String, Expr)>, Option<Expr>), String> {
        let mut bindings = Vec::new();
        while self.peek() == Some(&TokenType::Name)
            && self.pos + 1 < self.tokens.len()
            && self.tokens[self.pos + 1].ty == TokenType::Bind
        {
            let name_tok = self.consume(TokenType::Name, "Expected name")?;
            self.consume(TokenType::Bind, "Expected ':='")?;
            let value = self.parse_expr()?;
            self.consume(TokenType::Semicolon, "Expected ';' after binding")?;
            bindings.push((name_tok.lexeme.clone(), value));
        }
        let expr = if self.peek() != Some(&TokenType::Eof) {
            Some(self.parse_expr()?)
        } else {
            None
        };
        self.consume(TokenType::Eof, "Expected end of input")?;
        Ok((bindings, expr))
    }

    fn parse_expr(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_app()?;
        while self.matches(&[TokenType::Pipe]) {
            let right = self.parse_app()?;
            left = Expr::Pipe { left: Box::new(left), right: Box::new(right) };
        }
        Ok(left)
    }

    fn parse_app(&mut self) -> Result<Expr, String> {
        let mut left = self.parse_atom()?;
        let stop = &[
            TokenType::Semicolon, TokenType::Comma,
            TokenType::RBrace, TokenType::RBracket,
            TokenType::RParen, TokenType::Pipe,
            TokenType::Eof, TokenType::Bind,
        ];
        while self.peek().map_or(false, |t| !stop.contains(t)) {
            if self.peek() == Some(&TokenType::Dot) {
                break;
            }
            let right = self.parse_atom()?;
            left = Expr::Apply { func: Box::new(left), arg: Box::new(right) };
        }
        Ok(left)
    }

    fn parse_atom(&mut self) -> Result<Expr, String> {
        let tok = match self.peek_token() {
            Some(t) => t.clone(),
            None => return Err("Unexpected end of input".into()),
        };

        let mut node = match &tok.ty {
            TokenType::Lambda => {
                self.pos += 1;
                let param_tok = self.consume(TokenType::Name, "Expected parameter name after '\\'")?;
                self.consume(TokenType::Dot, "Expected '.' after lambda parameter")?;
                let body = self.parse_expr()?;
                Expr::Lambda { param: param_tok.lexeme.clone(), body: Box::new(body) }
            }
            TokenType::LParen => {
                self.pos += 1;
                let node = self.parse_expr()?;
                self.consume(TokenType::RParen, "Expected ')'")?;
                node
            }
            TokenType::LBrace => {
                self.pos += 1;
                let mut fields = Vec::new();
                while self.peek() != Some(&TokenType::RBrace) && self.peek() != Some(&TokenType::Eof) {
                    let name_tok = self.consume(TokenType::Name, "Expected field name")?;
                    self.consume(TokenType::Equals, "Expected '=' in record field")?;
                    let value = self.parse_expr()?;
                    self.consume(TokenType::Semicolon, "Expected ';' after record field")?;
                    fields.push((name_tok.lexeme.clone(), value));
                }
                self.consume(TokenType::RBrace, "Expected '}'")?;
                Expr::Record(fields)
            }
            TokenType::LBracket => {
                self.pos += 1;
                let mut items = Vec::new();
                while self.peek() != Some(&TokenType::RBracket) && self.peek() != Some(&TokenType::Eof) {
                    items.push(self.parse_expr()?);
                    let _ = self.matches(&[TokenType::Comma]);
                }
                self.consume(TokenType::RBracket, "Expected ']'")?;
                Expr::ListLit(items)
            }
            TokenType::If => {
                self.pos += 1;
                let cond = self.parse_atom()?;
                let then = self.parse_atom()?;
                let elze = self.parse_atom()?;
                Expr::If { cond: Box::new(cond), then: Box::new(then), elze: Box::new(elze) }
            }
            TokenType::Name => {
                self.pos += 1;
                Expr::Name(tok.lexeme.clone())
            }
            TokenType::Number => {
                self.pos += 1;
                let lexeme = &tok.lexeme;
                let (negative, body) = if lexeme.starts_with('-') {
                    (true, &lexeme[1..])
                } else {
                    (false, lexeme.as_str())
                };
                let abs = if body.starts_with("0x") || body.starts_with("0X") {
                    let digits: String = body.chars().skip(2).filter(|c| *c != '_').collect();
                    i64::from_str_radix(&digits, 16)
                        .map_err(|e| format!("Bad hex number '{}': {}", lexeme, e))?
                } else if body.starts_with("0o") || body.starts_with("0O") {
                    let digits: String = body.chars().skip(2).filter(|c| *c != '_').collect();
                    i64::from_str_radix(&digits, 8)
                        .map_err(|e| format!("Bad octal number '{}': {}", lexeme, e))?
                } else if body.starts_with("0b") || body.starts_with("0B") {
                    let digits: String = body.chars().skip(2).filter(|c| *c != '_').collect();
                    i64::from_str_radix(&digits, 2)
                        .map_err(|e| format!("Bad binary number '{}': {}", lexeme, e))?
                } else {
                    let digits: String = body.chars().filter(|c| *c != '_').collect();
                    digits.parse::<i64>()
                        .map_err(|e| format!("Bad number '{}': {}", lexeme, e))?
                };
                Expr::IntLit(if negative { -abs } else { abs })
            }
            TokenType::String => {
                self.pos += 1;
                if tok.interpolated {
                    let parts = self.parse_interpolated_parts(&tok.lexeme, tok.line, tok.col)?;
                    Expr::InterpolatedStr(parts)
                } else {
                    Expr::StrLit(tok.lexeme.clone())
                }
            }
            TokenType::Symbol => {
                self.pos += 1;
                Expr::SymLit(tok.lexeme.clone())
            }
            _ => return Err(format!("Unexpected token {:?} ({}) at line {}, col {}", tok.ty, tok.lexeme, tok.line, tok.col)),
        };

        // Postfix field access
        while self.peek() == Some(&TokenType::Dot) {
            self.pos += 1;
            let name_tok = self.consume(TokenType::Name, "Expected field name after '.'")?;
            node = Expr::Field { record: Box::new(node), name: name_tok.lexeme.clone() };
        }

        Ok(node)
    }
}
