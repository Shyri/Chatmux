# Chatmux en Windows — decisiones y datos

Conversación del 2026-08-11. Aparcado a propósito: Chatmux en Swift sigue
siendo la herramienta de trabajo diaria mientras lo otro no exista.

Este documento existe para no volver a razonarlo desde cero. Lo importante no
son las conclusiones sino **los números que las sostienen**, porque son caros de
medir y fáciles de olvidar.

---

## La decisión

**Windows es requisito del producto.** Y lo único que se necesita que Chatmux
haga y hoy no hace es, literalmente, funcionar en Windows. No falta
funcionalidad: falta plataforma.

De ahí sale todo lo demás.

## Por qué el port no es viable

De 1.345 ficheros Swift en `Sources/`:

| | ficheros |
|---|---|
| importan AppKit | 446 |
| importan SwiftUI | 245 |
| usan `NSView` | 168 |
| usan `NSWindow` | 148 |
| usan `NSHostingView` | 41 |

Swift tiene toolchain oficial en Windows; **SwiftUI no existe fuera de Apple**.
Toda la capa de vistas se tira. Y el terminal es Ghostty: submódulo en Zig con
renderer Metal, que es de Apple — portarlo no sería trabajo de este repo sino
del proyecto Ghostty.

## Cuánto de esto es realmente Chatmux

Lo que decidió el alcance:

| | líneas |
|---|---|
| `ClaudeChat/` + panel + popover | ~15.000 |
| `GitLab/` | 6.100 |
| `AutoTask/` | 4.100 |
| **producto propio** | **~25.000** |
| chasis heredado de cmux | **398.000** |

**El 6 %.** Se arrastran 398.000 líneas de gestor de terminales para llevar
25.000 que son el producto — y de esas, buena parte es UI que se rehace
igualmente en cualquier destino.

## Qué se descartó, y por qué

**Forkear VS Code.** Es lo que hicieron Cursor y Windsurf, y el modelo comercial
está probado. Pero si el chat es el producto y el terminal es accesorio, se
heredaría otro chasis gigante para usar el 20 % — repetir el error del que se
quiere salir, con una base mayor. Además: el código es MIT, pero el Marketplace
de extensiones y las extensiones propietarias de Microsoft (Pylance, C#, Remote,
Live Share) no están disponibles para forks; usan Open VSX, con mucho menos
catálogo.

**Divorciarse de cmux (como decisión aparte).** Ya no hace falta decidirlo: si
el destino es otra base, es irrelevante. El dato que lo cerró: el último
`sync-upstream` trajo **1.339 commits y 4.659 ficheros**, y de ellos
**cero** tocaron `ClaudeChat` o `GitLab`. Upstream aporta mantenimiento del
terminal, no del producto.

**El modelo de proyectos con `.chatmux/`.** Se diseñó entero (identidad por
`git-common-dir`, `project.json` commiteado, estado local dentro de `.git/`)
y se aparcó por lo mismo: se rehace en la base nueva. El diseño está en el
historial de la conversación si alguna vez hace falta.

## El destino propuesto

**Electron + TypeScript, reimplementando solo lo que se usa.** No un IDE.

- chat con streaming, tool cards, permisos, markdown — **lo difícil**
- panel de GitLab, que en el fondo es UI sobre `glab`
- auto-tasks, que son lógica pura y ya están especificados por sus tests
- terminal: `xterm.js`, sin más

Electron antes que Tauri por una razón concreta: Tauri usa el WebView del
sistema (WKWebView en Mac, WebView2 en Windows) y son dos motores que se
comportan distinto. Electron empaqueta un solo Chromium. Cuesta ~140 MB y
ahorra depurar dos veces.

### Por qué web y no nativo multiplataforma

No es preferencia. Los tres cuelgues de esta semana fueron **el mismo problema**:
renderizar una lista larga de contenido heterogéneo y altura variable. Que es
exactamente lo que un chat es.

| capa | coste medido |
|---|---|
| `GeometryReader` mediando mediciones | 17 % del hilo principal |
| `NSHostingView` reentrando el display cycle | 55 % |
| ventana creciendo a 410 filas | `prioritize` 48 %, botones 40 % |

Cada uno se diagnosticó muestreando un proceso colgado, porque AttributeGraph
es opaco: no se puede inspeccionar por qué invalida. En web ese problema tiene
librerías probadas y un profiler que lo enseña.

**No es gratis en web**: sin virtualización explícita, 400 mensajes también se
arrastran. La diferencia es que ahí se sabe qué hacer.

## Lo que hay que llevarse, y no es código

Los **126 tests** de la parte propia son la especificación ejecutable del
comportamiento. Y estos hechos, que costaron un día cada uno de descubrir:

- El runner usa `claude -p --input-format stream-json`: una sesión en
  streaming, no un one-shot. **El CLI expande los slash commands él mismo** —
  no hay que reimplementar la expansión.
- `KillShell` ya no existe en el CLI; los shells de fondo son *tareas* y se
  paran con `TaskStop` y su `task_id`.
- `rate_limit_event` llega en cada turno con `status` / `resetsAt` /
  `rateLimitType`, pero **sin porcentaje**. Los porcentajes de `/usage` salen
  de `/api/oauth/usage`, que es privada.
- `FORBIDDEN_PATHS` es un `case` de bash: `*` cruza separadores y una barra
  final ancla en la raíz. Reimplementarlo mal deja ficheros sin proteger **en
  silencio**.

## Abierto

- **¿Windows para uso propio o para distribuir?** Cambia el alcance por
  completo: firma de código, instaladores y actualizaciones son un mundo aparte.
- ¿Local, remoto o ambos? Meter remoto después es caro.
- Qué hacer con Chatmux-Swift a largo plazo: herramienta interina hasta que la
  otra base la alcance, y entonces se decide.
