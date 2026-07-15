# Observation sigils read the world and record trace cells.
# Each is a $ prefixed form that lowers to the corresponding builtin.
#
# $file("path")      -> slurp, records file: cell
# $env("VAR")        -> env-get, records env: cell
# $probe("name")     -> probe, records probe: cell
# $secret("path")    -> slurp under secret grant, records sealed: cell
#
# (These require the appropriate --grant at the command line;
#  this example only demonstrates the syntax, not actual execution.)
print("sigils: $file, $env, $config, $probe, $secret")
