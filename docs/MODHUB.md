# ModHub submission pack — FS25 Transport Company

Everything needed to submit to the GIANTS ModHub, in the order the form asks
for it. Copy the text blocks verbatim.

Run this first — it audits the built zip against what ModHub rejects:

```
py build.py
py tools/modhub_check.py     # must be 0 errors
```

Then run the **GIANTS TestRunner** on the same zip. It is the authority;
`modhub_check.py` is only the fast local pass.

> [!IMPORTANT]
> **Every texture the mod references must be DDS.** The TestRunner's DXTCheck
> looks up parsed DDS data for each referenced texture and crashes outright on
> a PNG:
>
> ```
> ERROR root - 'NoneType' object has no attribute 'header_dx10'
>   File "modules\DXTCheck.py", line 124, in run
> ```
>
> That is a hard blocker, not a warning. `modhub_check.py` now fails on any
> non-DDS texture reference so it is caught before submitting.

---

## 1. Metadata

| Field | Value |
|---|---|
| **Mod name** | Transport Company |
| **Zip filename** | `FS25_TransportCompany.zip` |
| **Version** | 1.0.0.0 |
| **Author** | TisonK |
| **Platform** | PC / Mac |
| **Category** | Gameplay / Placeables |
| **Multiplayer** | Yes (server-authoritative) |
| **Languages** | English, Deutsch |
| **Requires other mods** | No |
| **Map-specific** | No — works on any map |

---

## 2. Description — English

> Paste into the English description field. ModHub strips most formatting, so
> this is written to read correctly as plain text.

```
Own and operate a trucking company.

Your map is already full of silos, dairies and mills moving goods between them.
None of it pays you a penny. Buy a headquarters and it does.

Buy the Transport Company HQ from the shop (Buildings > Sheds) and place it on
your farm. The dispatch office opens in the in-game menu with four sections:

DISPATCH
Freight jobs generated from the loading and unloading stations that already
exist on your map, priced against the live economy. Every job names its pickup,
its drop-off, the amount, the reward and the deadline. Bulk freight is measured
in liters, pallet freight in pallets.

Accept a job and haul it yourself: load at the pickup, tip at the destination,
and watch the progress bar move as you unload. Deliver more than a contract
needs and the surplus rolls onto your next open job rather than being wasted.

Or hire a driver and hand the route to the base game AI as a Load & Deliver
job. Changed your mind? A job you accepted for yourself can still be handed to
a driver later.

FLEET
Every truck keeps its own books: distance driven, diesel burned valued at the
live economy price, revenue earned, driver wages paid and jobs completed.
Trucks enrol themselves as soon as you buy them.

LEDGER
Company totals plus a history of every finished and expired contract.

SETTINGS
Board size, deadline, driver wage share and notifications, all editable in
game. In multiplayer only the host can change them.

Everything uses stock FS25 behaviour: the base AI, the base finance system,
base menu widgets, savegame persistence and multiplayer.

No map preparation of any kind is required.

Note: only vehicles the base game classifies as trucks join the fleet. Many
vehicles are classified as tractors and will not appear.
```

---

## 3. Description — Deutsch

