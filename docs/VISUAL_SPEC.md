# Blueprint visual spec

Premium blueprint: thin isometric linework on carbon black, one butter accent. No fills, no
gradients. Height, line weight and light carry all the information.

## Tokens

| Token | Value | Use |
|---|---|---|
| Background | `#111111` carbon | page, and the colour every occluder is filled with |
| Ink | `#ECE8DD` warm white | all structure |
| Accent | `#E9D58B` butter | lit windows, the newest building, beacons, the caption eyebrow |

Occluders are filled with the background colour and never stroked. That is hidden-line removal for
the painter's algorithm, not a visible fill: the eye only ever sees lines.

## Line classes

Weights are output pixels at full scale; they thin to 40% when a huge city is fitted into one frame.

| Ink | Colour | Alpha | Weight | Carries |
|---|---|---|---|---|
| structure | ink | 0.80 | 0.80 | building edges |
| landmark | ink | 0.96 | 1.35 | landmark edges and spires |
| detail | ink | 0.34 | 0.55 | mullions, floor bands, scaffolding, rooftop plant |
| windowDark | ink | 0.085 | 0.90 | unlit windows |
| windowLit | accent | 0.95 | 1.00 | lit windows |
| ground | ink | 0.16 | 0.60 | block curbs, park outlines, plaza rings |
| road | ink | 0.22 | 0.60, dash 1.5/3.5 | road centrelines between claimed blocks |
| accent | accent | 1.00 | 1.10 | newest building, finished beacon, landmark finial |

## Geometry

* Isometric projection: `sx = (x − y)·cos30°`, `sy = (x + y)/2 − z`. Viewer looks from +x, +y, +z, so a
  box shows its top, +x face and +y face.
* A lot is 1×1. A block is 3×3 lots; the block pitch is 4, leaving a one-lot road.
* A floor is 0.16 lot units. Windows are one tick per 0.16-wide cell per floor, at 28–72% of the cell.

## Building styles

| Language | Style | Form |
|---|---|---|
| Swift, Kotlin | glass tower | slender box, full-height mullions, antenna from 14 floors |
| Python | low block | wide, a third of the height, floor bands |
| Rust, C, C++ | factory | sawtooth roof, chimney |
| JS, TS, Go | stepped tower | three setback tiers from 6 floors |
| Java, C#, other | slab | window grid, rooftop plant from 10 floors |
| Ruby, PHP, shell, config, web | gabled | at most 4 floors, pitched roof |
| Markdown / docs | park | ground outline, up to five trees |

Landmarks (≥ 3,000 changed lines or ≥ 150 files) get a block to themselves, a plaza ring, heavier
line weight and a spire with a butter finial.

## Time

| State | Look |
|---|---|
| Active, < 30 days | full linework, windows as lit by the streak |
| Idle, 30–90 days | lit windows fade to 15% |
| Abandoned, 90+ days | linework dashes and fades from 72% toward 22% over nine months |
| Finished | never decays; a butter beacon (mast and double ring) crowns the tallest building |

Inside a living district, a neighbourhood untouched for 30+ days dims its own windows.

## Level of detail

| Buildings | SVG and viewer |
|---|---|
| ≤ 2,500 | full detail |
| ≤ 12,000 | no windows, mullions or bands |
| > 12,000 | each block becomes one massing volume at its 75th-percentile height, with sparse lit bands; landmarks, the newest building and beacons stay individual. The viewer switches back to buildings as you zoom in. |
