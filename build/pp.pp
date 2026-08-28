# Canonical pp bootstrap request.  The tool is an immutable SBCL artifact.
# The request invokes the bootstrap entrypoint directly.
let source = source-tree(".", "lisp", "build")
let toolchain = sbcl-toolchain()
perform run-closed!({
  :tool -> toolchain[:tree],
  :tool-path -> toolchain[:tool-path],
  :args -> [
    "--no-userinit",
    "--no-sysinit",
    "--non-interactive",
    "--load",
    "build/bootstrap.lisp"
  ],
  :inputs -> source,
  :env -> {
    "SBCL_HOME" -> toolchain[:sbcl-home],
    "PP_TEMP_IMAGE" -> "build/pp.sbcl-image"
  },
  :platform -> {"os" -> "linux"},
  :policy -> {
    :provider -> "local-materialized-workspace",
    :mode -> "direct-sbcl",
    :contract -> {
      :version -> "v1",
      :capabilities -> vec[
        "direct-process",
        "explicit-environment",
        "workspace-filesystem"
      ],
      :namespaces -> {
        "clock" -> "ambient",
        "environment" -> "explicit-only",
        "filesystem" -> "workspace-materialized",
        "kernel" -> "ambient",
        "loader" -> "ambient",
        "network" -> "ambient",
        "randomness" -> "ambient",
        "resources" -> "ambient"
      }
    },
    :toolchain -> toolchain[:manifest],
    :toolchain-tree-sha256 -> hash-value(toolchain[:tree])
  },
  :outputs -> ["build/pp", "build/pp.sbcl-image",
               "build/pp.sbcl-image.build-id"]
})
