// Test fixture for prefix/postfix update expressions and compound assignment.
//
// Expected behavior from vizg:
//   - 0 parser diagnostics (parse cleanly).
//   - AST must contain UpdateExpression nodes for prefix and postfix forms.
//   - AssignmentExpression nodes must carry the PlusEqual operator for `line += "x"`.
//   - Logical assignments parse and compound targets produce read/write references.

let i = 0;
++i;
i++;

let line = "";
line += "hello";
line &&= "world";
line ||= "fallback";
line ??= "fallback";

function counter(start: number): number {
  let n = start;
  n++;
  return n;
}

function accumulator(acc: string, x: string): string {
  acc += x;
  return acc;
}
