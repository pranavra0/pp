(* Single source of truth for pp's version string.
   Sourced from dune-project's (version ...) field via dune-build-info,
   embedded into the binary at build time by dune because src/dune ties
   this executable to the "pp" package (public_name). This works from a
   plain git checkout AND from an unpacked release tarball with no .git
   present — dune-build-info reads the version dune recorded at build
   time, not the VCS. See docs/RELEASING.md.

   The fallback only fires if the executable is ever built outside dune's
   package machinery (e.g. no public_name), where Build_info has nothing
   to report. *)

let fallback = "0.2.0-dev"

let string =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> fallback
