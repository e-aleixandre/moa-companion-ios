# Moa Pulse — definición de producto y plan de trabajo

> Documento de definición. Sustituye a cualquier decisión anterior sobre "proyecciones seguras",
> "operaciones preparadas/confirmadas" o límites de lectura del modelo. Julio 2026.

## 1. Qué es Pulse

Pulse es el cliente iOS (y CarPlay) de `moa serve`. Es **tu intermediario por voz** con todas
las conversaciones de Moa: si las sesiones de Moa son tus trabajadores, Pulse es quien te
permite hablar con todos ellos en lenguaje natural, estés donde estés (andando con cascos,
en el coche).

Con Pulse puedes:

- Preguntar **qué está pasando**: qué sesiones hay abiertas, cuáles avanzan, cuáles están
  bloqueadas esperándote.
- Pedir **información de una conversación concreta**: qué ha dicho el agente, qué está
  haciendo ahora ("está leyendo `handlers.go`", "acaba de pasar los tests"), en qué punto va.
- **Actuar**: enviar mensajes o steers a una sesión, responder preguntas pendientes
  (`ask_user`), aprobar/denegar permisos, crear/retomar/cancelar sesiones.
- (Fase posterior) **Abrir conversaciones en la app** y leerlas en un formato narrativo:
  los mensajes del agente sí, pero la actividad de tools resumida en frases humanas, no
  líneas de código ni diffs crudos.

Dos modos de uso:

1. **Modo llamada (voz, headless)** — el vertical v1. Una conversación de voz continua con
   un modelo Realtime. Vas por la calle con cascos y hablas con Pulse como con una persona:
   "¿cómo va lo del bug de OpenAI?", "dile a la sesión del frontend que pruebe en Safari",
   "apruébale el comando a la de deploy". No hace falta mirar la pantalla.
2. **Modo app (visual)** — fase 2. Lista de sesiones con estado, y vista de conversación
   narrativa con acciones táctiles (enviar, aprobar, cancelar).

## 2. Principios de arquitectura

Estos cinco principios son la base; todo lo demás se deriva de ellos.

### P1 — Pulse es un cliente puro; Moa no sabe (casi) nada de Pulse

Moa expone una **API genérica** (REST + WebSocket) que consumen por igual el frontend web,
y Pulse. **No hay lógica de negocio Pulse-específica dentro de moa**: ni proyecciones
especiales, ni ledgers de operaciones, ni reviews, ni DTOs "seguros" a medida. Pulse se
comunica por los mismos sockets y endpoints que la web.

Las **únicas** piezas Pulse-aware que viven en moa, porque no pueden vivir en otro sitio:

1. **Pairing de dispositivos** (QR + credencial de dispositivo): cómo un iPhone se empareja
   con el servidor y se autentica después.
2. **Broker de client secrets Realtime**: moa guarda la API key de OpenAI (slot dedicado en
   `moa auth`) y emite client secrets efímeros de un solo socket a dispositivos emparejados.
   La key permanente nunca llega al iPhone; moa nunca proxya ni almacena audio.

### P2 — El modelo de voz tiene acceso completo de lectura

El modelo Realtime dispone de **tools de lectura sin restricciones de contenido**: puede
listar sesiones y leer los mensajes de usuario/asistente y la actividad de tools de
**cualquier** conversación, bajo demanda. Nada de briefs acotados ni redacción de contenido.
Es mi servidor, son mis conversaciones, y asumo que ese contexto pasa por OpenAI.

Los límites que sí existen son **de presupuesto, no de privacidad** — y son estrictos,
porque en Realtime cada token de contexto cuesta mucho más que en texto:

- Por defecto el modelo recibe **metadatos de actividad, nunca contenido de salidas**:
  qué tool se llamó, con qué argumentos (condensados), cómo terminó, qué subagentes/bash
  jobs hay corriendo. "Leyó `handlers.go`" — no las 500 líneas del fichero.
- Los mensajes de usuario/asistente sí van completos (son la conversación real y suelen
  ser cortos), con truncado defensivo para mensajes anómalos.
- El contenido de una salida concreta solo llega si el modelo lo pide explícitamente
  (`read_tool_detail`), y aún entonces acotado (tail de N KB), nunca ficheros enteros.
