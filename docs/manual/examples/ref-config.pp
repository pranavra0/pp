# Config is ambient, dynamically-scoped data. `config` reads a key, with an
# optional default when the key is absent.
print(with-config({:host -> "db1", :port -> 5432}) { config(:host) })
print(with-config({:host -> "db1"}) { config(:timeout, 30) })
