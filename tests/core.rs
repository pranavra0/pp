use pp::ast::Expr;
use pp::eval::{Evaluator, is_error};
use pp::lexer::{Lexer, TokenType};
use pp::parser::Parser;
use pp::value::Value;

use std::sync::Arc;

fn run(src: &str, load_stdlib: bool) -> Result<Option<Value>, String> {
    let mut ev = Evaluator::new(None);
    if load_stdlib {
        load_stdlib_into(&mut ev);
    }
    run_source(src, &mut ev)
}

fn run_source(src: &str, ev: &mut Evaluator) -> Result<Option<Value>, String> {
    let tokens = Lexer::new(src).tokenize()?;
    let (bindings, expr) = Parser::new(tokens).parse()?;
    let bindings: Vec<(String, Expr)> = bindings;
    Ok(ev.run(&bindings, expr.as_ref()))
}

fn load_stdlib_into(ev: &mut Evaluator) {
    let src = include_str!("../stdlib/std.pp");
    if let Ok(tokens) = Lexer::new(src).tokenize() {
        if let Ok((bindings, _)) = Parser::new(tokens).parse() {
            let bindings: Vec<(String, Expr)> = bindings;
            let _ = ev.run(&bindings, None);
        }
    }
}

fn run_expect(src: &str, load_stdlib: bool, expected: &str) {
    let result = run(src, load_stdlib);
    let val = match result {
        Ok(Some(v)) => v,
        Ok(None) => panic!("Expected {} but got none. src={:?}", expected, src),
        Err(e) => panic!("Expected {} but got error: {}. src={:?}", expected, e, src),
    };
    let repr = format!("{:?}", val);
    assert_eq!(repr, expected, "src={:?}, expected={:?}", src, expected);
}

fn run_error(src: &str, load_stdlib: bool, expected_kind: &str) {
    let result = run(src, load_stdlib);
    match result {
        Ok(Some(v)) => {
            assert!(is_error(&v), "Expected error but got {:?}", v);
            if let Value::Record(fields) = &v {
                if let Some(Value::Symbol(kind)) = fields.get("kind") {
                    assert_eq!(kind.as_ref(), expected_kind, "Expected error kind {}, got {}", expected_kind, kind);
                    return;
                }
            }
            panic!("Expected error but got {:?}", v);
        }
        Ok(None) => panic!("Expected error but got none"),
        Err(e) => panic!("Expected error {} but got parse error: {}", expected_kind, e),
    }
}

// ═══════════════════════════════════════════════════════════════════
// Lexer tests
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_lexer_numbers() {
    let tokens = Lexer::new("42").tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::Number);
}

#[test]
fn test_lexer_strings() {
    let tokens = Lexer::new("\"hello\"").tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::String);
}

#[test]
fn test_lexer_string_escapes() {
    // Basic escapes
    let tokens = Lexer::new("\"\\n\\t\\r\\\\\\\"\\0\"").tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "\n\t\r\\\"\0");
}

#[test]
fn test_lexer_string_hex_escape() {
    // Hex escape \x48 = 'H'
    let tokens = Lexer::new("\"\\x48\\x65\\x6c\\x6c\\x6f\"").tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "Hello");
}

#[test]
fn test_lexer_string_unicode_escape() {
    // Unicode escape \u{1f600} = grinning face
    let tokens = Lexer::new("\"\\u{1f600}\"").tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "\u{1f600}");
    // Also test simpler unicode
    let tokens = Lexer::new("\"\\u{41}\"").tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "A");
}

#[test]
fn test_lexer_string_invalid_escape() {
    // Invalid escape should error
    let result = Lexer::new("\"\\z\"").tokenize();
    assert!(result.is_err());
}

#[test]
fn test_lexer_string_invalid_hex() {
    // Invalid hex escape
    let result = Lexer::new("\"\\xGH\"").tokenize();
    assert!(result.is_err());
}

#[test]
fn test_lexer_string_invalid_unicode() {
    // Invalid unicode code point (too large)
    let result = Lexer::new("\"\\u{110000}\"").tokenize();
    assert!(result.is_err());
}

#[test]
fn test_lexer_multiline_string_basic() {
    // Basic multi-line string with whitespace stripping
    let src = "\"\"\"\n    hello world\n    \"\"\"";
    let tokens = Lexer::new(src).tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::String);
    assert_eq!(tokens[0].lexeme, "hello world");
}

