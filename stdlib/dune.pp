def dune-file(path, name, mode) {
  { :tree -> {
    name -> { :kind -> :file, :mode -> mode, :blob -> blob($file(path)) }
  }}
}

def dune-working-tree(spec) {
  $glob(spec[:root])
  let result = perform run(
    "dune", "build", "--root", spec[:root], spec[:target]
  )
  if result["exit"] = 0 {
    {
      :outputs -> dune-file(spec[:output], spec[:name], spec[:mode]),
      :evidence -> { "adapter" -> "working-tree" }
    }
  } else {
    error(string-append(result["err"], result["out"]))
  }
}

def dune-closed-request(spec) {
  {
    :tool -> spec[:tool],
    :tool-path -> spec[:tool-path],
    :args -> [
      "build", "--root", "/in", "--build-dir", "/out/_build",
      spec[:target]
    ],
    :inputs -> spec[:inputs],
    :env -> {},
    :platform -> spec[:platform],
    :outputs -> [spec[:closed-output]]
  }
}

def dune-closed-source(spec) {
  perform run-closed!(dune-closed-request(spec))
}

def dune-build(adapter, spec) {
  if adapter = :working-tree {
    dune-working-tree(spec)
  } else if adapter = :closed-source {
    dune-closed-source(spec)
  } else {
    error("dune-build: unknown adapter")
  }
}
