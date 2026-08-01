# itch.io page — The First Day

Copy for `lucaslizama/the-first-day`. Field names match itch.io's edit-game form.

**The theme below is the author's, stated 2026-07-31**, and is recorded here because it exists
nowhere else in the project: the game is a metaphor for a first day at work — the fear, the
expectations you put on yourself, the fear of failing, and the consequences of failing. Everything
else on this page is drawn from what the game demonstrably does.

That framing changes how the page should read. The death mechanic is not a feature sitting beside
the theme, it **is** the theme: failure is not punished with a retry, it permanently narrows what
you can see and raises what you can hear, and finishing never clears it. The copy below leads with
that rather than listing obstacles.

---

## Title

```
The First Day
```

## Short description / tagline

itch shows this in listings and search, so it has to work alone. Under ~140 characters.

**Recommended:**

```
Your first day at a new job, and the fear of failing it. Every failure makes it harder to see.
```

Alternatives, if a different emphasis is wanted:

```
A game about your first day at work: the fear, the expectations, and what failing costs you.
```

```
Nothing in this office chases you. You do that yourself.
```

The recommendation puts the theme and the mechanic in one sentence, in that order, because they are
the same thing — the fear of failing is not described to the player, it is applied to them. The
third option is the most striking and the least clear; it works if the cover carries the tone, and
not otherwise.

## Classification

| Field | Value |
|---|---|
| Kind of project | **Downloadable** |
| Classification | **Game** |
| Release status | **Released** |

## Pricing

**Recommended: No payments (free).** It is a game-jam port with one level. "Donations accepted"
is a reasonable alternative if you want a tip jar; paid is not defensible for a few minutes of play.

## Uploads

Already in place, pushed by butler:

| Channel | Platform | Notes |
|---|---|---|
| `windows` | Windows | 192 MB. `TheFirstDay.exe` + `.pck` + `data_…` — all three are required, they ship together |
| `linux` | Linux | 158 MB. `TheFirstDay.x86_64` + `.pck` + `data_…`; mark the binary executable is not needed, butler preserves the bit |

butler sets the platform flags from the channel names, so both should already show the right icons.
Worth confirming the **"This file will be played in the browser"** box is *unchecked* on both.

The size is almost entirely the bundled .NET runtime — the game itself is 11 MB of `.pck`. If a
player asks why a jam game is 190 MB, that is the answer.

## Genre and tags

**Genre:** `Platformer`

**Tags** — itch allows up to 10; these are the ones the game can actually claim:

```
3d, atmospheric, godot, low-poly, psychological-horror, short, singleplayer, third-person, unity-port, work
```

Notes on three of them:

- **`psychological-horror`** rather than plain `horror`, now that the theme is known. There is no
  monster and no chase; the dread is anxiety made mechanical. Plain `horror` sets up an expectation
  of threat that the game deliberately does not meet, and people who came for that will bounce.
- **`work`** is a real itch tag and unusually well-earned here — it puts the game in front of people
  looking for exactly this subject rather than for a platformer.
- **`unity-port`** is unusual but true, and genuinely interesting to a slice of people. Cut it if you
  would rather the port not be the first thing noticed.

## Description (page body)

```
The First Day

It is your first day at a new job. This is a game about the fear that comes with it — the
expectations you put on yourself, the fear of failing, and what failing does to you.

Get to the end of the floor. Walk, run and jump past swinging hammers, platforms that move and
platforms that give way under you. Checkpoints keep you moving forward. Nothing chases you; there
is no monster on this floor.

The pressure is not coming from outside. The office keeps count instead. Every death dims the edges
of your vision a little further, pulls the colour apart at the corners, and raises the whispering
from the desks around you. Failure is not something you retry past — it accumulates, and it stays.
Reach the end and none of it lifts. You get there, the confetti falls, and you are still carrying
every mistake you made getting there.

Made in November 2016, in Unity, for Asylum Jam.

Rebuilt in Godot 4 in July 2026 — almost ten years later — from the original project rather than
from memory. The level geometry, the mixer levels, the animation timings and the camera behaviour
are all carried across from the 2016 source, with every deliberate difference written down.

Controls
    WASD or left stick   move
    Mouse or right stick look
    Shift or a shoulder  run
    Space or the A/X     jump
    Escape or Start      pause
    A gamepad works throughout, and is analog — a half-pushed stick walks.

A few minutes to finish, longer if the office wins a few times first.

Credits
    Programming            Lucas Lizama
    3D Modeling & Animation Ian Genskowsky, Kathya Zuñiga, Fernando Castillo
    Concept Art            Fernando Castillo, Kathya Zuñiga
    Music                  Guillermo Rojas
    Sounds                 freesound.org — whisper1.wav by thanvannispen,
                           "small group whispering.wav" by speedygonzo,
                           looping-hollow-open-air-wind.wav by robinhood76
    Godot port             Lucas Lizama, Ian Genskowsky

Source: https://github.com/lucaslizama/the-first-day-godot
```

Two things about that text worth keeping if you edit it:

- **"Nothing chases you."** This is a kindness to the reader. The tags say horror and the
  description mentions whispering; without that line, people who bounce off chase horror will
  assume the worst and skip it.
- **"none of it lifts"** is a factual statement about the game, not a flourish: the death constant
  is never reset by finishing, so a player who died eight times sees the ending through the full
  vignette and aberration.

