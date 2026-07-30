load("stdlib/runtime.pp")
configure-runtime!({
  :schedule -> schedule-parallel(2),
  :build-policy -> build-policy({:toolchain -> "clang"}),
  :execution-policy -> execution-policy({:network -> false}),
  :reporter -> reporter-console
})
emit-event!({:kind -> :library-event, :value -> "ok"})
7
