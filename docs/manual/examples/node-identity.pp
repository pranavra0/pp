# A node is identified by its code and its inputs (LAW 20). Two nodes with
# identical code and free-variable values are the SAME node: the first force
# runs the body and stores the result; the second finds it already in the
# store. A store hit does not replay the body's output (LAW 17), so
# "compiling" prints exactly once.
let first = node { print("compiling"); 6 * 7 }
let second = node { print("compiling"); 6 * 7 }
print(first)
print(second)