- Paginación incremental: últimos N items, pedir más hacia atrás solo si hace falta.

### P3 — Acciones directas, sin ceremonia de confirmación

Cuando digo "dile a la sesión del bug que pruebe con `-race`", el modelo **lo envía
directamente**. Sin eco-y-confirma, sin review visual, sin operación preparada en dos fases.
La conversación de voz ya es el contexto de confianza; si el modelo duda del destino
("¿te refieres a la sesión *fix openai stall* o a *bug review*?"), pregunta como preguntaría
una persona, no mediante un protocolo.

Esto aplica a todas las acciones expuestas como tools: enviar/steer, responder asks,
decidir permisos, crear/retomar/cancelar sesiones.

### P4 — Voz directa iPhone ↔ OpenAI Realtime

El audio va **directo del iPhone a OpenAI** (WebRTC/WS contra la API Realtime, modelo
`gpt-realtime-2.1-mini` de partida) usando el client secret efímero que emite moa. Ventajas:
latencia mínima, moa no procesa audio, y el coste de la conversación de voz no pasa por el
provider-loop de moa.

Las tools que el modelo invoca **las ejecuta la app** (Swift) contra la API genérica de moa
por Tailscale, y devuelve el resultado JSON al socket Realtime. El modelo nunca tiene la
credencial de moa ni acceso HTTP genérico: solo las tools tipadas que la app implementa.

```
        audio + tool-calls                    REST/WS (Tailscale)
  ┌──────────┐  WebRTC/WS   ┌──────────────┐
  │  OpenAI   │ ◄──────────► │  iPhone      │ ◄──────────────► ┌────────────┐
  │  Realtime │              │  (Pulse app) │                   │  moa serve │
  └──────────┘              └──────────────┘                   └────────────┘
       ▲                            │  1. POST /api/pulse/realtime/client-secret
       └────────────────────────────┘     (credencial dispositivo → ek_ efímero)
```

### P5 — El modelo narra; no hay "generador de narrativa" determinista para voz

