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
        // self.peek() is '#' — consume it first
        self.advance();
        // Check if this is a block comment (#| ... |#)
        if self.peek() == Some('|') {
            self.advance(); // consume '|'
            self.skip_block_comment(1);
        } else {
            // Line comment: skip until newline or EOF
            while let Some(ch) = self.peek() {
                if ch == '\n' { break; }
                self.advance();
            }
        }
    }

    fn skip_block_comment(&mut self, depth: usize) {
        while let Some(ch) = self.peek() {
            match ch {
                '#' => {
                    self.advance();
                    if self.peek() == Some('|') {
                        self.advance();
                        self.skip_block_comment(depth + 1);
                    }
                }
                '|' => {
                    self.advance();
                    if self.peek() == Some('#') {
                        self.advance();
                        if depth == 1 {
                            return;
                        } else {
                            return self.skip_block_comment(depth - 1);
                        }
                    }
                }
                _ => {
                    self.advance();
                }
            }
        }
    }

    fn read_escape(&mut self) -> Result<char, String> {
        self.advance(); // consume '\\'
        match self.advance() {
            'n' => Ok('\n'),
            'r' => Ok('\r'),
            't' => Ok('\t'),
            '\\' => Ok('\\'),
            '"' => Ok('"'),
            '0' => Ok('\0'),
            'x' => {
                let hex = self.read_hex_digits(2)?;
                let byte = u8::from_str_radix(&hex, 16)
                    .map_err(|_| self.error(&format!("Invalid hex escape: \\x{}", hex)))?;
                Ok(byte as char)
            }
            'u' => {
                self.expect_char('{', "Expected '{' after \\u")?;
                let hex = self.read_hex_digits_until('}')?;
                if hex.is_empty() || hex.len() > 6 {
                    return Err(self.error("Invalid unicode escape: \\u{...} must have 1-6 hex digits"));
                }
                let code = u32::from_str_radix(&hex, 16)
                    .map_err(|_| self.error(&format!("Invalid unicode escape: \\u{{{}}}", hex)))?;
                char::from_u32(code)
                    .ok_or_else(|| self.error(&format!("Invalid unicode code point: U+{:X}", code)))
            }
            c => Err(self.error(&format!("Invalid escape sequence: \\{}", c))),
        }
    }

    fn read_string(&mut self, quote: char) -> Result<String, String> {
        let mut chars = Vec::new();
        loop {
            match self.peek() {
                None => return Err(self.error("Unterminated string")),
                Some('\\') => {
                    let c = self.read_escape()?;
                    chars.push(c);
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

    fn read_multiline_string(&mut self) -> Result<String, String> {
        // Already past the first '"' — we've consumed two '"' already
        // so we're now positioned after the opening """
        // Read the raw string content
        let mut raw = Vec::new();
        let closing_col;
        loop {
            match self.peek() {
                None => return Err(self.error("Unterminated multi-line string")),
                Some('\\') => {
                    let c = self.read_escape()?;
                    raw.push(c);
                }
                Some('"') => {
                    // Check for closing """
                    if self.pos + 2 < self.source.len()
                        && self.source[self.pos] == '"'
                        && self.source[self.pos + 1] == '"'
                        && self.source[self.pos + 2] == '"'
                    {
                        closing_col = self.col;
                        self.advance(); // '"'
                        self.advance(); // '"'
                        self.advance(); // '"'
                        break;
                    }
                    raw.push(self.advance());
                }
                Some(_) => raw.push(self.advance()),
            }
        }
        // Process whitespace stripping
        let content: String = raw.into_iter().collect();
        // Determine indentation from closing """ position
        let indent = if closing_col > 0 { closing_col - 1 } else { 0 };
        // Remove empty first line if content starts with newline
        let content = if content.starts_with('\n') {
            content[1..].to_string()
        } else {
            content
        };
        // Split, strip indent, remove trailing empty lines
        let mut lines: Vec<String> = content.split('\n').map(|line| {
            if indent > 0 {
                let trimmed = line.trim_start_matches(' ');
                let to_strip = indent.min(line.len() - trimmed.len());
                line[to_strip..].to_string()
            } else {
                line.to_string()
            }
        }).collect();
        // Remove trailing empty lines
        while lines.last().map_or(false, |l| l.is_empty()) {
            lines.pop();
        }
        Ok(lines.join("\n"))
    }

    fn read_raw_string(&mut self, hash_count: usize) -> Result<String, String> {
        let mut chars = Vec::new();
        loop {
            match self.peek() {
                None => return Err(self.error("Unterminated raw string")),
                Some('"') => {
                    // Check if " is followed by hash_count #'s (closing delimiter)
                    let is_close =
                        self.source.len() > self.pos + hash_count
                        && (0..=hash_count).all(|i| {
                            self.source[self.pos + i] == if i == 0 { '"' } else { '#' }
                        });
                    if is_close {
                        self.advance(); // consume '"'
                        for _ in 0..hash_count {
                            self.advance(); // consume #'s
                        }
                        break;
                    }
                    chars.push(self.advance());
                }
                Some(_) => chars.push(self.advance()),
            }
        }
        Ok(chars.into_iter().collect())
    }

    fn expect_char(&mut self, expected: char, msg: &str) -> Result<(), String> {
        match self.peek() {
            Some(ch) if ch == expected => {
                self.advance();
                Ok(())
            }
            Some(ch) => Err(self.error(&format!("{}: expected '{:?}', got '{:?}'", msg, expected, ch))),
            None => Err(self.error(&format!("{}: expected '{}', got EOF", msg, expected))),
        }
    }

    fn read_hex_digits(&mut self, count: usize) -> Result<String, String> {
        let mut hex = String::with_capacity(count);
        for _ in 0..count {
            match self.peek() {
                Some(c) if c.is_ascii_hexdigit() => hex.push(self.advance()),
                Some(c) => return Err(self.error(&format!("Expected hex digit, got '{}'", c))),
                None => return Err(self.error("Expected hex digit, got EOF")),
            }
        }
        Ok(hex)
    }

    fn read_hex_digits_until(&mut self, delimiter: char) -> Result<String, String> {
        let mut hex = String::new();
        loop {
            match self.peek() {
                Some(c) if c == delimiter => {
                    self.advance();
                    return Ok(hex);
                }
                Some(c) if c.is_ascii_hexdigit() => {
                    hex.push(self.advance());
                    if hex.len() > 6 {
                        return Err(self.error("Unicode escape has too many hex digits (max 6)"));
                    }
                }
                Some(c) => return Err(self.error(&format!("Expected hex digit or '}}', got '{}'", c))),
                None => return Err(self.error("Unterminated unicode escape")),
            }
        }
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

            // Raw strings: r"..." or r#"..."# or r##"..."## etc.
            if (ch == 'r' || ch == 'R') && self.pos + 1 < self.source.len() {
                let mut la = self.pos + 1;
                // Skip hashes to look for " after them
                while la < self.source.len() && self.source[la] == '#' {
                    la += 1;
                }
                if la < self.source.len() && self.source[la] == '"' {
                    let hash_count = la - self.pos - 1;
                    let start_col = self.col;
                    self.advance(); // consume r/R
                    for _ in 0..hash_count {
                        self.advance(); // consume #'s
                    }
                    self.advance(); // consume "
                    let value = self.read_raw_string(hash_count)?;
                    tokens.push(Token { ty: TokenType::String, lexeme: value, line: self.line, col: start_col });
                    continue;
                }
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
                    // Check for """ (multi-line string)
                    if self.peek() == Some('"') && self.pos + 1 < self.source.len() && self.source[self.pos + 1] == '"' {
                        self.advance(); // second '"'
                        self.advance(); // third '"'
                        let value = self.read_multiline_string()?;
                        tokens.push(Token { ty: TokenType::String, lexeme: value, line: self.line, col: self.col });
                    } else {
                        let value = self.read_string('"')?;
                        tokens.push(Token { ty: TokenType::String, lexeme: value, line: self.line, col: self.col });
                    }
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
