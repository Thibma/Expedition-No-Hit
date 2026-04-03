# ExpeditionNoHit

A UE4SS mod for **Clair Obscur: Expedition 33** that enforces no-hit runs by displaying a game over screen whenever a hero takes damage from an enemy in battle.

---

## What it does

When active, the mod monitors every battle in real time. As soon as an enemy deals damage to any hero, it immediately triggers the defeat screen, forcing you to retry. This lets you practice no-hit runs with automatic enforcement instead of relying on self-discipline.

---

## Requirements

- **Clair Obscur: Expedition 33** (Steam or Epic Games)
- **UE4SS RE-UE4SS 3.0.1 or later**
  - Download from Nexus Mods: https://www.nexusmods.com/clairobscurexpedition33/mods/630

---

## Installation

### Step 1 — Locate your game directory

**Steam (default):**
```
C:\Program Files (x86)\Steam\steamapps\common\Clair Obscur Expedition 33\
```

**Epic Games (default):**
```
C:\Program Files\Epic Games\ClairObscurExpedition33\
```

### Step 2 — Install UE4SS

If UE4SS is not already installed, follow its installation instructions before continuing.

### Step 3 — Copy the mod folder

Copy the entire `ExpeditionNoHit` folder into the UE4SS mods directory:

```
<GameDir>\Sandfall\Binaries\Win64\ue4ss\Mods\
```

The final structure should look like this:

```
Mods\
└── ExpeditionNoHit\
    └── Scripts\
        └── main.lua
```

### Step 4 — Enable the mod

Open the following file in a text editor:

```
<GameDir>\Sandfall\Binaries\Win64\ue4ss\Mods\mods.txt
```

Add this line:

```
ExpeditionNoHit : 1
```

### Step 5 — Verify it works

1. Launch the game
2. Open the UE4SS log at:
   ```
   <GameDir>\Sandfall\Binaries\Win64\ue4ss\Logs\UE4SS.log
   ```
3. You should see lines like:
   ```
   [ExpeditionNoHit] ExpeditionNoHit v1.0.0 loading...
   [ExpeditionNoHit] ClientRestart fired.
   [ExpeditionNoHit] Lifecycle: battle-start hook registered (OnBattleDependenciesFullyLoaded).
   [ExpeditionNoHit] Lifecycle: battle-end hook registered (ResumeExplorationOnBattleEnd).
   [ExpeditionNoHit] ExpeditionNoHit ready.
   ```
4. Enter a battle (check if you can see those lines) and take a hit — the defeat screen should appear immediately.
   ```
   [ExpeditionNoHit] === Battle #1 STARTED — No-hit monitoring ACTIVE ===
   [ExpeditionNoHit] Combat: OnDamageReceived hook connected. Hit detection ACTIVE.
   ```

---

## Uninstall

In `mods.txt`, set the mod to disabled:

```
ExpeditionNoHit : 0
```

Or delete the `ExpeditionNoHit` folder entirely.
