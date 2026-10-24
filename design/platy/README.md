# Platy

Platy is PlatyNotch's mascot, a platypus. A platypus borrows a feature from lots of other
animals, the way PlatyNotch borrows the best ideas from other notch apps. Platy is original
work drawn in code. It is vector art, it animates, it is tiny, and it is Apache-2.0 like
the rest of the project. There are no copied artwork, fonts or other outside assets.

- `platy.svg` is the master drawing. It is hand-written in a 100 × 100 box (y down) in the
  idle pose with full detail.
- `apps/mac/Sources/PlatyNotchUI/Mascot/PlatyArt.swift` (`PlatyShapes`) draws the same
  shapes with the same numbers in a SwiftUI `Canvas`. If you change one, change both.
- The mood and pose math (`PlatyMood`, `PlatyPoseValues`) lives in PlatyNotchKit and is
  tested there.
- To re-render the app icon:
  `PLATYNOTCH_HOME=/tmp/pn PlatyNotch --render-icon /tmp/icon && iconutil -c icns /tmp/icon/AppIcon.iconset -o apps/mac/Resources/AppIcon.icns`
- To render the art review set (contact sheet, icons, menu bar, pill):
  `PLATYNOTCH_HOME=/tmp/pn PlatyNotch --platy-gallery <dir>`

## Palette

| Part | Hex |
|---|---|
| Body (gradient top / middle / bottom) | `#4E8F80` / `#3F7D70` / `#336A5F` |
| Outline (64 pt and up) | `#1F4640` |
| Belly (60% over the body) | `#9BCBB5` |
| Tail / tail texture and edge | `#7E5739` / `#5E3F28` |
| Bill / lower bill / bill line | `#F6E7C6` / `#E6CFA2` / `#B8966A` |
| Nostrils | `#8E7049` |
| Paws and feet / their lines | `#EDCB97` / `#B78F5B` |
| Eyes / glint | `#1A2124` / `#FFFFFF` |
| Cheeks (55%) | `#F29C94` |
| Headphones band / cups / pads | `#2A2E35` / `#FF6F59` / `#C4493A` |
| Sparkle / sparkle edge | `#FFD25A` / `#D99A00` |
| Done check badge | `#2FB75A` with a white check |
| Sleepy "z" | `#9FB8FF` |
| Waiting rim and tail | `#FFB020` |
| App icon background (top to bottom, glow) | `#1F4E78` to `#0A1630`, glow `#3A7FA8` |
| App icon notch | `#05080C` |

## Proportions (in the 100 box)

- **Head:** an ellipse centred on (50, 42), 64 × 56. **Body:** an ellipse centred on
  (50, 70), 62 × 48. Together they make one gumdrop shape: the platypus has no neck.
- **Bill:** a rounded rectangle at (26, 46), 48 × 20, radius 10. It is the widest feature of
  the face and is what makes Platy a platypus. The lower bill below the smile is a shade
  darker.
- **Eyes:** centred on (37, 36) and (63, 36), radius 5.4, or 6.4 when tiny. They sit high,
  well above the bill.
- **Tail:** a flat beaver paddle 36 long and 18 wide. Its base is at (66, 84), turned −22°,
  so it pokes out at the lower right. That asymmetry helps the silhouette read at 16 px.
- **Feet:** 22 × 10 ellipses at the bottom. **Front paws:** small webbed paws (a palm and
  three toes) on the sides of the belly.
- **Platy stands on** (50, 95). Leaning and breathing pivot there.

## Sizes

The design starts from the silhouette at 16–32 pt (the menu bar and the pill), and detail
is added as the size grows (`PlatyDetail`):

| Size | What shows |
|---|---|
| Under 28 pt (pill 22 pt, menu bar, small icons) | Silhouette, bigger eyes, two-tone bill, feet, tail. No paws, nostrils, smile line or cheeks. |
| 28–63 pt | Adds paws, nostrils, the smile and the body gradient. |
| 64 pt and up | Adds the outline, tail texture, toes and webbing, and cheeks. |

The **menu bar** icon is a one-colour template image (macOS tints it). The eyes are holes,
and the bill is drawn wider than the head with a gap around it, so the duck bill reads.

The **app icon** follows the macOS grid: an 824 × 824 rounded square (radius 185, continuous)
in a 1024 canvas with a soft shadow. It has a night-blue gradient, a black notch at the
top, and Platy in the middle. At 64 px and below, Platy fills more of the plate.

## Moods

Moods must read at pill size (22 pt). Each one has a cue that also shows in the still frame
(Reduce Motion, a hidden panel):

| Mood | Cue | Motion |
|---|---|---|
| idle | plain | none (still) |
| working | paws out | paddling, a bob on each stroke (0.8 s) |
| thinking | head tilted | slow sway (3 s) |
| waiting | amber rim and tail | two tail taps, then a pause (1.2 s) |
| done | green check and a sparkle | small sparkle pulse (1.6 s) |
| dancing | headphones, eyes closed | bounce on the beat, sway (1.2 s) |
| focused | half-closed eyes | none (still) |
| sleepy | closed eyes, "z" | slow breath at 1 frame a second (4 s) |
| celebrating | paws up, big sparkles | a jump (1 s) |

## Do

- Keep Platy front-facing, round and friendly, with the bill as the widest feature.
- Keep the outline off at small sizes. Simplify rather than shrink detail.
- Put mood cues outside the face (badge, sparkles, "z", headphones, rim) so they read at 22 pt.
- Check every change in the gallery at 22 pt on black and on light, and at 16 px for the icon.

## Don't

- Don't give Platy a realistic dark bill, teeth, claws or anything scary.
- Don't add text, fonts or outside images to the drawing.
- Don't tint the whole body for a mood: a tinted body looks unwell. Use a rim or a badge.
- Don't animate while nothing is live. Idle and focused are still, and sleepy runs at 1 fps.
- Don't redraw the art from another mascot or stock image.
