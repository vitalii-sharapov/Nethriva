# Nethriva brand assets

## Identity

The Nethriva mark combines a remote display, terminal prompt, and layered session cards. Its midnight-navy base and electric-blue connection layers are paired with a small emerald terminal-status accent.

The master assets are:

- `Nethriva/Resources/Brand/Nethriva-AppIcon-Master.png` — high-resolution RGBA app-icon source
- `Nethriva/Resources/Brand/Nethriva-Wordmark.png` — transparent horizontal logo lockup
- `Nethriva/Resources/Assets.xcassets/AppIcon.appiconset` — generated macOS application icon sizes
- `Nethriva/Resources/Assets.xcassets/NethrivaMark.imageset` — in-app mark at 1×, 2×, and 3×
- `Nethriva/Resources/Assets.xcassets/AccentColor.colorset` — light- and dark-appearance accent colors

Keep the mark proportions intact. Do not recolor individual layers, add text inside the app icon, or place the wordmark on a visually busy background.

## Reproducible app-icon prompt

```text
Use case: logo-brand
Asset type: master macOS application icon for Nethriva, a native SSH, SFTP, terminal, and remote-desktop connection manager
Primary request: create an original, premium app icon that combines three ideas in one extremely clear symbol: a remote computer display, a terminal prompt chevron, and two subtly layered session cards suggesting a deck of active connections
Style/medium: polished vector-like macOS app icon, minimal geometry, crisp edges, restrained dimensionality, professional developer-tool aesthetic
Composition/framing: centered strong silhouette with generous internal padding; a rounded-square app tile filling most of a square canvas; large readable forms that remain recognizable at 16 pixels
Color palette: deep midnight navy and graphite base, luminous electric cyan-to-blue accent, one very small emerald terminal-status accent; sophisticated high contrast, compatible with light and dark macOS desktops
Lighting/mood: subtle soft depth and controlled highlights, confident and technical, not playful
Materials/textures: smooth matte surfaces with a very slight glass edge highlight; no noisy texture
Constraints: no words, no letters, no brand names, no tiny interface details, no photorealism, no mockup device, no surrounding scene, no watermark, no resemblance to existing remote-access product logos; preserve a clean square master suitable for deriving all macOS icon sizes; transparent outside the rounded-square tile if supported
Avoid: gradients that become muddy at small sizes, excessive glow, generic cloud symbols, locks, globes, handshakes, mascots, skeuomorphic cables, fine lines
```

## Reproducible wordmark prompt

```text
Use case: logo-brand
Asset type: horizontal Nethriva logo lockup for README, DMG, About window, and release materials
Input images: Image 1 is the approved Nethriva master app icon and must be preserved as the brand mark
Primary request: create a clean horizontal lockup with the approved icon on the left and the exact wordmark "Nethriva" on the right
Style/medium: premium vector-like brand lockup, native macOS developer-tool aesthetic
Composition/framing: wide horizontal canvas, vertically centered, icon at left at approximately the height of the wordmark block, balanced clear space, generous transparent margins
Color palette: preserve the icon colors; render the wordmark in deep midnight navy with a subtle electric-blue accent only if needed for visual unity
Text (verbatim): "Nethriva"
Typography: modern humanist geometric sans serif, medium-to-semibold weight, highly legible, professional, exact capitalization N-e-t-h-r-i-v-a
Constraints: preserve the icon design and proportions; genuinely transparent background; render the word Nethriva exactly once with no spelling changes; no tagline, no extra text, no mockup, no watermark
Avoid: condensed fonts, futuristic gimmick fonts, excessive glow, shadows behind the wordmark, additional symbols
```
