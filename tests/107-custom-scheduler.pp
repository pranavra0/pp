load("stdlib/runtime.pp")
def choose(jobs) {
  {:mode -> :serial, :batches -> vec[vec[0]]}
}
configure-runtime({:schedule -> schedule-custom(choose), :reporter -> reporter-console})
node double(x) {
  perform log("BODY")
  x * 2
}
print(double(21))