#[test]
fn test_lexer_multiline_string_multiple_lines() {
    // Multi-line string with multiple lines
    let src = "\"\"\"\n    line one\n    line two\n    line three\n    \"\"\"";
    let tokens = Lexer::new(src).tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "line one\nline two\nline three");
}

#[test]
fn test_lexer_multiline_string_no_indent() {
    // Multi-line string with no extra indentation
    let src = "\"\"\"\nfirst\nsecond\n\"\"\"";
    let tokens = Lexer::new(src).tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "first\nsecond");
}

#[test]
fn test_lexer_multiline_string_escapes() {
    // Escape sequences work in multi-line strings
    let src = "\"\"\"\n    hello\\nworld\n    \"\"\"";
    let tokens = Lexer::new(src).tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "hello\nworld");
}

#[test]
fn test_lexer_multiline_string_unterminated() {
    // Unterminated multi-line string should error
    let src = "\"\"\"\n    hello";
    let result = Lexer::new(src).tokenize();
    assert!(result.is_err());
}

#[test]
fn test_lexer_raw_string_basic() {
    // Basic raw string: r"..." — backslash is literal, not escape
    let tokens = Lexer::new("r\"hello\\nworld\"").tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::String);
    assert_eq!(tokens[0].lexeme, "hello\\nworld");
}

#[test]
fn test_lexer_raw_string_windows_path() {
    // Windows paths with raw strings
    let tokens = Lexer::new("r\"C:\\\\Users\\\\name\\\\path\\\\to\\\\file\"").tokenize().unwrap();
    assert_eq!(tokens[0].lexeme, "C:\\\\Users\\\\name\\\\path\\\\to\\\\file");
}

#[test]
fn test_lexer_raw_string_with_hash() {
    // Raw string with hash delimiter: r#"..."#
    let tokens = Lexer::new("r#\"hello \"quote\" world\"#").tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::String);
    assert_eq!(tokens[0].lexeme, "hello \"quote\" world");
}

#[test]
fn test_lexer_raw_string_double_hash() {
    // Raw string with double hash delimiter: r##"..."##
    let tokens = Lexer::new("r##\"hello #\" world\"##").tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::String);
    assert_eq!(tokens[0].lexeme, "hello #\" world");
}

#[test]
fn test_lexer_raw_string_unterminated() {
    // Unterminated raw string should error
    let result = Lexer::new("r\"hello").tokenize();
    assert!(result.is_err());
}

#[test]
fn test_lexer_symbols() {
    let tokens = Lexer::new(":int").tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::Symbol);
}

#[test]
fn test_lexer_bind() {
    let tokens = Lexer::new("x := 1;").tokenize().unwrap();
    assert_eq!(tokens[1].ty, TokenType::Bind);
}

#[test]
fn test_lexer_pipe() {
    let tokens = Lexer::new("x |> f").tokenize().unwrap();
    assert_eq!(tokens[1].ty, TokenType::Pipe);
}

#[test]
fn test_lexer_lambda() {
    let tokens = Lexer::new("\\x.").tokenize().unwrap();
    assert_eq!(tokens[0].ty, TokenType::Lambda);
}

