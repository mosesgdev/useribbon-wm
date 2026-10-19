# Ribbon design language (Dia/Arc-inspired, ADHD-first)

Borrowed patterns: command bar as the primary navigator (find > organize); controls only when relevant;
"Tuesday morning test" (no relearning); spend the novelty budget on one thing (the ribbon + map);
Peek-like non-committal previews; calm, purposeful, interruptible motion.

ADHD principles: one primary action per screen; persistent "you are here" cue; undo everywhere;
no shame/red states (red only for data loss); no timeouts or nagging; honor Reduce Motion/Transparency.

## Tokens
- Accent: #6B7CFF (light) / #8E9BFF (dark). Amber #E0A526 for caution, success #3FA273.
- Ink #1D1B19 / #F2EFEA, muted #6E6A64 / #9C978F.
- Surfaces are Liquid Glass (system material), never opaque fills.
- Type: SF Pro Rounded semibold for display (onboarding, the HUD caption title at 12.5pt); SF Pro Text 13pt base, 11pt captions.
- Focus ring: accent, 4pt (5pt opaque with Increase Contrast), concentric with a 12pt window radius, soft accent glow; glides 0.2s, instant with Reduce Motion.
- Radii (continuous corners): 20pt floating panels (the HUD strip, with 12pt tiles), 16pt command bar, 8pt chips; nested radius = outer - padding.
- Motion: panels .spring(response: 0.35, dampingFraction: 0.85); HUD strip eases on cubic-bezier(.2,.9,.2,1) (`Theme.ease`):
  hover 150ms, focus 200ms, slides 250ms, scale 0.97→1; micro .easeOut(0.15). Reduce Motion → .easeOut(0.12)/opacity only.
- HUD: appear 120ms, linger 1200ms after last change (held while keys active), fade 300ms.
- HUD strip: 40pt tiles drawn to scale (width follows the column), one 2pt accent ring on the focused tile's edge over an opaque,
  accent-washed plate; stacks draw at most two slivers and a tile that hides windows (tab group, deeper stack) carries a count badge
  on its corner; off-screen columns at 40% (55% in light); one caption line ("Terminal  3/7") with desktop dots on the right.
  Toasts live in their own pill above it. Those numbers are Small (78pt); Settings → General → Window strip size also offers
  Medium (1.25×, the default) and Large (1.5×). Every strip dimension, type and corner derives from that one size (`HUDLayout.size`).

## Voice
Short, warm, confident, never scolding.
- "Let Ribbon tidy your windows."
- "You're here: Terminal · 3 of 7"
- "Nothing to arrange. Open something and it'll find its place."
- "Moved. ⌃⌥Z to undo."
- "Ribbon is paused. Your windows stay put."
