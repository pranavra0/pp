# Reading a file requires a filesystem capability. This program is granted
# nothing, so the read is refused before it happens — the check is on
# authority, not on whether the file exists. Observation sigils ($file,
# $env, etc.) are the idiomatic way to read the world; a bare `perform
# read-file` is linted.
print($file("/etc/hostname"))
