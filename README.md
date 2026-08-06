<div align="center">

# 🚚 FS25 Transport Company
### *Freight Dispatch & Fleet Management*

[![Downloads](https://img.shields.io/github/downloads/TheCodingDad-TisonK/FS25_TransportCompany/total?style=for-the-badge&logo=github&color=f5b335&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_TransportCompany/releases)
[![Release](https://img.shields.io/github/v/release/TheCodingDad-TisonK/FS25_TransportCompany?style=for-the-badge&logo=tag&color=ffd47c&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_TransportCompany/releases/latest)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-lightgrey?style=for-the-badge&logo=creativecommons&logoColor=white)](https://creativecommons.org/licenses/by-nc-nd/4.0/)
<a href="https://paypal.me/TheCodingDad">
  <img src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif" alt="Donate via PayPal" height="50">
</a>

<br>

> *"Bought the Volvo thinking I'd haul my own grain. Three contracts later I'd not touched the wheel once, the drivers were doing the miles, and I was sat in the office watching the ledger tick up. Turns out I didn't want to be a trucker. I wanted to own trucks."*

<br>

**Your map is already full of silos, dairies and mills moving goods between them. None of it pays you a penny.**

Buy a headquarters and it does. Freight jobs are generated from the stations that already exist on your map, priced against the live economy. Haul them yourself, or put a driver in the cab and let the base game AI run the route while your fleet quietly books the miles, the diesel and the profit — truck by truck.

`Singleplayer` • `Multiplayer (server-authoritative)` • `Persistent saves` • `English & Deutsch` • `Any map, no preparation`

</div>

> [!NOTE]
> **No map preparation of any kind.** Contracts are built from the loading and unloading stations already present on whatever map you play. Nothing to patch, nothing to install alongside it.

> [!IMPORTANT]
> The dispatch office stays empty until you own a **Transport Company HQ**. Buy it from the shop under **Buildings → Sheds** and place it — the board fills the moment it is standing.

---

## ✨ Features

### 📋 Contract Board

Jobs are generated from real stations on your map, priced against the live economy **and the route length** — a long haul pays more than a short one for the same goods.

| | Type | Measured in | Notes |
|---|---|---|:---|
| 🌾 | **Bulk freight** | Liters | Grain, roots, silage — anything a tipper carries |
| 📦 | **Pallet freight** | Pallets | Palletisable goods, priced against the live economy |

Jobs come in three **priority tiers**:

| Tier | What it means | Pay |
|---|---|---|
| Standard | The usual job | Baseline |
| ⏱ Urgent | Half the deadline | +50% |
| 📦 Bulk | Up to 50% more volume | Tighter margin, more turnover |

Every contract names its pickup, its drop-off, the amount, the reward and the deadline. Only routes whose source actually holds stock are offered, and the amount is **sized to your fleet** — a job never asks for more than a few loads of your biggest truck and trailer.

### 🚛 Two Ways To Run A Job

| Approach | How it works | The catch |
|---|---|---|
| 🧑‍🌾 **Haul it yourself** | Load at the pickup, tip at the destination. Progress moves as you tip. | Your time |
| 🤖 **Hire a driver** | Hands the route to the base game AI as a Load & Deliver job. | The driver keeps a cut |

Changed your mind halfway? A job you accepted for yourself can still be handed to a driver later — the **Hire driver** button stays available until someone is actually in the cab.

> [!TIP]
> Over-tipping is never wasted. Deliver more than a contract needs and the surplus rolls straight onto your next open job for the same goods.
>
> The detail panel tells you a job's **distance, estimated fuel cost and estimated profit before you accept** — the reward is a haul, not just a goods price.

### 🚚 Per-Truck Books

The base game only keeps farm-wide statistics. This tracks every truck separately — including the jobs **you** drive.

| | Tracked | Source |
|---|---|---|
| 📏 | **Distance** | Accumulated every physics tick, not sampled |
| ⛽ | **Fuel** | Diesel burned, valued at the live economy price |
| 💰 | **Revenue** | Contracts delivered with that truck, hauled by you or a hired driver |
| 👷 | **Wages** | Driver cuts, kept separate from fuel |
| 📦 | **Jobs** | Completed deliveries |

Trucks enrol themselves. Anything the base game classes as a truck and your farm owns appears in the Fleet tab within a few seconds of purchase.

### 💼 Run A Business

Beyond the board, the company runs like one — hire people, grow, spend, and watch the books.

| System | What it does |
|---|---|
| 🧑‍🤝‍🧑 **Named drivers** | Hire drivers from the **Drivers** tab. Each has a name, a weekly wage and experience that grows with every completed contract (and raises their wage). Assign one to a truck and hired-driver jobs on that truck ride their record. |
| ⭐ **Reputation & level** | Delivering on time builds reputation; missing a deadline costs it. Higher reputation means more drivers on the payroll. |
| 🏢 **HQ upgrades** | Spend money to raise the HQ tier — bigger board, more drivers. |
| 🔧 **Maintenance** | Trucks need a service every 5000 km. The Fleet tab tells you when one is due; skipping it never stops the truck, but the bill catches up in the books. |
| 📈 **Weekly P&L** | The Ledger shows a rolling weekly profit-and-loss so you can see the company trending, not just the lifetime totals. |

### 📖 Company Ledger

Revenue, driver wages, fuel, distance and job count for the company as a whole, followed by a history of every finished and expired contract, newest first.

Company figures are tracked separately from the fleet on purpose — a load you tip yourself is credited to the truck that is physically discharging, but the aggregate company book keeps one consistent total regardless of how a job was run.

### 📱 Dispatch Office

Five tabs in the in-game menu, built from stock FS25 menu widgets so it looks and behaves like the rest of the game.

| Tab | Shows |
|---|---|
| 📋 **Dispatch** | Open jobs, with full route and progress detail |
| 🚚 **Fleet** | Every enrolled truck and its books |
| 💼 **Drivers** | The payroll: hire, assign and fire named drivers |
| 📖 **Ledger** | Company totals, weekly P&L and completed job history |
| ⚙️ **Settings** | Everything below, editable in-game |

---

## ⚙️ Settings

All settings live in the **Settings** tab of the dispatch office. Highlight one and use **Change** to cycle it, or **Reset** to restore the default.

| Setting | Options | Default | What it does |
|---|---|---|---|
| **Company enabled** | On / Off | On | Master switch — stops generation and bookkeeping |
| **Contracts on the board** | 1 – 12 | 5 | How many open jobs the board holds |
| **Deadline (days)** | 1 – 30 | 7 | Time allowed once a contract is accepted |
| **Driver wage share** | 0 – 100% | 20% | Cut a hired driver keeps from the reward |
| **Notifications** | On / Off | On | Messages on accept, delivery and expiry |
| **Debug logging** | On / Off | Off | Verbose output to the game log |

> [!IMPORTANT]
> Every setting except **Debug logging** applies to the whole server. In multiplayer each farm that owns an HQ runs its **own** company — its own board, fleet and ledger — and only the host can change the shared settings for their company. Debug logging is per player and always editable.

---

## 🖥️ Console Commands

Available with the developer console enabled.

| Command | Description |
|---|---|
| `tc_debug` | Toggle verbose logging |
| `tc_generate_contract` | Force a job onto the board |
| `tc_list_contracts` | List ids, states and progress |
| `tc_list_trucks` | List what actually enrolled |
| `tc_drivers` | List the payroll, reputation and HQ tier |
| `tc_hire_driver` | Hire a named driver (debug) |
| `tc_reset_settings` | Reset settings to defaults |
| `tc_stations` | List every loading station, its stock and whether the AI can load there |
| `tc_reset_board` | Clear the board and regenerate it |

`tc_list_trucks` is the quickest way to confirm whether a vehicle qualifies as a truck.

---

## 🛠️ Installation

**1. Download** `FS25_TransportCompany.zip` from the [latest release](https://github.com/TheCodingDad-TisonK/FS25_TransportCompany/releases/latest).

**2. Copy** the ZIP (do not extract) to your mods folder:

| Platform | Path |
|---|---|
| 🪟 Windows | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\` |
| 🍎 macOS | `~/Library/Application Support/FarmingSimulator2025/mods/` |

**3. Enable** *Transport Company* in the in-game mod manager.

**4. Load** any career save — the dispatch office appears immediately.

---

## 🎮 Quick Start

```
1. Open the in-game menu → the truck tab is there straight away
2. Buy the Transport Company HQ → shop → Buildings → Sheds
3. Place it on your farm → the contract board fills instantly
4. Dispatch → pick a job → check its route in the panel on the right
5. Accept it yourself, or press Hire driver and let the AI run it
6. Load at the pickup station, drive over, tip at the destination
7. Progress climbs as you tip → the reward lands when it completes
8. Fleet → see the diesel and miles that job actually cost you
9. Ledger → watch the company books, job by job
```

> [!TIP]
> Buy a truck before your first job. A tractor will not enrol in the fleet and cannot be handed to a driver — the base game has to classify the vehicle as a truck.

---

## ⚠️ Known Limitations

| Issue | Details |
|---|---|
| 🚚 **What counts as a truck** | Only vehicles the base game classes as trucks enrol in the fleet. Many vehicles are classed as tractors and will not appear. This is deliberate, not a fault. |
| 🤖 **Hired drivers are fussier than you are** | The AI needs an AI-loadable fill type and stock your farm can actually draw, which is stricter than what you can haul by hand. When a job cannot be driven the mod says exactly why. |
| 💰 **Selling stations pay twice** | If a contract's destination happens to be a selling point, you are paid for the goods and for the contract. Defensible — you were paid to haul someone's cargo — but worth knowing. |
| 🌐 **Multiplayer** | Each farm that owns an HQ runs its own company — independent board, fleet, ledger and settings. Contracts, payouts and AI dispatch run on the server. Clients request changes and receive the result for their own company. |
| 📦 **Pallet contracts** | Counted at 1000 L per pallet, the standard FS capacity. Unusual pallets may not line up exactly. |
| 🚛 **Self-haul attribution** | A self-hauled delivery is credited to the truck that is physically discharging at the station. If the match cannot be made (a parked truck, an unusual setup), the job still completes and pays — it just is not pinned to a truck in the Fleet tab. |

---

## 🤝 Contributing

Found a bug? [Open an issue](https://github.com/TheCodingDad-TisonK/FS25_TransportCompany/issues/new) — the game log (`log.txt`) is worth more than a description.

Want to contribute code? PRs are welcome on the `development` branch.

```
py build.py --deploy      # build the zip and install it
py tests/run.py           # 123 assertions (needs: pip install lupa)
py tools/modhub_check.py  # audit the built zip for ModHub
py tools/build_icons.py   # regenerate the artwork and icon.dds
```

The test suites stub the engine and load the **real** mod sources under LuaJIT 5.1 — the same runtime FS25 uses — so they exercise shipped code rather than a copy.

---

## 📝 License

This mod is licensed under **[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)**.

You may share it in its original form with attribution. You may not sell it, modify and redistribute it, or reupload it under a different name or authorship. Contributions via pull request are explicitly permitted and encouraged.

**Author:** TisonK &nbsp;·&nbsp; **Version:** 1.2.0.0

© 2026 TisonK - See [LICENSE](LICENSE) for full terms.

---

<div align="center">

*Farming Simulator 25 is published by GIANTS Software. This is an independent fan creation, not affiliated with or endorsed by GIANTS Software.*

*Somebody has to move it.* 🚚

</div>
