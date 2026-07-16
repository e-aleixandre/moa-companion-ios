# Pulse Design System

Lenguaje visual de **Moa Pulse**, el cliente iOS de voz de moa. Todo en SwiftUI
puro con fuentes del sistema; sin dependencias de terceros ni binarios de fuente.

## Filosofía

Pulse es una herramienta de poder para un desarrollador exigente: le habla al
oído mientras sus agentes trabajan. La estética sigue la línea de Linear,
Raycast, Superhuman y Arc: **oscuro por defecto, tipografía cuidada, profundidad
sutil, movimiento con intención**. Nada del look por defecto de iOS (SF Symbols
crudos con tint azul y Form gris).

Tres principios:

1. **La luz es señal.** Sobre un fondo casi negro, el color solo aparece cuando
   significa algo: el estado de la voz, un aviso, un error. El glow
   (`pulseGlow`) es la firma lumínica del sistema y se reserva para lo vivo.
2. **Lo técnico se ve técnico.** Nombres de sesión, servidores, códigos y
   timestamps van en SF Mono. El resto de la interfaz habla en SF Pro.
3. **El orbe es el centro emocional.** Una app de voz sin cara necesita un
   punto de vida. `PulseVoiceOrb` respira, escucha y habla; todo lo demás es
   secundario y silencioso.

## Paleta (`PulseTheme.swift`)

| Token | Valor | Uso |
| --- | --- | --- |
| `backgroundBase` | `#0B0D10` | Fondo de pantalla. Casi negro con matiz azul-carbón: menos duro que negro puro, mejor con OLED. |
| `backgroundRaised` | `#14171C` | Tarjetas, filas, controles. |
| `backgroundOverlay` | `#1C2128` | Campos dentro de tarjetas. |
| `hairline` | blanco 8 % | Bordes de 1 pt; la profundidad viene de trazos, no de sombras negras. |
| `ember` | `#FF6D3F` | **El acento.** Naranja-brasa: cálido, con carácter, evoca "pulso"/energía y se distingue de golpe del azul de sistema y del verde/rojo semánticos. |
| `listening` | `#4FD8EB` | Cian frío = entrada (el dueño habla). Opuesto perceptivo del ember (salida: Pulse habla). |
| `success` / `warning` / `danger` | verde/ámbar/rojo | Semánticos clásicos, desaturados para no chillar sobre oscuro. |

`PulseTone` empaqueta estos semánticos para que pills, botones, orbe y tarjetas
compartan el mismo vocabulario (`.accent`, `.listening`, `.success`, `.warning`,
`.danger`, `.neutral`).

El asset `AccentColor` del app target replica el ember para que los controles de
sistema (alerts, toolbar) hereden el acento.

Light mode: no es objetivo. La app fija `preferredColorScheme(.dark)` en
`pulseScreenBackground()`; los tokens son constantes, no dinámicos. Si algún día
hace falta light, se migran los tokens a assets con variantes.

## Tipografía (`PulseTypography.swift`)

- **SF Pro** — `display` (30 bold) → `title` (22 semibold) → `headline` (17
  semibold) → `body`/`callout` → `footnote` → `micro` (11 semibold, en
  mayúsculas con tracking 1.4 vía `pulseMicroCaps()` para cabeceras tipo
  "SERVIDOR").
- **SF Mono** — `monoLarge`/`mono`/`monoSmall` para material técnico: nombres de
  sesión, URLs, códigos de emparejamiento, timestamps.

## Layout (`PulseLayout.swift`)

- Espaciado en escala de 4 pt (`PulseSpacing.xxs…xxl`).
- Radios: `control` 12 / `card` 16 / `sheet` 22, siempre `.continuous`.
- `pulseCard()` — superficie estándar (raised + hairline + radio card).
- `pulseGlow(color)` — sombra de color, la firma lumínica.
- `pulseScreenBackground()` — fondo base + halo ember tenue arriba + esquema
  oscuro forzado.

## Componentes (`PulseComponents.swift`, `PulseVoiceOrb.swift`)

Todos con `#Preview`:

- `PulsePrimaryButtonStyle(tone:)` — relleno de tono, texto oscuro, glow.
  Protagonista: Llamar (ember) / Colgar (danger).
- `PulseSecondaryButtonStyle(tone:)` — superficie + hairline.
- `PulseIconButtonStyle(tone:diameter:)` — circular (mic, ajustes).
- `PulseStatusPill(_:tone:pulses:)` — badge de estado con punto que late en
  estados transitorios (TimelineView, sin animación huérfana).
- `PulseInlineNotice(_:tone:)` — aviso/error inline.
- `PulseTextField(_:text:monospaced:)` — campo sobre overlay, tint ember.
- `PulseCaptionBubble(text:isOwner:)` — transcript: dueño a la derecha con tinte
  ember, Pulse a la izquierda sobre superficie.
- `PulseSectionHeader(_:)` — micro-cabecera en mayúsculas.
- **`PulseVoiceOrb(mode:diameter:)`** — el orbe de voz. Estados `idle`
  (respiración lenta), `connecting` (anillo que rota), `listening` (anillos
  cian que se expanden), `speaking` (latido ember con flutter). Dibujado con
  círculos + gradientes sobre `TimelineView(.animation)` a 30 fps: iOS 17-safe,
  sin symbol effects. Cuando el motor exponga niveles de audio reales, el
  flutter simulado se sustituye por amplitud medida (TODO marcado en código).

## Guardián (`GuardianPreviews.swift`)

Piezas listas para el modo Guardián, **sin cablear** (el motor no existe aún);
se demuestran con mocks en `#Preview` y reciben todo por parámetro:

- `PulseGuardianMode` — Vigilando / Escuchando / Hablando / Resolviendo /
  Reconectando, con mapeo a tono y a modo de orbe. Se sustituirá o mapeará al
  enum real del motor.
- `PulseGuardianStatusView` — orbe + pill de modo + contadores ("4 sesiones
  vigiladas · 2 avisos pendientes").
- `PulseGuardianSessionRow` + `PulseGuardianSessionPreview` — tarjeta de sesión
  vigilada: barra de actividad de color, nombre en mono, detalle, pill.
- `PulseGuardianAlertCard` + `PulseGuardianAlertPreview` — briefing entrante
  ("Distribuciones terminó") con acciones Escuchar/Descartar opcionales.
- `PulseGuardianPendingBadge` — contador compacto para cabeceras.

Cuando llegue el motor: sustituir los structs `*Preview` por los modelos
reales (o mapearlos), montar la pantalla del Guardián con estas piezas y
conectar los callbacks. El lenguaje visual ya está decidido.
