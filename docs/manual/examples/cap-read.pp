# Reading a file reaches out and touches the world, so it needs a filesystem
# capability. This program is granted nothing, so the read is refused before
# it happens — the check is on authority, not on whether the file exists.
print(perform read-file("/etc/hostname"))
