// Test fixture for prefix/postfix update expressions and compound assignment.
//
// Expected behavior from vizg:
//   - 0 parser diagnostics (parse cleanly).
//   - AST must contain UpdateExpression nodes for prefix and postfix forms.
//   - AssignmentExpression nodes must carry the PlusEqual operator for `line += "x"`.
//   - Resolver must record a write reference on the LHS of both forms (`i` and `line`).

let i = 0;
++i;
i++;

let line = "";
line += "hello";

function counter(start: number): number {
  let n = start;
  n++;
  return n;
}

function accumulator(acc: string, x: string): string {
  acc += x;
  return acc;
}
