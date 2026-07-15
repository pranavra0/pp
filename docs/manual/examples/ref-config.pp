# Config is ambient, dynamically-scoped data. `$config(key)` reads a key,
# with an optional default when the key is absent. It records a `config:`
# trace cell so a node that observed config recomputes when it changes.
print(with-config({:host -> "db1", :port -> 5432}) { $config(:host) })
print(with-config({:host -> "db1"}) { $config(:timeout, 30) })
