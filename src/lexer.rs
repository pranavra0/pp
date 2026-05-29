use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum TokenType {
    Lambda, Dot, LParen, RParen, LBrace, RBrace, LBracket, RBracket,
    Equals, Comma, Semicolon, Colon,
    Bind, Pipe,
    If,
    Name, Symbol, Number, String,
    Eof,
}

#[derive(Debug, Clone)]
pub struct Token {
    pub ty: TokenType,
    pub lexeme: String,
    pub line: usize,
    pub col: usize,
}

impl fmt::Display for Token {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "Token({:?}, {:?}, L{}:{})", self.ty, self.lexeme, self.line, self.col)
    }
}

pub struct Lexer {
    source: Vec<char>,
    pos: usize,
    line: usize,
    col: usize,
}

impl Lexer {
    pub fn new(source: &str) -> Self {
        Lexer {
            source: source.chars().collect(),
            pos: 0,
            line: 1,
            col: 1,
        }
    }

    fn peek(&self) -> Option<char> {
        self.source.get(self.pos).copied()
    }

    fn advance(&mut self) -> char {
        let ch = self.source[self.pos];
        self.pos += 1;
        if ch == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        ch
    }

    fn error(&self, msg: &str) -> String {
        format!("{} at line {}, col {}", msg, self.line, self.col)
    }

    fn skip_whitespace(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn skip_comment(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == '\n' { break; }
            self.advance();
        }
    }

    fn read_string(&mut self, quote: char) -> Result<String, String> {
        let mut chars = Vec::new();
        loop {
            match self.peek() {
                None => return Err(self.error("Unterminated string")),
                Some('\\') => {
                    self.advance();
                    match self.advance() {
                        'n' => chars.push('\n'),
                        't' => chars.push('\t'),
                        '\\' => chars.push('\\'),
                        '"' => chars.push('"'),
                        c => chars.push(c),
                    }
                }
                Some(ch) if ch == quote => {
                    self.advance();
                    break;
                }
                Some(_) => chars.push(self.advance()),
            }
        }
        Ok(chars.into_iter().collect())
    }

    fn read_number(&mut self) -> String {
        let mut chars = Vec::new();
        let mut has_dot = false;
        while let Some(ch) = self.peek() {
            if ch.is_ascii_digit() {
                chars.push(self.advance());
            } else if ch == '.' && !has_dot {
                has_dot = true;
                chars.push(self.advance());
            } else {
                break;
            }
        }
        chars.into_iter().collect()
    }

    fn read_name(&mut self) -> String {
        let mut chars = Vec::new();
        while let Some(ch) = self.peek() {
            if ch.is_alphanumeric() || ch == '_' || ch == '-' || ch == '+'
                || ch == '*' || ch == '/' || ch == '%' || ch == '?'
                || ch == '@' || ch == '$' || ch == '&' || ch == '~'
                || ch == '^' || ch == '#' || ch == '!'
            {
                chars.push(self.advance());
            } else {
                break;
            }
        }
        chars.into_iter().collect()
    }

    pub fn tokenize(&mut self) -> Result<Vec<Token>, String> {
        let mut tokens = Vec::new();
        while self.pos < self.source.len() {
            self.skip_whitespace();
            let ch = match self.peek() {
                None => break,
                Some(c) => c,
            };

            // Comments
            if ch == '#' {
                self.skip_comment();
                continue;
            }

            // :=
            if ch == ':' {
                self.advance();
                if self.peek() == Some('=') {
                    self.advance();
                    tokens.push(Token { ty: TokenType::Bind, lexeme: ":=".into(), line: self.line, col: self.col - 2 });
                } else if matches!(self.peek(), Some(c) if c.is_alphanumeric()) {
                    let name = self.read_name();
                    tokens.push(Token { ty: TokenType::Symbol, lexeme: name, line: self.line, col: self.col - 1 });
                } else {
                    tokens.push(Token { ty: TokenType::Colon, lexeme: ":".into(), line: self.line, col: self.col - 1 });
                }
                continue;
            }

            // |>
            if ch == '|' {
                self.advance();
                if self.peek() == Some('>') {
                    self.advance();
                    tokens.push(Token { ty: TokenType::Pipe, lexeme: "|>".into(), line: self.line, col: self.col - 2 });
                } else {
                    return Err(self.error("Unexpected character after '|'"));
                }
                continue;
            }

            // Single-char tokens
            match ch {
                '\\' => { self.advance(); tokens.push(Token { ty: TokenType::Lambda, lexeme: "\\".into(), line: self.line, col: self.col - 1 }); }
                '.' => { self.advance(); tokens.push(Token { ty: TokenType::Dot, lexeme: ".".into(), line: self.line, col: self.col - 1 }); }
                '(' => { self.advance(); tokens.push(Token { ty: TokenType::LParen, lexeme: "(".into(), line: self.line, col: self.col - 1 }); }
                ')' => { self.advance(); tokens.push(Token { ty: TokenType::RParen, lexeme: ")".into(), line: self.line, col: self.col - 1 }); }
                '{' => { self.advance(); tokens.push(Token { ty: TokenType::LBrace, lexeme: "{".into(), line: self.line, col: self.col - 1 }); }
                '}' => { self.advance(); tokens.push(Token { ty: TokenType::RBrace, lexeme: "}".into(), line: self.line, col: self.col - 1 }); }
                '[' => { self.advance(); tokens.push(Token { ty: TokenType::LBracket, lexeme: "[".into(), line: self.line, col: self.col - 1 }); }
                ']' => { self.advance(); tokens.push(Token { ty: TokenType::RBracket, lexeme: "]".into(), line: self.line, col: self.col - 1 }); }
                '=' => { self.advance(); tokens.push(Token { ty: TokenType::Equals, lexeme: "=".into(), line: self.line, col: self.col - 1 }); }
                ',' => { self.advance(); tokens.push(Token { ty: TokenType::Comma, lexeme: ",".into(), line: self.line, col: self.col - 1 }); }
                ';' => { self.advance(); tokens.push(Token { ty: TokenType::Semicolon, lexeme: ";".into(), line: self.line, col: self.col - 1 }); }
                '"' => {
                    self.advance();
                    let value = self.read_string('"')?;
                    tokens.push(Token { ty: TokenType::String, lexeme: value, line: self.line, col: self.col });
                }
                c if c.is_ascii_digit() || (c == '-' && self.pos + 1 < self.source.len() && self.source[self.pos + 1].is_ascii_digit()) => {
                    let start_col = self.col;
                    let mut negative = false;
                    if c == '-' {
                        negative = true;
                        self.advance();
                    }
                    let value = self.read_number();
                    let lexeme = if negative { format!("-{}", value) } else { value };
                    tokens.push(Token { ty: TokenType::Number, lexeme, line: self.line, col: start_col });
                }
                c if c.is_alphabetic() || c == '_' || "+-*/%?@$&~^#!".contains(c) => {
                    let start_col = self.col;
                    let name = self.read_name();
                    let ty = if name == "if" { TokenType::If } else { TokenType::Name };
                    tokens.push(Token { ty, lexeme: name, line: self.line, col: start_col });
                }
                _ => return Err(self.error(&format!("Unexpected character: {:?}", ch))),
            }
        }
        tokens.push(Token { ty: TokenType::Eof, lexeme: String::new(), line: self.line, col: self.col });
        Ok(tokens)
    }
}