## Metadata tab

| Field | Value | Why |
|---|---|---|
| Input methods | **Keyboard**, **Mouse**, **Gamepad (any)** | All three verified working; the gamepad path is analog and complete |
| Average session | **A few minutes** | One level. Honest for a first clean run |
| Languages | **English** | The UI is English throughout. The original was Spanish — that text is gone from the build |
| Accessibility | **leave everything unchecked** | See below. This is the honest answer, not an oversight |
| Multiplayer | none | Singleplayer only |

**On accessibility, deliberately claiming nothing.** itch's checkboxes are things like subtitles,
configurable controls, colour-blind friendly and one-button. This build has no subtitles, no
in-game rebinding (the input map is fixed in `project.godot`), and the core feedback mechanic is a
*visual* darkening plus an *audio* swell with no alternative signal. Ticking any of those boxes
would be a promise the game does not keep. If you want to be able to tick some later, in-game
rebinding is the cheapest real win.

## Content warnings

itch has no formal rating, but the description should carry a line and the page has an adult-content
toggle (leave it **off** — nothing here warrants it).

What is honestly in the game: **repeated player death**, an increasingly distorted screen, layered
whispering voices, and — now that the theme is stated — **themes of workplace anxiety and
self-imposed pressure to not fail**. There is no gore, no jump scare, and no chase.

That last item is worth naming rather than leaving implicit. A game whose subject is the fear of
failing at a new job, and whose mechanic is failure that accumulates and never clears, can land
harder than a horror tag on someone going through exactly that. Naming it costs nothing and lets
people choose.

```
Contains repeated player death, screen distortion that intensifies as you fail, and layered
whispering voices. Themes of workplace anxiety and the pressure not to fail. No gore, no jump
scares, nothing chases you.
```

## Links

| Field | Value |
|---|---|
| Source / repository | `https://github.com/lucaslizama/the-first-day-godot` |
| Community | **Comments** is a sensible default; Discussion board is overkill for one level |
| Visibility | **Public** once the cover image is in place — itch will not let you publish without one |

---

## Images — captured, in `docs/itch/`

All from the real game at 1920×1080, positions chosen by raycasting for actual floor so nothing is
a shot of the void. Covers are 1260×1000, twice itch's 630×500 minimum at its exact 1.26 aspect.

### Cover — two candidates, `cover_a_doorway.png` recommended

| File | What it is |
|---|---|
| **`cover_a_doorway.png`** | Fortunato in the doorway, from the menu. **Recommended.** |
| `cover_b_vista.png` | The ending's canyon of office towers, coworkers watching from the ledges |

`cover_b_vista.png` is the more beautiful image, and it is the better *screenshot* — which is why
it is already in the set below as `05_ending.png`. But the cover is displayed at **315×250** in a
listing grid, and at that size the vista's detail collapses into grey mush while a face with two
bright eyes still reads instantly. Pick the one that survives being small, not the one that looks
best at full size.

A note on `cover_a_doorway.png`: the first crop caught the tail of the menu's title text at the
left edge. Re-cropped past it. If you re-cut it yourself, keep clear of the left third of
`menu.png`.

### Screenshots, in upload order

| File | What it shows |
|---|---|
| `01_start.png` | The first room and the tutorial signs — where the player starts, at zero deaths |
| `02_hammers.png` | The walkway over the void, office slabs and doors suspended in the dark, hammers ahead |
| `03_hammers_deaths.png` | **The same camera at nine deaths.** Corners crushed, colour split on every edge |
| `04_platforms.png` | The falling-platform stretch |
| `05_ending.png` | The canyon of towers at the end, with coworkers watching from the ledges |
| `06_start_deaths.png` | The first room at nine deaths, for the same before/after read as 02 → 03 |

**Upload `02_hammers.png` and `03_hammers_deaths.png` adjacent.** Side by side they show that the
distortion is a mechanic responding to failure; either one alone just looks like a colour grade.
That pair is the single most useful thing on the page.

## What I could not determine

Stated plainly so nobody mistakes silence for research:

- **The theme came from the author, not the repository.** It is written down here now, and nowhere
  else in the project: the Unity `README.md` is the single line `AsylumJam2016` and there is no
  design document. Worth keeping in mind if this page is ever rewritten from the code alone — the
  code cannot tell you what the death mechanic is *for*.
- **I have deliberately not characterised Asylum Jam's rules or theme.** The jam's name is a
  documented fact — it is in the credits and the Unity README — but I am not certain enough about
  what the jam asked of entrants to put a claim about it on a public page. The dates below are from
  git and are solid; the jam's own framing is not mine to assert.
- **The dates are exact, from git.** The Unity project's first commit is 2016-11-12 and its last is
  2016-11-20. The port's first commit is 2026-07-28 and `v1.0.0` was tagged 2026-07-31. "Almost ten
  years later" is 9 years 8 months. The page says "November 2016" rather than naming jam dates,
  because the commit range spans nine days and I do not know which of those was the jam itself.
- **The Windows build has never been launched.** It exported by the same path as the Linux build,
  which does run, and it is a valid PE32+ x86-64 binary with the C# assembly beside it. That is not
  the same as it starting. Worth confirming before the page gets traffic.
