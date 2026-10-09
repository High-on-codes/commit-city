# Commit City

A city that grows every time you commit. Each repository is a district drawn as blueprint linework
on carbon black; your personal city is every district together. Neglected projects slowly fade.
Finished ones stay lit forever.

Pure Swift, zero dependencies, zero running cost: GitHub Actions and Pages only. No servers, no
accounts, no personal tokens.

![Demo city](docs/demo.svg)

## Put a city in your README

1. Copy [`templates/commit-city.yml`](templates/commit-city.yml) to `.github/workflows/commit-city.yml`.
2. Settings → Pages → Source: **GitHub Actions**.
3. Push. Then add to your README:

```markdown
[![City](https://<you>.github.io/<repo>/city.svg)](https://<you>.github.io/<repo>/)
[![Commit City](https://<you>.github.io/<repo>/badge.svg)](https://<you>.github.io/<repo>/)
```

The Action rebuilds on every push and once a week, so decay shows even when nobody pushes. It
publishes `city.svg` (README image), `city.json` (data), `badge.svg` and `index.html` (the viewer).

> Pages holds one site per repo. If yours already publishes a site, add the Commit City step to that
> workflow and point `out:` at a subfolder of the site you upload.

## Your personal city

In your profile repo (`<you>/<you>`), copy [`templates/profile-city.yml`](templates/profile-city.yml)
and enable Pages the same way. Each day it lists your public repos with the workflow's own
`GITHUB_TOKEN` and turns every one into a district, oldest first. New repos join on the next run
with no setup. A repo that publishes its own `city.json` (the per-repo action above) is used as
published, so its `.commitcity` settings apply; every other repo is cloned and generated in the
profile run. Repos over 2 GB are skipped; give those the per-repo action instead.

**Private repos are opt-in and shape only.** Set `shape-only: "true"` in that repo's workflow: its
`city.json` then carries geometry and timing, never commit messages, authors, SHAs, folder names or
the repo name. List its URL with `include:` in a `.commitcity-profile` file in your profile repo
([example](templates/.commitcity-profile)). Publishing Pages from a private repo needs a paid
GitHub plan; that is GitHub's rule, not ours.

## Mark a project finished

Commit a `.commitcity` file:

```
status: finished
```

The district never decays and gets a permanent butter beacon. Other keys: `visibility: shape`,
`label: Display name`, `seed: 42`.

## City rules

| Commit | Becomes |
|---|---|
| Lines changed | height (lockfiles, vendored and minified files don't count) |
| Dominant language | style: Swift glass tower, Python low block, Rust factory, Markdown park… |
| `feat` and anything unprefixed | a new building |
| `fix`, `revert` | scaffolding on the latest building of that language in that folder |
| `docs`, Markdown | a tree, or a new park once the last one has five |
| Files touched | footprint |
| ≥ 3,000 lines or ≥ 150 files | a landmark on its own plaza |
| Daily streak | more windows lit, up to all of them at 14 days |
| Folder | neighbourhood: blocks for one folder cluster together |

Roads grow outward from the first commit; a new block always touches the city. Decay: active under
30 days, windows dim from 30 to 90, linework dashes and fades toward a ghost after 90.
The full look is specified in [docs/VISUAL_SPEC.md](docs/VISUAL_SPEC.md).

**Deterministic.** Layout reads only commit order and content, with `Hasher`, dictionary order and
stdlib random sampling kept out of it. The same repo yields the same `city.json`, byte for byte, on
any machine. Per-building detail is keyed on a content hash (author time, email, subject, numstat),
never the SHA, so a rebase that keeps content and order rebuilds the identical city.

## Run it locally

```sh
swift build -c release
.build/release/commitcity generate --repo . --out commit-city   # city.json, city.svg, badge.svg
.build/release/commitcity render commit-city/city.json --out day.svg --at 2025-06-01 --card
.build/release/commitcity merge --out me a/city.json b/city.json
.build/release/commitcity demo --out demo                        # no repo needed
```

For instant, offline updates, put `commitcity` on your `PATH` and install the hook:

```sh
cp hooks/post-commit .git/hooks/post-commit && chmod +x .git/hooks/post-commit
```

It regenerates into `.git/commit-city/` in the background after every commit and never blocks or
fails a commit.

## Web viewer

`viewer/index.html` is one static file. It reads `city.json` beside it (or `?src=`), and supports
pan, pinch and wheel zoom, hover for the commit behind a building, and replay of the whole history
with a scrubber. It re-reads `city.json` every minute and new buildings drop in. Themes: `?theme=cyanotype`,
`?theme=vellum`.

Its geometry is a line-for-line JavaScript port of the Swift geometry. `Tests/viewer-parity.mjs`
checks every point against `commitcity scene` in CI, so the two cannot drift.

## Widget

WidgetKit can't render SVG, so `CityKitUI.BlueprintCanvas` draws the same geometry with SwiftUI
`Canvas`. To ship it, create an app with a Widget Extension in Xcode, add this package's `CityKit`
and `CityKitUI` products to the extension, and add [`widget/CommitCityWidget.swift`](widget/CommitCityWidget.swift).
The widget is configured with your Pages `city.json` URL and shows the whole city or the newest
building.

## Scale

Measured on the git project's own history (82k commits, 61k non-merge, 58k buildings):

| Step | Time / size |
|---|---|
| `git log --numstat` | 46 s (git's own cost; most of the run) |
| Generate + render | 6 s |
| `city.svg` | 2.7 MB (block massing above 12,000 buildings) |
| `city.json` | 27 MB |
| Viewer | 1.3 s to load, 60 fps panning |

## Layout

```
Sources/CityKit      model, git log parser, generator, decay, merge, geometry, SVG, badge
Sources/CityKitUI    SwiftUI Canvas renderer (Apple platforms)
Sources/commitcity   the CLI
viewer/index.html    the web viewer
action.yml           per-repo GitHub Action
profile/             personal-city GitHub Action
templates/           workflows to copy
hooks/post-commit    local hook
widget/              WidgetKit extension source
```
