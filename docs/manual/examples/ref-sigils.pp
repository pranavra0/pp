# Observation sigils are the complete world-read surface. Each lowers to a
# typed observation node and records the corresponding trace cell.
#
# $file("path")       -> file: or sealed:
# $env("VAR")         -> env:
# $tree("root")       -> tree:
# $probe("name")      -> probe:
# $secret("path")     -> sealed:
# $stat("path")       -> stat:
# $argv()             -> argv:
# $config(:key)       -> config:
#
# Appropriate command-line grants are required where applicable.
print("sigils: $file, $env, $tree, $probe, $secret, $stat, $argv, $config")