Como el modelo lee el contenido real, **la narración la hace él**: recibe la lista de
mensajes y actividad de tools en JSON estructurado y la cuenta en voz alta de forma natural
("ha estado media hora con los tests de `pkg/serve`, los acaba de poner en verde y ahora
está escribiendo el changelog"). No se necesita un builder determinista de frases tipo
`PulseBriefBuilder` para el modo voz. (El feed visual de la fase 2 sí necesitará un mapeo
tool→frase, y por la regla de paridad debería compartirse con la web — se define en §8.)

## 3. Qué existe hoy y qué sobra

### 3.1 Servidor (rama `feat/pulse-call-integration` de moa)

Se construyó un subsistema "Ops/Pulse operations" que contradice P1–P3 y **hay que
eliminarlo** antes de construir lo nuevo:

**Eliminar** (con sus tests y su UI web):

| Pieza | Ficheros | Por qué sobra |
|---|---|---|
| Proyección "Ops segura" | `ops.go`, `ops_ask.go`, `ops_ws.go`, endpoints `/api/ops/*` | Brief acotado que oculta contenido al modelo — contra P2. La web tampoco lo necesita: ya tiene el dashboard real. |
| Operaciones en dos fases | `pulse_operations.go` (~950 líneas), `operation_store.go`, locks, endpoints `/api/pulse/operations/*` | Prepare/confirm/review/receipts — contra P3. |
| Ledger de instrucciones canónicas | `instruction.go`, `instruction_store.go`, locks, `/api/ops/instruction`, `/api/sessions/{id}/instruction` | Infraestructura del punto anterior. |
| WS de companion "seguro" | `companion_ws.go`, `/api/sessions/{id}/companion-ws` | DTO paralelo que censura tools — contra P2. Pulse usará el `/api/sessions/{id}/ws` genérico. |
| Niveles de ruta por dispositivo | `route_auth.go` (los tiers `routeDeviceRead`/`routeDeviceOperation`) | El dispositivo emparejado debe tener la superficie genérica completa (ver §4.2), no una jaula de endpoints. |
| Frontend Ops | `OpsPanel.jsx`, `ops-*.js`, estilos ops | UI del sistema eliminado. |

**Conservar**:

| Pieza | Ficheros | Rol |
|---|---|---|
| Pairing de dispositivos | `pulse_auth_api.go`, `device_auth.go`, `PulsePairingPanel.jsx`, `/api/pulse/pairings*`, `/api/pulse/devices*` | P1: única pieza Pulse-aware legítima (1/2). |
| Broker Realtime | `realtime_client_secret.go`, `/api/pulse/realtime/client-secret` | P1: pieza legítima (2/2). Modelo fijado server-side. |
| Attention | `attention.go`, `/api/attention` | Genérico: qué sesiones requieren al usuario. Útil para web y Pulse. |
| Transcript paginado | `conversation.go`, `/api/sessions/{id}/messages` | Base genérica buena, pero hay que **quitarle la censura** de tools (hoy elimina deliberadamente toda actividad de tools). Ver §4.1. |

### 3.2 Cliente (este repo, `moa-companion-ios-openai-realtime`)

Repo canónico. Las otras carpetas `moa-companion-*` son iteraciones anteriores y se archivan.

**Conservar/adaptar**: la conexión Realtime directa (client secret efímero → socket OpenAI),
el cliente de pairing/dispositivo (`PulseDeviceAuth`, `PulseDeviceClient`), el manejo de
audio PCM16, el esqueleto de app y CI.

**Eliminar/reescribir**: `PulseBriefBuilder` y todo el sistema de provenance/citations
(el modelo narra, P5); el flujo PTT-con-reserva-de-turno y el review inmutable visible
(contra P3); `AnthropicPulseProvider` (la voz es OpenAI Realtime; no hay segundo provider);
los modelos Codable del snapshot "Ops seguro" (la API cambia a la genérica).

## 4. Trabajo en moa (servidor)

### 4.1 Extender el transcript genérico con actividad de tools

`GET /api/sessions/{id}/messages` hoy devuelve solo texto de usuario/asistente. Necesita
incluir la actividad de tools como **items narrables estructurados**, p. ej.:

```json
{
  "role": "tool",
  "tool": "edit",
  "action": "edit",
  "target": "pkg/serve/handlers.go",
  "summary": "Tool activity",
  "status": "ok",
  "at": "2026-07-15T18:02:11Z"
}
```

- `action` es una categoría neutra y `target` aplica una whitelist estricta: rutas para
  operaciones de fichero, el ejecutable base de `bash` cuando se puede determinar
  conservadoramente y el hostname de `fetch_content`. Las búsquedas, patrones,
  tareas de subagente y argumentos arbitrarios no se exponen. `summary` es solo
  el fallback neutro `Tool activity`; los clientes y el modelo Realtime construyen
  la narración localizada.
- **Por defecto los items de tool NO llevan la salida** — solo tool, action, target
  seguro, estado y timestamp. Es el contrato de eficiencia: el transcript por defecto
  es barato de leer para un modelo, por larga que sea la sesión.
- La actividad de subagentes y bash jobs aparece igual: "lanzó subagente: 'migrar tests
  de pkg/serve' (corriendo, 4 min)" — su transcript interno no se incluye por defecto,
  pero es investigable bajo demanda ("¿y qué está haciendo el subagente?" → el modelo
  tira de `read_subagent` y lo cuenta).
- Parámetro opt-in (`?detail=full` sobre un item concreto) devuelve la salida de esa
  llamada, acotada (tail de N KB, configurable), nunca ilimitada.
- Paginación existente se mantiene (`?before=`, `limit`).
- Es un endpoint genérico: la web puede usarlo también (paridad), aunque hoy la web ya
  recibe esto por WS.

### 4.2 Superficie del dispositivo emparejado = superficie del owner

Simplificar la autorización: una credencial de dispositivo emparejado da acceso a **toda la
API genérica** (`/api/sessions/*`, `/api/attention`, `/api/usage`, …) igual que el token,
con una única excepción: la administración de pairing (`/api/pulse/pairings`,
`/api/pulse/devices/*`) sigue siendo solo del owner (web/red de confianza), para que un
dispositivo robado no pueda emparejar otros ni revocar.

### 4.3 Overview para la voz: composición en cliente

No se añade ningún endpoint "resumen para Pulse". El estado global se compone en el cliente
con lo que ya existe: `GET /api/sessions` (lista + estados) + `GET /api/attention`
(pendientes). Si en la práctica hacen falta demasiadas llamadas, se valorará un
`?verbose=1` en `/api/sessions` — genérico, nunca Pulse-específico.

### 4.4 Limpieza

Ejecutar la tabla "Eliminar" de §3.1. La rama queda con: pairing + device auth + broker +
attention + transcript extendido + los endpoints genéricos que ya estaban en main.

## 5. Tools del modelo Realtime

Las implementa la app en Swift; cada una mapea a la API genérica. Firma pensada para voz:
resultados compactos, JSON plano, sin blobs de código salvo petición explícita.

| Tool | Qué hace | Endpoint moa |
|---|---|---|
| `list_sessions` | Sesiones con título, estado (running/idle/waiting/permission), modelo, última actividad, flag de atención | `GET /api/sessions` + `GET /api/attention` |
| `read_session` | Últimos N items de una sesión: mensajes completos + actividad de tools **solo como metadatos** (tool, args, estado); paginable hacia atrás | `GET /api/sessions/{id}/messages` |
| `read_tool_detail` | Salida de una llamada a tool concreta, acotada a un tail de N KB (única vía de ver contenido de salidas; uso excepcional) | `GET /api/sessions/{id}/messages?detail=full&…` |
| `read_subagent` | Transcript de un subagente (mismo formato que `read_session`: mensajes + metadatos de tools, últimos N items) — para "¿qué está haciendo el subagente?" | `GET /api/sessions/{id}/subagents/{jobID}` |
| `send_message` | Envía texto a una sesión; si está corriendo, steer; si idle, prompt nuevo | `POST /api/sessions/{id}/send` |
| `respond_ask` | Responde una pregunta `ask_user` pendiente | `POST /api/sessions/{id}/ask` |
| `decide_permission` | Aprueba/deniega un permiso pendiente (la tool devuelve antes el detalle de qué se pide, para que el modelo lo lea en voz alta) | `POST /api/sessions/{id}/permission` |
| `create_session` | Crea sesión nueva (título, cwd, modelo opcionales) | `POST /api/sessions` |
| `resume_session` | Retoma una sesión guardada | `POST /api/sessions/{id}/resume` |
| `cancel_run` | Cancela el turno en curso de una sesión | `POST /api/sessions/{id}/cancel` |
| `archive_session` | Archiva una sesión terminada | `POST /api/sessions/{id}/archive` |

Notas de diseño:

- **Resolución de referencias**: yo hablo de sesiones por descripción ("la del bug de
  OpenAI"). El modelo resuelve contra los títulos/estados de `list_sessions`; si hay
  ambigüedad real, pregunta. No hay matcher determinista.
- **Errores**: las tools devuelven errores legibles ("la sesión ya no está esperando ese
  permiso") para que el modelo los explique, no códigos crudos.
- **Presupuesto**: `read_session` por defecto N≈20 items; salidas de tools nunca por
  defecto (solo vía `read_tool_detail`, acotado). El system prompt instruye al modelo a
  leer incrementalmente, a razonar con los metadatos de actividad ("si editó el fichero y
  los tests pasaron, no necesitas leer el diff") y a usar `read_tool_detail` solo cuando
  yo pida detalle explícitamente.

## 6. Modo llamada: experiencia y comportamiento

- **System prompt** (en la app, versionado en este repo): identidad — "eres Pulse, el
  intermediario de voz del usuario con sus sesiones de Moa" —, español, respuestas cortas y
  orales, nunca leer código en voz alta salvo petición explícita (resumir: "cambió la
  validación del token en `auth.go`"), actuar directamente sin pedir confirmación, preguntar
  solo ante ambigüedad genuina.
- **Manos libres**: VAD del modelo Realtime (server-side turn detection), no PTT. La llamada
  es continua: la inicio, me la llevo en el bolsillo, hablo cuando quiero.
- **Inicio de llamada**: al conectar, la app hace `list_sessions`+`attention` y se lo pasa
  al modelo como contexto inicial, para que el primer "¿qué está pasando?" no gaste un turno
  de tools.
- **Audio de sistema iOS**: sesión de audio tipo llamada (background audio + controles en
  pantalla de bloqueo), compatible con cascos Bluetooth.
- **Ciclo de vida**: si el socket Realtime cae (cobertura), la app reconecta con un nuevo
  client secret y re-inyecta un resumen del estado; la conversación de voz es efímera por
  diseño (no se persiste transcript en moa).
- **CarPlay** (fase 3): la misma llamada expuesta como app de audio/comunicación en CarPlay;
  cero interacción visual obligatoria.

## 7. Seguridad (modelo simple)

- Frontera de red: Tailscale (como el resto de `moa serve`). El puerto nunca a Internet.
- Pairing por QR desde la web de moa → credencial de dispositivo persistente en el Keychain.
- La credencial de dispositivo da superficie de owner (§4.2) salvo administración de pairing.
- API key de OpenAI solo en el servidor (slot `moa auth`); el iPhone recibe `ek_…` efímeros
  de un socket.
- Revocación de dispositivo desde la web invalida credencial y client secrets futuros.
- Asunción explícita y aceptada: el contenido de las sesiones que el modelo lee viaja a
  OpenAI como contexto de la conversación Realtime.

## 8. Modo app visual (fase 2 — esbozo, se detallará al llegar)

- **Dashboard**: lista de sesiones ordenada por recencia con estado vivo (punto de color,
  "esperando permiso", "corriendo desde hace 12 min"), vía `/api/sessions` + WS.
- **Vista de conversación narrativa**: los mensajes del usuario y del asistente completos;
  la actividad de tools como líneas compactas ("📖 leyó `app.go`", "✏️ editó 3 ficheros",
  "▶️ `go test` ✅") expandibles a detalle. Misma fuente de datos que la tool `read_session`
  (§4.1) — el mapeo tool→frase se hace una vez y lo comparten el endpoint, la web y la app.
- **Acciones táctiles**: input para enviar/steer, botones aprobar/denegar en permisos, cerrar
  sesión.
- Botón prominente "📞 Llamar a Pulse" que inicia el modo llamada.

## 9. Plan de fases

### Fase 0 — Limpieza y base servidor (moa)
1. Eliminar el subsistema Ops/operations/instruction/companion-ws (§3.1) de la rama.
2. Simplificar autorización de dispositivo (§4.2).
3. Extender `/api/sessions/{id}/messages` con actividad de tools + `detail=full` (§4.1).
4. Conservar y verificar: pairing QR, revocación, broker Realtime.

### Fase 1 — Vertical de voz (v1 usable de verdad)
1. Limpiar el cliente Swift (§3.2): fuera brief builder, provenance, PTT, reviews, provider Anthropic.
2. Cliente de API genérica en Swift (sesiones, mensajes, send, ask, permission, attention).
3. Definir las tools Realtime (§5) + system prompt + contexto inicial de llamada.
4. UI mínima de llamada: pantalla de llamada (estado, mute, colgar), pairing por QR, ajustes.
5. Robustez: reconexión con nuevo client secret, audio en background, cascos BT.
6. **Criterio de "hecho"**: salir a la calle con cascos y, sin mirar el móvil, enterarme del
   estado de todo, leer lo que ha hecho una sesión y mandarle trabajo.

### Fase 2 — Feed visual
Dashboard + conversación narrativa + acciones táctiles (§8).

### Fase 3 — CarPlay
Modo llamada en CarPlay.

### Ideas post-v1 (no comprometidas)
- Proactividad: push cuando una sesión pide permiso/atención → "llamada entrante" de Pulse.
- Resumen hablado al descolgar ("desde tu última llamada, la sesión X terminó y la Y espera").
- Control de coste de la llamada (duración/uso visible, autocierre por inactividad).

## 10. Decisiones abiertas (a decidir cuando toquen, no bloquean fase 0)

1. **VAD fino**: umbrales de turn-detection del Realtime en entorno ruidoso (calle/coche);
   quizá toggle mute rápido desde los cascos.
2. **Push proactivo** (post-v1): ¿APNs desde moa —pieza nueva server-side— o polling al abrir?
3. **Multi-servidor**: ¿un Pulse emparejado con más de un `moa serve`? (hoy: uno).
4. **Modelo Realtime**: `gpt-realtime-2.1-mini` de partida; revisar calidad/coste tras uso real.
5. **Idioma**: prompt en español; ¿respuesta siempre en el idioma en que hablo?
