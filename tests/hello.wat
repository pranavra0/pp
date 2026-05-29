(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "Hello\0a")
  (export "_start" (func $main))
  (func $main
    (i32.store (i32.const 16) (i32.const 0))
    (i32.store (i32.const 20) (i32.const 6))
    (call $fd_write (i32.const 1) (i32.const 16) (i32.const 1) (i32.const 32))
    drop)
)