#[test]
fn test_lexer_comments() {
    let tokens = Lexer::new("+ 1 # comment\n 2").tokenize().unwrap();
    let names: Vec<_> = tokens.iter().filter(|t| t.ty == TokenType::Name).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn test_lexer_block_comment() {
    // Basic block comment
    let tokens = Lexer::new("+ 1 #| block comment |# 2").tokenize().unwrap();
    let names: Vec<_> = tokens.iter().filter(|t| t.ty == TokenType::Name).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn test_lexer_block_comment_nested() {
    // Nested block comments
    let tokens = Lexer::new("+ 1 #| outer #| inner |# still outer |# 2").tokenize().unwrap();
    let names: Vec<_> = tokens.iter().filter(|t| t.ty == TokenType::Name).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn test_lexer_block_comment_multiline() {
    // Multi-line block comment
    let tokens = Lexer::new("+ 1 #|\n   line one\n   line two\n |# 2").tokenize().unwrap();
    let names: Vec<_> = tokens.iter().filter(|t| t.ty == TokenType::Name).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn test_lexer_line_comment_after_block() {
    // Line comment after a block comment
    let tokens = Lexer::new("+ 1 #| block |# # line\n 2").tokenize().unwrap();
    let names: Vec<_> = tokens.iter().filter(|t| t.ty == TokenType::Name).collect();
    assert_eq!(names.len(), 1);
}

#[test]
fn test_lexer_empty() {
    let tokens = Lexer::new("").tokenize().unwrap();
    assert_eq!(tokens.len(), 1);
    assert_eq!(tokens[0].ty, TokenType::Eof);
}

// ═══════════════════════════════════════════════════════════════════
// Parser tests
// ═══════════════════════════════════════════════════════════════════

fn parse(src: &str) -> Result<(Vec<(String, Expr)>, Option<Expr>), String> {
    let tokens = Lexer::new(src).tokenize()?;
    Parser::new(tokens).parse()
}

#[test]
fn test_parse_int() {
    let (_, e) = parse("42").unwrap();
    assert!(matches!(e, Some(Expr::IntLit(42))));
}

#[test]
fn test_parse_string() {
    let (_, e) = parse("\"hi\"").unwrap();
    assert!(matches!(e, Some(Expr::StrLit(ref s)) if s == "hi"));
}

#[test]
fn test_parse_symbol() {
    let (_, e) = parse(":int").unwrap();
    assert!(matches!(e, Some(Expr::SymLit(ref s)) if s == "int"));
}

#[test]
fn test_parse_lambda() {
    let (_, e) = parse("\\x. x").unwrap();
    assert!(matches!(e, Some(Expr::Lambda { .. })));
}

#[test]
fn test_parse_apply() {
    let (_, e) = parse("f x").unwrap();
    assert!(matches!(e, Some(Expr::Apply { .. })));
}

#[test]
fn test_parse_pipe() {
    let (_, e) = parse("x |> f").unwrap();
    assert!(matches!(e, Some(Expr::Pipe { .. })));
}

#[test]
fn test_parse_if() {
    let (_, e) = parse("if true 42 0").unwrap();
    assert!(matches!(e, Some(Expr::If { .. })));
}

#[test]
fn test_parse_record() {
    let (_, e) = parse("{ x = 1; y = 2; }").unwrap();
    assert!(matches!(e, Some(Expr::Record(ref fields)) if fields.len() == 2));
}

#[test]
fn test_parse_bindings() {
    let (b, _e) = parse("x := 1; y := 2; x").unwrap();
    assert_eq!(b.len(), 2);
    assert_eq!(b[0].0, "x");
}

// ═══════════════════════════════════════════════════════════════════
// Eval basics
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_int_literal() {
    run_expect("42", false, "42");
}

#[test]
fn test_string_literal() {
    run_expect("\"hello\"", false, "\"hello\"");
}

#[test]
fn test_record_literal() {
    let val = run("{x = 1;}", false).unwrap().unwrap();
    let repr = format!("{:?}", val);
    assert!(repr.starts_with("{"), "expected record, got: {}", repr);
    assert!(repr.contains("x"));
}

#[test]
fn test_field_access() {
    run_expect("{x = 42;}.x", false, "42");
}

#[test]
fn test_lambda_apply() {
    run_expect("(\\x. x) 42", false, "42");
}

#[test]
fn test_pipe() {
    run_expect("42 |> \\x. x", false, "42");
}

#[test]
fn test_pipe_chain() {
    run_expect("41 |> \\x. int-add x 1", false, "42");
}

#[test]
fn test_undefined() {
    run_error("zxyz", false, "name");
}

#[test]
fn test_symbol() {
    let val = run(":int", false).unwrap().unwrap();
    match &val {
        Value::Symbol(s) => assert_eq!(s.as_ref(), "int"),
        _ => panic!("Expected symbol"),
    }
}

// ═══════════════════════════════════════════════════════════════════
// Arithmetic primitives
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_int_add() { run_expect("int-add 1 2", false, "3"); }
#[test]
fn test_int_sub() { run_expect("int-sub 5 3", false, "2"); }
#[test]
fn test_int_mul() { run_expect("int-mul 3 4", false, "12"); }
#[test]
fn test_int_div() { run_expect("int-div 10 2", false, "5"); }
#[test]
fn test_int_cmp_lt() { run_expect("int-cmp 1 2", false, "-1"); }
#[test]
fn test_int_cmp_eq() { run_expect("int-cmp 3 3", false, "0"); }
#[test]
fn test_int_cmp_gt() { run_expect("int-cmp 5 2", false, "1"); }
#[test]
fn test_div_by_zero() { run_error("int-div 1 0", false, "div-by-zero"); }
#[test]
fn test_int_type_error() { run_error("int-add 1 \"hi\"", false, "type"); }

// ═══════════════════════════════════════════════════════════════════
// String primitives
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_str_append() { run_expect("str-append \"hello \" \"world\"", false, "\"hello world\""); }
#[test]
fn test_str_length() { run_expect("str-length \"hello\"", false, "5"); }
#[test]
fn test_int_to_str() { run_expect("int-to-str 42", false, "\"42\""); }
#[test]
fn test_str_to_int() { run_expect("str-to-int \"42\"", false, "42"); }
#[test]
fn test_str_to_int_error() { run_error("str-to-int \"abc\"", false, "parse"); }

// ═══════════════════════════════════════════════════════════════════
// Truthiness / if
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_if_true() { run_expect("if true 42 0", false, "42"); }
#[test]
fn test_if_false() { run_expect("if false 0 42", false, "42"); }

#[test]
fn test_if_truthy_int() {
    // Lisp model: 0 is truthy
    run_expect("if 0 \"yes\" \"no\"", false, "\"yes\"");
}

#[test]
fn test_if_truthy_record() {
    run_expect("if {x = 1;} \"yes\" \"no\"", false, "\"yes\"");
}

#[test]
fn test_if_lazy_then() {
    // Then branch should not be evaluated if condition is false
    let val = run("if false (head nil) 42", false).unwrap().unwrap();
    assert_eq!(format!("{:?}", val), "42");
}

#[test]
fn test_if_lazy_else() {
    let val = run("if true 42 (head nil)", false).unwrap().unwrap();
    assert_eq!(format!("{:?}", val), "42");
}

// ═══════════════════════════════════════════════════════════════════
// eq? / type-of / error
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_eq_int_true() { run_expect("eq? 42 42", false, "{tag = :true}"); }
#[test]
fn test_eq_int_false() { run_expect("eq? 42 0", false, "{tag = :false}"); }
#[test]
fn test_eq_record() { run_expect("eq? {x = 1;} {x = 1;}", false, "{tag = :true}"); }

#[test]
fn test_typeof_int() {
    let val = run("type-of 42", false).unwrap().unwrap();
    assert!(matches!(&val, Value::Symbol(s) if s.as_ref() == "int"));
}

#[test]
fn test_typeof_str() {
    let val = run("type-of \"hi\"", false).unwrap().unwrap();
    assert!(matches!(&val, Value::Symbol(s) if s.as_ref() == "str"));
}

#[test]
fn test_typeof_record() {
    let val = run("type-of {x = 1;}", false).unwrap().unwrap();
    assert!(matches!(&val, Value::Symbol(s) if s.as_ref() == "record"));
}

#[test]
fn test_typeof_fn() {
    let val = run("type-of \\x. x", false).unwrap().unwrap();
    assert!(matches!(&val, Value::Symbol(s) if s.as_ref() == "fn"));
}

#[test]
fn test_typeof_tagged_record() {
    // Tagged records should return their tag as type
    let val = run("type-of {tag = :cons; head = 1;}", false).unwrap().unwrap();
    assert!(matches!(&val, Value::Symbol(s) if s.as_ref() == "cons"));
}

#[test]
fn test_error() {
    let val = run("error :type \"test error\"", false).unwrap().unwrap();
    assert!(is_error(&val));
    if let Value::Record(fields) = &val {
        let kind = fields.get("kind").unwrap();
        assert!(matches!(kind, Value::Symbol(s) if s.as_ref() == "type"));
    }
}

#[test]
fn test_error_propagation() {
    // Error from one arg should propagate
    run_error("int-add (error :type \"msg\") 2", false, "type");
}

// ═══════════════════════════════════════════════════════════════════
// Bindings
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_binding_simple() {
    run_expect("x := 42; x", false, "42");
}

#[test]
fn test_binding_multi() {
    run_expect("x := 1; y := 2; int-add x y", false, "3");
}

#[test]
fn test_recursive() {
    run_expect(
        "fact := \\n. if (eq? n 0) 1 (int-mul n (fact (int-sub n 1)));
         fact 5",
        false, "120",
    );
}

#[test]
fn test_mutual_recursion() {
    run_expect(
        "even? := \\n. if (eq? n 0) true (odd? (int-sub n 1));
         odd? := \\n. if (eq? n 0) false (even? (int-sub n 1));
         even? 6",
        false, "{tag = :true}",
    );
}

// ═══════════════════════════════════════════════════════════════════
// Stdlib (requires std.pp)
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_stdlib_not() { run_expect("not true", true, "{tag = :false}"); }
#[test]
fn test_stdlib_and() { run_expect("and true false", true, "{tag = :false}"); }
#[test]
fn test_stdlib_or() { run_expect("or false true", true, "{tag = :true}"); }

#[test]
fn test_stdlib_and_shortcircuit() {
    let val = run("and false (head nil)", true).unwrap().unwrap();
    assert!(!is_error(&val));
}

#[test]
fn test_stdlib_or_shortcircuit() {
    let val = run("or true (head nil)", true).unwrap().unwrap();
    match &val {
        Value::Record(fields) => {
            assert_eq!(fields.get("tag").unwrap(), &Value::Symbol(Arc::from("true")));
        }
        _ => panic!("expected true"),
    }
}

#[test]
fn test_stdlib_lt() { run_expect("lt 1 2", true, "{tag = :true}"); }
#[test]
fn test_stdlib_gt() { run_expect("gt 2 1", true, "{tag = :true}"); }

#[test]
fn test_stdlib_type_predicates() {
    run_expect("is-int 42", true, "{tag = :true}");
    run_expect("is-str \"hello\"", true, "{tag = :true}");
    run_expect("is-record {x = 1;}", true, "{tag = :true}");
    run_expect("is-fn (\\x. x)", true, "{tag = :true}");
}

#[test]
fn test_stdlib_list_ops() {
    run_expect("head (cons 1 nil)", true, "1");
    run_expect("is-nil nil", true, "{tag = :true}");
    run_expect("is-cons (cons 1 nil)", true, "{tag = :true}");
}

#[test]
fn test_stdlib_map() {
    run_expect("head (map (\\x. int-add x 1) [1, 2, 3])", true, "2");
}

#[test]
fn test_stdlib_foldl() {
    run_expect("foldl int-add 0 [1, 2, 3]", true, "6");
}

#[test]
fn test_stdlib_filter() {
    run_expect("head (filter (\\x. lt x 3) [1, 2, 3])", true, "1");
}

#[test]
fn test_stdlib_length() {
    run_expect("length [1, 2, 3]", true, "3");
}

#[test]
fn test_stdlib_sum() {
    run_expect("sum [1, 2, 3, 4, 5]", true, "15");
}

#[test]
fn test_stdlib_any() {
    run_expect("any (\\x. eq? x 3) [1, 2, 3]", true, "{tag = :true}");
    run_expect("any (\\x. eq? x 5) [1, 2, 3]", true, "{tag = :false}");
}

#[test]
fn test_stdlib_all() {
    run_expect("all (\\x. lt x 5) [1, 2, 3]", true, "{tag = :true}");
}

#[test]
fn test_stdlib_replicate() {
    run_expect("head (replicate 3 7)", true, "7");
}

#[test]
fn test_stdlib_range() {
    run_expect("head (range 0 3)", true, "0");
}

#[test]
fn test_stdlib_y() {
    run_expect(
        "Y (\\self. \\n. if (eq? n 0) 1 (int-mul n (self (int-sub n 1)))) 5",
        true, "120",
    );
}

#[test]
fn test_stdlib_reverse() {
    run_expect("head (reverse [1, 2, 3])", true, "3");
}

#[test]
fn test_stdlib_take() {
    run_expect("length (take 2 [1, 2, 3])", true, "2");
}

// ═══════════════════════════════════════════════════════════════════
// Derivation
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_construct_derivation() {
    let val = run("exec { kind = :wasm; module = \"test.wasm\"; }", false).unwrap().unwrap();
    assert!(matches!(&val, Value::Derivation(_)));
}

#[test]
fn test_derivation_wasm_execution() {
    let val = run("realize (exec { kind = :wasm; module = \"tests/hello.wat\"; })", false).unwrap().unwrap();
    match &val {
        Value::Record(fields) => {
            let stdout = fields.get("stdout").unwrap();
            assert_eq!(stdout, &Value::Str(Arc::from("Hello\n")));
            let ec = fields.get("exit-code").unwrap();
            assert_eq!(ec, &Value::Int(0));
        }
        _ => panic!("expected record, got {:?}", val),
    }
}

// ═══════════════════════════════════════════════════════════════════
// Import as derivation
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_import_as_derivation() {
    let val = run(
        "realize (exec { kind = :import; path = \"stdlib/std.pp\"; })",
        false,
    ).unwrap().unwrap();
    match &val {
        Value::Record(fields) => {
            assert!(fields.contains_key("map"), "stdlib should have map: {:?}", fields.keys());
            assert!(fields.contains_key("foldl"));
            assert!(fields.contains_key("filter"));
        }
        _ => panic!("expected record, got {:?}", val),
    }
}

#[test]
fn test_import_missing() {
    let val = run(
        "realize (exec { kind = :import; path = \"nonexistent.pp\"; })",
        false,
    ).unwrap().unwrap();
    assert!(is_error(&val));
}

// ═══════════════════════════════════════════════════════════════════
// Disk cache
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_disk_cache_persists() {
    let tmpdir = std::env::temp_dir().join(format!("pp-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmpdir);
    let mut ev = Evaluator::new(Some(tmpdir.to_str().unwrap().to_string()));

    let result = run_source("int-add 1 2", &mut ev).unwrap().unwrap();
    assert_eq!(result, Value::Int(3));

    // Check that cache files were created
    let mut file_count = 0;
    if let Ok(entries) = std::fs::read_dir(&tmpdir) {
        for _entry in entries.flatten() {
            file_count += 1;
        }
    }
    assert!(file_count > 0, "no cache files created");
    let _ = std::fs::remove_dir_all(&tmpdir);
}

// ═══════════════════════════════════════════════════════════════════
// Syntax sugar
// ═══════════════════════════════════════════════════════════════════

#[test]
fn test_list_literal_syntax() {
    run_expect("head [1, 2, 3]", true, "1");
    run_expect("length [1, 2, 3]", true, "3");
}

#[test]
fn test_field_access_on_literal() {
    run_expect("{x = 42;}.x", false, "42");
}

// ── Shadowing / substitution correctness ──

#[test]
fn test_lambda_shadowing() {
    // (\x. \x. x) 42 should evaluate to \x. x (inner lambda returned)
    // The outer x is shadowed by the inner x; substitution should NOT
    // strip the inner lambda's binder.
    let val = run("(\\x. \\x. x) 42", false).unwrap().unwrap();
    match &val {
        Value::Closure { param, .. } => {
            assert_eq!(param.as_ref(), "x", "should be a function binding x");
        }
        other => panic!("expected a closure, got: {:?}", other),
    }
    // Applying the result should work: (\x. \x. x) 42 99  = 99
    let src = "(\\x. \\x. x) 42 99";
    let result = run(src, false).unwrap().unwrap();
    assert_eq!(result, Value::Int(99), "inner lambda should return its argument");
}

#[test]
fn test_lambda_no_shadow() {
    // (\f. \x. f x) (\x. x) 42  = 42  (no shadowing)
    let src = "(\\f. \\x. f x) (\\x. x) 42";
    let result = run(src, false).unwrap().unwrap();
    assert_eq!(result, Value::Int(42));
}

#[test]
fn test_substitute_preserves_lambda_under_same_param() {
    // The substitute function must preserve a lambda when the parameter
    // being substituted matches the lambda's binder (shadowing).
    // Without bindings, (\x. \x. x) 42 should be a closure, not an error
    // (if it strips the lambda, it tries to look up 'x' which is undefined)
    let result = run("(\\x. \\x. x) 42", false);
    assert!(result.is_ok(), "should not be a parse/eval error");
    let val = result.unwrap();
    assert!(val.is_some(), "should have a result");
    let val = val.unwrap();
    assert!(!pp::eval::is_error(&val),
        "should not be an error (got {:?})", val);
}
