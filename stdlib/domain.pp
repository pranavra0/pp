# Generic domain composition helpers. Domain policy remains ordinary pp
# functions; register-domain supplies only the runtime lifecycle boundary.

def domain(spec) {
  register-domain(spec)
}

def probe(name, observe, read-cap) {
  register-probe(name, observe, read-cap)
}

def register-domains(domains) {
  each(domain, domains)
}
