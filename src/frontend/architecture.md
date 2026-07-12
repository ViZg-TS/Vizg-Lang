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

Los templates con interpolación se dividen en `TemplateHead`, `TemplateMiddle` y `TemplateTail`. El parser los representa como `TemplateExpression`, con texto literal y expresiones AST recorribles. Los templates sin interpolación conservan `NoSubstitutionTemplate` como literal opaco.

El scanner decide contextualmente si `/` inicia un `RegExpLiteral` o representa división. El AST conserva el patrón, las flags válidas y el span del literal completo.

Las expresiones unarias prefijas (`!`, `~`, `-`, `+`, `typeof`, `void`, `delete`, `await`) se agrupan antes que los operadores multiplicativos. La aserción no nula `value!` sigue siendo una expresión postfija distinta.

La precedencia de expresiones sigue la escalera de JavaScript: exponenciación (asociativa a la derecha), multiplicación, suma, shifts, relaciones, igualdad, AND/XOR/OR bit a bit, AND/OR lógico, coalescencia nula, condicional ternaria y asignación. Las expresiones condicionales son asociativas a la derecha y recorren condición, consecuencia y alternativa. Mezclar `??` con `&&` o `||` requiere paréntesis explícitos.

Cada token guarda:

```zig
ttype
lexeme
line
column
start_offset
```

Eso está bien como base mínima.
