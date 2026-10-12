# Ant City — TODO / roadmap (after v7)

## Done in v7
- [x] WebGL audit: polygon buffer churn removed, soil uploads chunked, broken context-lost handler fixed + auto-reload/resume, autosave 60 s + tab hide, F3 readout, HiDPI/MSAA off.

## Still open after v7
- [ ] Context loss was never reproduced on a real GPU here; confirm on the user's machine (F3 numbers, chrome://gpu).
- [ ] Godot creates/deletes ~1 framebuffer per frame internally (engine, not game code); upgrading to Godot 4.4+ may help.

## Done in v6
- [x] Founding start (queen chamber only, nanitic workers, reserve in the queen chamber); queen chamber fallback store / nursery.
- [x] Skippable 7-step tutorial driven by real actions, highlight, Tutorial button, settings flag, first-launch offer.
- [x] Self-tests: founding + scripted tutorial (survives 30 min), do-nothing run, skip-tutorial run, UI test of Tutorial / Skip buttons.

## Still open after v6
- [ ] Do-nothing colonies still grow to ~14 workers before stalling: could be harsher if wanted.
- [ ] The tiny queen chamber label overlaps when it holds food (cosmetic).
- [ ] Tutorial has no camera step (the whole map is always visible) and no step for rain / raids.

## Done in v5
- [x] Home pheromone (4th grid) laid by outbound ants, followed by returning ants, blended into A* weights; P overlay; saved.
- [x] Raiding rival scouts enter the nest, steal brood / food; workers + soldiers defend inside; loot recovered on kill.
- [x] Diggers haul soil pellets to the mounds (conservation checked by the self-test).
- [x] Gentle rain + shallow flooding (toggle `Config.rain_enabled`), brood moved deeper, HUD banners.
- [x] Balance: early sugar, Auto soldiers on plentiful food, threats matter with soldiers Off.
- [x] Browser-safe keys (K / L / Tab / ?), WebGL load cut ~55 % (primitives), field overlays as one texture, 60 fps cap on web, autosave + context-lost banner.
- [x] Art batch 3 (2x sprites, empty chamber art, sound icons, 4 new sounds, OGG preferred).

## Still open after v5 (be honest)
- [ ] Mid-game sugar can still dip to ~0-5 for a minute in some seeds (recovers; tune with real playtests).
- [ ] Raiders are usually killed before they steal anything (0 thefts in the self-test runs) - may need to be tougher at "Normal".
- [ ] Draw calls are still ~400/frame (each ant switches between sprite and untextured shapes); a MultiMesh / atlas pass would cut it further.
- [ ] The cause of "context lost" on the user's machine was not reproduced here (headless Chrome + SwiftShader ran 20 game-min with no loss); the fix lowers GPU load and adds autosave.
- [ ] Predators / in-flight raids are not saved.

## Done in v4
- [x] Audio manager (ambient surface / nest crossfade, 5 one-shots, throttling, master volume, mute, settings file), HUD indicator.
- [x] Icons on buttons, stats lines and event log; chamber art; ant / predator sprites; sky background.

## Done in v3
- [x] Queen lays in her chamber; nurses carry eggs/larvae to nurseries and relocate brood to better-climate chambers.
- [x] Full storage no longer destroys food (foragers drop it at the entrance, others carry it in later).
- [x] Brood <-> Room reference cycle fixed (weak reference).
- [x] Soil mounds at the entrances (visual).
- [x] Waste chamber, cleaners, corpses, refuse, middens, hygiene -> brood disease.
- [x] Soldier caste (auto / off / max), patrols, alarm pheromone.
- [x] Surface threats (spider, rival scout) with a difficulty toggle; ambient surface death kept tiny.
- [x] Depth based temperature / humidity, brood comfort, H overlay.
- [x] Sugar + protein with separate trails, HUD and colony needs.
- [x] Save / load (F5 / F9), event log, help overlay, ant animation, effect popups.

## Skipped / only partly done in v3 (be honest)
- [x] (v5) **Home pheromone** inside the nest: was skipped in v3. Inside tunnels ants still use A* (perfect memory). Rationale: the outdoor trail is where the
      interesting behaviour is; a home gradient would need a 4th grid and a rewrite of every in-nest walk.
- [ ] Mounds are only decoration: diggers don't physically carry soil out (no "carrying pellet" state) and mounds don't block anything.
- [ ] Threats stay on the surface (no intruders entering the nest, no tunnel flooding).
- [ ] No sound (the request was sound-free feedback: effects + log + HUD warnings only).
- [ ] The save file does not keep predators / in-flight actions (documented in the GDD).

## P0 — polish what exists
- [ ] Balance pass with human playtesting (everything was tuned with the headless self-test only): early-game sugar is tight, soldier AUTO rarely triggers from "food plentiful" alone.
- [ ] Soil pellets physically carried out by diggers; a dig order should be refused if it would cut a chamber off.
- [ ] Mid-aged "storage work": move food between storage chambers, pack food, keep entrances clear.
- [ ] A day/night tint on the sky, ants that react to the day cycle (foraging peaks), seasons that change food respawn.
- [ ] Proper difficulty / scenario presets (food scarcity, start size, threat mix) and a score / game-over screen.
- [ ] A nursery should be able to be *marked* (player priority) as "soldier nursery"; brood caste visible when selected.

## P1 — new systems
- [ ] Queen death / new queen, nuptial flights, colony extinction score.
- [ ] More threats: beetles, rain flooding shallow tunnels, rival colony raids that *enter* the nest, ants fighting rivals underground.
- [ ] Seeds / fungus gardens as a third food chain; storage split by type per chamber.
- [ ] Worker caste variance (minors/majors), trail-quality learning, home pheromone.
- [ ] Disease spreading between chambers (corpses next to the nursery are worse than in the waste chamber).

## P2 — presentation
- [ ] More sound: footsteps, eating, hatching, queen laying, music; positional (panned) effects; a speaker icon for the sound button (none was delivered).
- [ ] Zoom / pan camera, bigger map and chunked rendering; animated sprite sheets (current sprites are single frames, legs are code-drawn).
- [ ] Weather and critters above ground; grass animation.
- [ ] Stats graph panel; tooltips on every HUD element; localisation (ES/EN).
- [ ] Controller / touch input; accessibility (colour-blind task markers).

## Asset follow-ups (from the v4 integration)
- [ ] `load.png` shows an up arrow (reads like "upload"); a down arrow would suit "Load [F9]". `dig.png` is a hammer / pick rather than a shovel. Icons are ~1 px off-centre (62 px opaque in a 64 px canvas).
- [ ] The queen-chamber picture has a queen painted in it, so the real queen appears next to a "ghost" queen (art is drawn at 62 % opacity); an empty-chamber variant would be better.
- [ ] The storage picture has painted sugar / protein items; the live fill heaps are drawn over them on a dark backing.
- [ ] Convert the WAV loops to OGG if memory matters (~2.4 MB of WAV now).

## Tech debt
- [ ] Move `SelfTest` scenarios into GUT/GdUnit tests and add CI (`godot --headless`; remember a parse error makes headless Godot hang -> use `timeout`).
- [ ] Spatial index for `ant_at`, `claim_waste`, `claim_dig_task` if worker counts go into the hundreds.
- [ ] `Colony.gd` is ~1100 lines: split brood logistics, food/waste storage and threat/soldier policy into helper classes.
- [ ] Saves are version-locked (`SaveGame.VERSION`); add migration if the format changes.
