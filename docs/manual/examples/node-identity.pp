# A node is identified by its code and its inputs. Write the same node twice
# and it is the SAME node: the first force runs the body and stores the
# result; the second finds that result already in the store. A store hit does
# not replay the body's output (LAW 17), so "compiling" prints exactly once.
let a = node { print("compiling"); 6 * 7 }
let b = node { print("compiling"); 6 * 7 }
print(a)
print(b)
