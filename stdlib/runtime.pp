# Runtime policy constructors. These return ordinary data consumed by
# configure-runtime; they do not grant authority or execute host work.

def schedule-serial() {
  { :kind -> :serial }
}

def schedule-parallel(width) {
  { :kind -> :parallel, :width -> width }
}

def schedule-race(width) {
  { :kind -> :race, :width -> width }
}

def schedule-custom(policy) {
  { :kind -> :custom, :policy -> policy }
}

def runtime-manifest(schedule, reporter) {
  { :schedule -> schedule, :reporter -> reporter }
}

def reporter-ignore(events) { nil }

def reporter-console(events) {
  print(events)
}

def build-policy(fields) { fields }
def execution-policy(fields) { fields }
