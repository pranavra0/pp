# collect partitions a list of [:ok, v] / [:err, e] results.
# It returns [:ok, values] if all succeeded or [:err, errors] if any failed.
let results = list([:ok, 1], [:ok, 2], [:err, "x"])
print(results |> collect)

let all-ok = list([:ok, 10], [:ok, 20])
print(all-ok |> collect)
