Source text
  ↓
Scanner / Lexer
  ↓
Token stream + comments + lexical diagnostics
  ↓
Parser
  ↓
AST + parse diagnostics
  ↓
Binder
  ↓
Scopes + symbols + imports/exports
  ↓
Control-flow graph preliminar
  ↓
FrontendResult

`
tokens // done
scanner
ast
parser
binder
control_flow`

tokens.zig define el vocabulario léxico completo: keywords, literales, operadores, símbolos, comentarios, regex, EOF/EOL y templates.

Cada token guarda:

```zig
ttype
lexeme
line
column
start_offset
```

Eso está bien como base mínima.