```
Führe dein eigenes Transportunternehmen.

Auf deiner Karte bewegen Silos, Molkereien und Mühlen längst Waren hin und her
- nur verdienst du keinen Cent daran. Mit einer eigenen Zentrale ändert sich das.

Kaufe die Transportunternehmen-Zentrale beim Händler (Gebäude > Hallen) und
stelle sie auf deinem Hof auf. Die Disposition öffnet sich im Spielmenü und hat
vier Bereiche:

DISPOSITION
Frachtaufträge, erzeugt aus den Lade- und Abladestellen, die es auf deiner
Karte ohnehin gibt, bewertet nach den aktuellen Wirtschaftspreisen. Jeder
Auftrag nennt Ladestation, Abladestelle, Menge, Vertragswert und Frist.
Schüttgut wird in Litern gemessen, Palettenfracht in Paletten.

Nimm einen Auftrag an und fahre selbst: an der Ladestation beladen, am Ziel
abkippen, der Fortschrittsbalken läuft beim Abladen mit. Lieferst du mehr als
nötig, wird der Überschuss auf deinen nächsten offenen Auftrag angerechnet
statt verloren zu gehen.

Oder stelle einen Fahrer an und übergib die Route der Spiel-KI als Auftrag
"Laden und liefern". Umentschieden? Auch einen bereits selbst angenommenen
Auftrag kannst du später noch einem Fahrer übergeben.

FUHRPARK
Jeder LKW führt eigene Bücher: Fahrstrecke, verbrauchter Diesel zum aktuellen
Wirtschaftspreis, Einnahmen, gezahlte Fahrerlöhne und abgeschlossene Aufträge.
LKW werden automatisch erfasst, sobald du sie kaufst.

BUCHHALTUNG
Unternehmenszahlen sowie eine Übersicht aller abgeschlossenen und erloschenen
Aufträge.

EINSTELLUNGEN
Anzahl der Aufträge, Frist, Fahreranteil und Benachrichtigungen, alles direkt
im Spiel einstellbar. Im Mehrspieler kann nur der Host sie ändern.

Alles nutzt die Mechaniken des Grundspiels: die Spiel-KI, das Finanzsystem, die
Menü-Elemente, Speicherstände und Mehrspieler.

Es ist keinerlei Vorbereitung der Karte nötig.

Hinweis: Nur Fahrzeuge, die das Grundspiel als LKW einstuft, werden im Fuhrpark
erfasst. Viele Fahrzeuge gelten als Traktor und erscheinen nicht.
```

---

## 4. Changelog — v1.0.0.0

```
v1.0.0.0
- Initial release
- Freight contracts generated from the stations on your map
- Bulk and pallet freight, priced against the live economy
- Haul jobs yourself or hand them to a hired driver via the base game AI
- Per-truck books: distance, fuel, revenue, wages and completed jobs
- Company ledger with completed job history
- In-game settings: board size, deadline, driver wage share, notifications
- Multiplayer support, server-authoritative
- English and German
```

---

## 5. Screenshots

ModHub wants 1920x1080. Six is a good number; the first is the one most people
will judge it by.

| # | Shot | Why |
|---|---|---|
| 1 | Dispatch tab with a full board, a contract selected, detail panel showing the route | The one-image summary of the whole mod |
| 2 | The HQ placed on a farm, in daylight | Shows what you actually buy |
| 3 | A truck tipping at a destination station with the progress bar part-filled | Proves the delivery loop |
| 4 | Fleet tab with two or three trucks and non-zero distance and fuel | The bookkeeping people care about |
| 5 | Ledger tab with completed job history | Shows progression over time |
| 6 | Settings tab | Answers "can I tune it?" before anyone asks |

Take them at 1920x1080 with the HUD clean. Avoid other mods' HUDs in frame.

---

## 6. Pre-submission checklist

- [ ] `py tests/run.py` — all suites pass
- [ ] `py tools/modhub_check.py` — 0 errors
- [ ] GIANTS TestRunner run from GDN, no errors
- [ ] Fresh save: buy HQ, board fills, accept, deliver, paid
- [ ] Hire a driver end-to-end at least once
- [ ] Reload the save: contracts, fleet and ledger all persist
- [ ] `log.txt` clean of `[TransportCompany] Error`
- [ ] Version in `modDesc.xml` matches the submitted zip
- [ ] Screenshots taken at 1920x1080
- [ ] Zip is the one built by `build.py`, not a hand-made archive

---

## 7. Notes for the reviewer

Worth stating in the submission comment if there is a free-text field:

- Ships no copyrighted assets. The HQ reuses a base game shed model
  (`$data/placeables/easySheds/easyShed01/easyShed01.i3d`); all textures and
  the icon are original.
- No external network access, no file writes outside the savegame directory and
  the user profile `modSettings` folder.
- Console commands are prefixed `tc_` and are diagnostic only.
- Debug logging ships disabled.
