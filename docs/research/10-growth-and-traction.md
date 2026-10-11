# 10 — Growth & Traction: How Bass-Booster / EQ / Menu-Bar Apps Got Their First Users (and a 90-Day GTM for Bass Shake)

_Research date: 2026-10-11. Method: ~40 web searches. Direct page fetches were blocked by the sandbox proxy for most hosts, so most facts come from search-result summaries of the cited pages; raw.githubusercontent.com was reachable and was used to check FineTune's README. Labels used below: **[verified]** means a primary or near-primary source confirms it; **[secondary]** means one third-party source; **[estimate]** means my own inference or arithmetic; **[unverified]** means a claim (often from the brief or the screenshot) that I could not confirm._

---

## 0. TL;DR

1. **Boom was a 2011 Mac app, not a 2013–2016 one.** It debuted at Macworld Expo in January 2011, won Best of Show, and reached the Mac App Store in June 2011. Global Delight then grew it with **paid sponsorships of Apple-enthusiast media** (TidBITS, Macdrifter, MacStories), **TechCrunch coverage**, **paid version resets** (Boom 2 at $14.99 in Dec 2014, Boom 3D at $16.99 in June 2017), heavy discounting (up to 75% off at Black Friday and anniversaries), and **bundles** (Bundlehunt, StackSocial, Setapp). The iOS app came in May 2016 and leaned on a regional Apple feature plus a 60% discount (India). The company reports 20M+ downloads, which is self-reported.
2. **The anonymous iOS "Bass Booster" apps grow through ASO plus a subscription paywall, not through brand.** Their titles are built from keywords. Typical pricing is a 3-day trial followed by **$2.99/week, $9.99/month or $49.99/year**. In Adapty's 2026 data, Utilities takes **73.6% of its subscription revenue from weekly plans**, against 55.5% across all categories.
3. **The screenshot's revenue/download ratios point to two business models.** Boom makes about **$0.75 per download** ($6K / 8K), "Bass Booster – Volume boost" about **$0.50**, and b Buds+ about **$2.00**. b Buds+ is almost certainly running a hard, high-priced weekly paywall. UE BOOM (60K downloads) and Boomplay (90K) are **distribution-driven**: installs follow speaker sales and Transsion/telco pre-installs and bundles. They are not ASO plays and are not useful comparables for Bass Shake.
4. **On the Mac, you cannot buy search intent.** Apple Ads campaigns still require an iPhone/iPad app, and developers on Apple's forums report that Mac App Store apps are not supported. Growth therefore has to be earned through community launches (r/macapps, Show HN, Product Hunt), the press, comparison/SEO pages, Homebrew, Setapp and Apple editorial.
5. **"No driver" is quickly becoming table stakes.** The Core Audio process-tap API (macOS 14.2/14.4+) lets newcomers ship without a driver: FineTune, EQK (PH launch July 2026), EQBase (August 2026), CoreEQ, SOUND and AudiosteerEQ. Bass Shake should lead with **feel and focus** (bass-first, 6 smart bands, beautiful meters, zero setup), with "no driver" as supporting proof rather than the headline.

---

## 1. Origin stories and launch tactics

### 1.1 Global Delight: Boom (2011) → Boom 2 (2014) → Boom 3D (2017) → Boom iOS (2016)

| Year | Event | Tactic | Source |
|---|---|---|---|
| Jan 2011 | Boom ("one-click volume booster") debuts at **Macworld Expo**; wins **Best of Show** | Trade-show launch and an award to use as press hook | MacTech 2011; Macworld [verified-secondary] |
| Jun 2011 | Lands on the **Mac App Store**. GD says it had been "inundated with requests" | Waitlist-style demand story in the press release | GD press release 2011 [verified] |
| 2011–2012 | **Sponsorships** on TidBITS and Macdrifter; **TechCrunch** "Boom makes your Mac speakers go up to 11" (Aug 2012) | Paid reach into Apple-enthusiast readers plus earned tech press | tidbits.com, macdrifter.com, techcrunch.com [verified] |
| Dec 2014 | **Boom 2** ($14.99, 2-Mac license, 50% upgrade discount, student/edu discount). Rebuilt for Yosemite and Dark Mode; auto-calibrates EQ per Mac model. Launched on the web store first, MAS "in coming weeks" | **Paid-upgrade reset**: MAS doesn't allow paid upgrades, so a "new app" re-triggers press and "new app" featuring | MacTech 2014, GD press 2014, TidBITS [verified] |
| 2014 | One store listing cites "**App Store Best of 2014**" and Macworld Editor's Choice | Apple editorial recognition | listing summary via search [unverified; single source] |
| May 2016 | **Boom for iOS** announced (3D surround, presets incl. bass booster, intensity slider); TechCrunch covers it | Cross-platform brand extension; press | GD press 2016; TechCrunch 2016-05-25 [verified] |
| Aug 2016 | Apple **features Boom iOS on the India App Store** with a **60% discount** | Pairing a regional feature with a promo (India is still a top-3 country in the screenshot) | GD press 2016 [verified] |
| Jun 2017 | **Boom 3D** at **$16.99** on the web store and MAS; "3D Surround" becomes the headline feature | A second version reset and a new hero feature | GD press 2017; MacTech; AppleWorld.Today [verified] |
| 2017–2026 | **MacStories sponsorship** for Boom 3D; Black Friday **up to 75% off**; distribution via **MAS + Setapp + Steam**; **StackSocial** (Windows, $16.99 vs $49.99 list) and **Bundlehunt** (Boom 2 in "pick 10 of 30") | Discount and bundle flywheel; multi-store presence | macstories.net/sponsored; GD blog; stacksocial.com; bundlehunt.com; 9to5Mac/9to5Toys [verified] |
| ~2021 | 10th-anniversary page: **20M+ downloads, 12M+ users, 20K+ reviews** | Social proof (self-reported) | globaldelight.com [self-reported] |

**What made it work.** Boom arrived first ("first-of-its-kind" system-wide volume booster for Mac) and solved a visceral problem (MacBook speakers are too quiet). From there Global Delight stacked press, paid sponsorships and editorial hooks, and **used version resets to relaunch**. I found **no evidence of MacHeist participation**. The bundle channel I could confirm was Bundlehunt/StackSocial.

**Where Boom is vulnerable today.** The iOS app's 3.9★ from only 4.5K ratings over ten years, and ~8K monthly downloads, point to an aging franchise [estimate]. Users on Apple's developer forums report Boom 3D's virtual driver both *fixing* and *causing* audio issues: volume keys muting on macOS 14.7.1 and incompatibility with Audirvana [secondary, anecdotal]. That is exactly the gap Bass Shake's "no driver, no glitch" message targets.

### 1.2 The anonymous "Bass Booster" iOS apps

- **Who they are.** These are mostly small studios or solo sellers with interchangeable names. Search turns up "Bass Booster: Volume Boost EQ" (seller MD UZZAL MIA), "Bass Booster – Audio Equalizer" (Pretty View LLC), "Volume Booster Bass Boost" (NOTARIA LATINA CORP) and others. I could not tie the screenshot's "Bass Booster – Volume boost & Eq…" to a specific seller [unverified].
- **Monetization.** One example is a **3-day free trial → $2.99/week, $9.99/month or $49.99/year** (Pretty View LLC listing). Others offer weekly plus yearly only and do not allow mid-period cancellation [secondary, AppFollow mirrors].
- **Growth engine** [estimate, based on category norms and listing patterns]:
  1. **Keyword-stuffed titles and subtitles**: "Bass Booster", "Volume Boost", "Equalizer", "EQ", "Speaker", "Headphone", "Sound Amplifier". These map to high-volume, low-brand-loyalty searches.
  2. **Apple Ads (iOS only)** on generic terms such as "bass booster" and "equalizer". These terms are cheap relative to how well a weekly-sub paywall monetizes them.
  3. **Onboarding paywall** shown before the core feature. Adapty 2026 reports that onboarding paywalls with trials convert at 1.35% versus 0.89% for in-app paywalls, and that ~90% of trial starts happen on Day 0.
  4. **Aggressive review prompts** timed after a "wow" moment (for example, the first bass boost). Apple caps the prompt at 3 per 365 days, but the prompts still build rating volume. This likely explains "Bass Booster – Speaker Booster" at 4.5★ and "Bass Booster – Volume boost" at 4.6★ (4.9K), compared with Boom's 3.9★ [estimate].
  5. **Clone-and-relist**: several near-identical listings with fresh IDs (many IDs above 64xxxxxxxx, i.e. 2024–2026) spread across keyword clusters.

### 1.3 UE | BOOM by Ultimate Ears (hardware companion)

Installs follow **speaker sales**. The app offers PartyUp (up to 150 speakers), EQ, remote power-on and preset playlists. Its 4.8★ from 51K ratings reflects owners who are happy with their hardware, not app discovery. It probably makes **$0 in revenue**, and it ranks for "BOOM" only because of keyword overlap with "Boom" [estimate]. **Lesson for Bass Shake:** this listing competes for the keyword "boom", but its users are not your users. Do not bid on or target "boom" in iOS-style ASO. On the Mac this matters less.

### 1.4 Boomplay (telco and OEM distribution)

Boomplay launched in 2015 as a Transsion–NetEase JV. It comes **pre-installed on TECNO/Transsion phones**, and Transsion held ~48% of the African smartphone market in 2021. It also runs **telco data-bundle deals**:
- MTN Nigeria: ₦99/day with 250MB, up to ₦999/month with 2.5GB.
- MTN Ghana, AirtelTigo and Airtel Nigeria (2021): 500MB for ₦100 via *141#.
- 9mobile.

Reported user counts run from 31M (2018) to 75M (2020), all company-reported [secondary]. Its 90K iOS downloads are a sideshow to Android. **Not a comparable**; it shows up in the tracker only because of the "Boom" keyword.

### 1.5 Mac utilities in the same orbit

| App | Origin and growth lever | Business model | Key fact |
|---|---|---|---|
| **SoundSource** (Rogue Amoeba) | Started as a cheap ($10, free for RA customers) add-on, then became a flagship. v4 (2019) at $29 added per-app routing; v5 (2020) was the "lone paid upgrade" of that year. Usage surged in 2020 (WFH audio) | One-time with paid upgrades; list price climbed to $39 and then ~$49 | Rogue Amoeba's status reports and anniversary sales (20% off) act as recurring press moments [verified] |
| **eqMac** | Began in 2017 by hacking Apple's CAPlayThrough sample plus Soundflower. Open-source on GitHub (Apache-2.0), ~5.7–6.4K stars. PH launch of eqMac2 on 2018-09-15. Later moved new development to a **private fork** | Free tier + **Pro** (monthly/yearly subscription or lifetime) | Open source as a funnel, then closed core for monetization [verified] |
| **FineTune** (Ronit Singh) | GPLv3 menu-bar per-app volume/EQ, positioned as the "free SoundSource". Built because BackgroundMusic crashed on recent macOS. Install path: `brew install --cask finetune` ("recommended"). The README asks users to "Star this repo" | Free | ~4.3K stars (AlternativeTo snapshot) → 7.8K (+1.0K in 30 days, gittrend) → ~9.7K per the brief. German press (ifun.de) and Lifehacker coverage [verified README; stars secondary] |
| **Bartender** (Surtees Studios) | Solo developer, ~2012. Became the default "hide menu-bar icons" app. Sold quietly to Applause in 2024 and the signing-certificate change triggered a trust backlash | One-time with paid major versions | The backlash fed growth for free alternatives such as **Ice** (open-source), covered by appgefahren/ifun.de [verified] |
| **Rectangle** (Ryan Hanson) | Swift rewrite of the abandoned **Spectacle**: "nearly a drop-in replacement". Free and open source, with paid **Rectangle Pro** upsell | Open-core | Riding an abandoned incumbent's user base is a proven playbook [verified] |
| **Raycast** | YC W20, **Launch HN** 2020-03-02. DAU grew from 130 (Oct 2020) to 11K+ in ~12 months. Extensions API/Store PH launch 2021-11-30: **528 upvotes, #1 of the day**. Side project ray.so drew **2.4K+ PH upvotes** | VC-backed freemium | Community extensions (100+ in a month) and viral side projects [secondary] |

**The pattern behind breakout Mac utilities:**
- (a) **Inherit a frustrated user base**: Spectacle → Rectangle, Bartender sale → Ice, BackgroundMusic crashes → FineTune. For Bass Shake, that is Boom driver pain.
- (b) **Free or open entry point.**
- (c) **One killer surface** in the menu bar.
- (d) Paid upgrades or Pro tier later.

---

## 2. ASO playbook for the bass/EQ category

### 2.1 What the screenshot's competitors do (pattern analysis)

- **Titles are keyword strings**: "Bass Booster – Volume boost & Eq…", "Equalizer Fx: Bass Booster, Speaker Sound, H…", "Bass Booster – Speaker Booster S…". Boom itself renamed to **"Boom: Bass Booster & Equalizer"**: the brand goes first and then two head keywords. That is the right template for a brand that wants to own a name.
- **Screenshot style**: neon/purple-to-pink gradients, giant EQ curves, callouts like "16-band EQ", "3D Surround", "Volume Boost 200%" and device mockups with headphones. These signal "power" at thumbnail size. Vendor ASO guides agree the **first three screenshots** decide most installs. StoreMaven, as cited by vendors, says ~70% of visitors never read the description [secondary].
- **Ratings**: the anonymous apps keep 4.4–4.6★ through timed prompts, while Boom sits at 3.9★. Prompt placement matters more than prompt count (Apple caps it at 3/yr) [verified for the cap].

### 2.2 Recommended Mac App Store / product page setup for Bass Shake

| Element | Recommendation |
|---|---|
| **Name (30 chars)** | `Bass Shake: Bass Booster & EQ` (29 chars). The brand comes first and the two head terms follow, mirroring Boom's rename |
| **Subtitle (30)** | `System-Wide Equalizer, No Driver` or `Volume Boost for Mac Speakers` |
| **Keyword field (100)** | `equalizer,volume,booster,boost,sound,audio,speaker,headphone,surround,louder,amplifier,eq,menu bar` (don't repeat title words) |
| **Screenshot 1** | The promise: "Deeper bass on any Mac. In one click." Show the menu-bar popover with live meters |
| **Screenshot 2** | The proof: 6 smart bands plus meters reacting to music |
| **Screenshot 3** | The reason to believe: "No driver. No kernel extension. No glitches." with a macOS 14.4+ badge |
| **Screenshots 4–6** | Presets (Movies, Podcasts, Lo-fi, EDM), per-output memory (AirPods vs speakers), Shortcuts/hotkeys |
| **Visual style** | Stay inside the category's gradient/neon vocabulary so users recognize it at thumbnail size, but use **real UI and real meters** rather than fake 16-band art, to stand apart from clones |
| **Localization** | EN, **DE, Hindi/EN-IN**, JA, FR, ES, PT-BR. DE and IN are already top Boom markets. Localize screenshots, not just keywords; Phiture/AppFollow say screenshot localization can lift conversion as much as text. Distimo's old figure is +128% downloads per localized country [secondary/dated] |
| **Ratings** | Prompt after the 3rd session in which the user kept bass on for more than 10 minutes, never on first launch. Use a pre-prompt "Enjoying Bass Shake?" with a feedback route for "no", but no rating gating (guideline 1.1.7) |
| **In-app events / CPPs** | I could not confirm that in-app events or custom product pages run on the Mac App Store [unverified]. Check App Store Connect. If available, run events such as "Holiday Movie Mode" and "WWDC week" |
| **Apple Ads** | **Not available for Mac App Store apps** per developer reports (Apple's help text requires an iPhone/iPad app) [secondary]. If Bass Shake ever ships an iOS companion, the bid-on-competitor-keywords tactic becomes available |

### 2.3 Reading the revenue/download ratios

| App | Rev/mo | DL/mo | $/DL | Interpretation [estimate] |
|---|---|---|---|---|
| Boom (iOS) | $6K | 8K | **$0.75** | 7-day trial plus subscription. A mature franchise living on renewals from a long tail of older cohorts |
| Bass Booster – Volume boost & Eq | $20K | 40K | **$0.50** | Weekly sub with a softer paywall or cheap price point. Volume-driven ASO and probably Apple Ads |
| b Buds+ | $20K | 10K | **$2.00** | **Hard paywall, high weekly price** ($4.99–$7.99/wk class) and probably paid UA. Adapty: high-tier weekly plans earn 5.2× more revenue per install than low-tier |
| UE BOOM / Boomplay | ~$0 / streaming | 60K / 90K | n/a | Hardware or OEM distribution |

Monthly revenue divided by monthly downloads mixes renewals from earlier cohorts, so treat these as relative monetization intensity, not as LTV. Tracker revenue and download figures are themselves modelled estimates.

**Implication.** The iOS bass category monetizes through weekly subscriptions sold to low-intent, impulse users. Mac buyers expect **one-time or modest pricing**:
- Boom 2: $14.99. Boom 3D: $16.99 list, often discounted to $9–12.
- SoundSource: $39–49. Re-Q: $35 one-time.
- EQK markets itself as "no subscription".

A weekly sub on macOS would collide with that norm and with r/macapps culture. **Recommended:** a free core (basic bass knob) plus **Bass Shake Pro at $14.99–$19.99 one-time** (launch price $9.99). Optionally add a $1.99/mo or $9.99/yr "Supporter" tier, and put the app on Setapp later.

---

## 3. Mac-specific growth channels (2024–2026)

### 3.1 Community launch platforms

**r/macapps** (~233K members per GummySearch [secondary])
- Solution requests and self-promotion are the most common post types.
- Current rules, from a Redlib mirror [secondary]:
  - **Tier 1 (main feed):** MAS developers (paid account with App Store distribution), *or* GitHub projects with **100+ stars**, *or* "Recognized Developer" flair. 10+ local karma also required.
  - **Tier 2 (main feed):** non-MAS developers who give a real identity and have a website with Privacy Policy and ToS.
  - **Tier 3:** the megathread for everyone else.
- **Action:** ship on the MAS, or have a public repo with 100+ stars, before posting. Build 10+ karma by answering "Boom alternative?" and "EQ for Mac?" threads first.

**Hacker News: Show HN**
- Front-page posts typically bring **~3K–5K visits in about a day**, with shallow engagement.
- Easy Data Transform: ~4,400 unique views, but only 192 reached the download page (~4%).
- Aidlab: ~500 HN uniques and ~6K page views.
- HN rewards a **technical story**, for example: "How I built a driverless system-wide EQ with Core Audio process taps". The technical write-up is the hook and the app is the payload. Add a founder comment right away (a moderator tip in the Easy Data Transform case) [secondary].

**Product Hunt**
- Indie Mac benchmarks [secondary, self-reported]:
  - CompressX: 592 upvotes, #2 of the day, **35 sales / ~$600**.
  - Chunk (menu-bar app): 10 upvotes on first try → **300 upvotes / #3** on a relaunch with demo video, and downloads ~doubled over the following weeks.
  - Paste Switch (2026): ~10 votes, essentially nothing.
  - Raycast Store: 528 upvotes, #1.
  - Direct EQ comparables: **EQK** launched 2026-07-15 and relaunched as EQK 3.0 on 2026-07-29, an example of the **repeat-launch tactic**. Mixio drew 0 upvotes (#101).
- B2C visitor→signup estimates are 3–16%, and ~60% of traffic arrives in the first 24h [secondary].
- **Reality check:** PH is a backlink, social-proof and press-discovery event, not a sales engine. Plan on ~1–3K visitors and roughly 50–300 installs for a top-5 finish [estimate].

**Indie Hackers / X / Bluesky / Threads build-in-public.** EQBase posted its 10-release journey on IH (first build August 5, 2026, now v1.4.5).

### 3.2 Distribution and directories

**Homebrew cask**
- FineTune lists `brew install --cask finetune` as its recommended install. That makes Homebrew both a trust signal and a discovery path, and a cask also feeds **MacUpdater/Latest**-style update trackers.
- **Notability bar** (current Acceptable Casks policy):
  - Third-party submission: 30 forks / 30 watchers / 75 stars.
  - **Self-submission: 90 forks / 90 watchers / 225 stars.**
  - The repo must be at least 30 days old.
- Plan the cask for after the public repo or companion repo reaches that bar, or get a fan to submit [verified].

**Setapp**
- Payouts are usage-based: about 70% of subscription revenue to developers, split by app launches weighted by list price. Developers who refer users get an extra 20% of those users' fees [secondary; check current terms].
- Requirements: **no in-app purchases, ads or trial builds inside the Setapp build**, and the app must be notarized; submissions go to a review team.
- Boom 3D is already on Setapp. It's a good **month 3+ channel** for recurring "long tail" income and for appearing in Setapp's editorial roundups.

**MacUpdate, AlternativeTo, Softpedia, SourceForge mirrors**
- AlternativeTo is especially valuable: users search "Boom 3D alternatives" and "SoundSource alternatives", and FineTune, Ice and SOUND all surface there.
- List Bass Shake as an alternative to **Boom 3D, Boom 2, eqMac, SoundSource and FineTune** on day 1 of the public beta.

**Comparison SEO pages**: "Boom 3D alternative", "eqMac alternative", "best equalizer for Mac 2026", "MacBook speakers too quiet". 2026 "Bartender alternatives" listicles (DrBuho, nexasphere) show that these listicles get written; pitch their authors.

### 3.3 Press and newsletters

- **9to5Mac "Indie App Spotlight"**: a weekly series. Pitch with "indie" in the subject line plus screenshots and a summary; tips@9to5mac.com is the historical route [secondary].
- **MacStories**: Boom 3D bought a MacStories weekly sponsorship. Earned coverage favours polished, native apps, so pitch Federico/John with a TestFlight build and a technical angle.
- **TidBITS, Six Colors, MacRumors, AppleInsider, Cult of Mac**: Boom's own coverage history shows these outlets cover audio utilities.
- **German press (ifun.de, appgefahren.de, Sir Apfelot, Mac & i)**: they covered FineTune, Ice and Boom 3D, and **DE is a top-3 market for Boom**.
- **Indian tech media**: India is Boom's #2 market. Global Delight is Indian (Pune) and got an India App Store feature.
- **Newsletters**: Indie Watch accepts submissions and covers macOS; Create with Swift runs an "indie app of the week". I could not confirm submission routes for "Indie Dev Monday" or MacStories Club [unverified].

### 3.4 Creators (TikTok, YouTube, Shorts)

I found **no documented case study** of a specific creator video driving a measured sales spike for a Mac menu-bar utility [unverified gap]. The "Mac apps you need" genre clearly exists (many roundups and listicles), and audio is unusually **demo-friendly**: a before/after bass clip on MacBook speakers is a 10-second hook. Suggested tactic: seed **20–40 small and mid-size creators** (10K–300K subs) with free Pro licenses and an affiliate code, rather than paying for one big integration.

### 3.5 Apple editorial

- Use the **"Promote your app"** form, or Featuring Nominations in App Store Connect.
- Submit **3+ weeks ahead** (some guides say 6–8 weeks), and resubmit for every major update.
- Editors favour adoption of **new Apple features**. For Bass Shake that means:
  - native SwiftUI menu-bar UI
  - App Intents/Shortcuts and Control Center or menu-bar controls
  - accessibility
  - Liquid Glass/macOS 26 design language
  - process taps (a modern API story)

  [secondary]
- Boom's history (an India feature with a discount, a possible "Best of 2014") shows Apple has featured this category before.

---

## 4. Concrete numbers cheat-sheet

| Metric | Number | Source quality |
|---|---|---|
| Show HN front page → visits | ~3–5K in ~24h; ~4% reach download page | secondary (successfulsoftware.net, IH) |
| PH top-3 → visitors | ~1–3K; ~60% on day 1 | secondary (causo.ai guide, founder posts) |
| PH #2 Mac utility → revenue | 592 upvotes → 35 sales, ~$600 (CompressX) | self-reported |
| PH visitor → signup (B2C) | 3–16% (varies wildly) | secondary |
| Mac trial download → purchase | ~5% (Curio, 15-day trial, 2006); 1.1% (Stand, pay-what-you-want) | dated / anecdotal |
| Hard paywall download → paid (iOS) | ~10.7–12.1% vs ~2.1–2.2% freemium | RevenueCat/Adapty via secondary |
| iOS trial → paid | 25.6% global median (Adapty 2026); 8–12% "good", 15–25% "great" (indie benchmark) | secondary |
| Weekly share of sub revenue | 55.5% all apps; **73.6% Utilities** | Adapty 2026 via Airbridge |
| Median weekly price (all categories) | ~$7.48/wk; $12.99/mo; $38.42/yr | Adapty 2026 |
| Utilities first-renewal retention | 58.1% (highest category) | Adapty 2026 |
| Typical bass-booster iOS pricing | $2.99/wk, $9.99/mo, $49.99/yr after 3-day trial | listing |
| Mac EQ/audio one-time prices | Boom 2 $14.99; Boom 3D $16.99 (sales $9–12); SoundSource $39–49; Re-Q $35; Audio Hijack $64 | verified-secondary |
| Direct-sale fees | Paddle ~5% (+VAT handling) vs MAS 15% (small-business program) | secondary (Gigazine/dev blog) |
| Setapp | ~70% to devs (usage-weighted) + 20% referral share | secondary/dated |
| Homebrew cask self-submit bar | 225 stars / 90 forks / 90 watchers; repo ≥30 days | verified (docs.brew.sh) |
| r/macapps main-feed bar | MAS dev, or 100+ GitHub stars, or flair; 10+ karma | secondary (mirror) |
| FineTune stars | ~4.3K → 7.8K (+1K/30d) → ~9.7K (brief) | secondary |
| Raycast early DAU | 130 → 11K in ~12 months | secondary |
| Localization lift | +128% downloads per localized country (Distimo, old); 25–40% global lift from ~6 languages | dated / unverified |

---

## 5. Positioning vs Boom

**Core message:** *"Bass you can feel. Setup you won't notice."*

| Boom 3D pain (from reviews/forums) | Bass Shake answer |
|---|---|
| Installs a virtual audio driver; volume-key, Bluetooth and DAW/Audirvana conflicts | **No driver, no kext.** Uses Apple's Core Audio process taps (macOS 14.4+). Uninstalling is just deleting the app |
| Audio glitches and crackle reports | **Glitch-free promise** backed by a public latency/CPU number on the site |
| Bloated feature set (3D surround, radio, player, apps) | **6 smart bands** tuned for bass, plus one hero knob. Opinionated, not overwhelming |
| Dated UI | **Beautiful live meters** in the menu bar; feels native to macOS 26 |
| Paid upgrade cycles; frequent "75% off" trains users to wait for a sale | Fair one-time Pro price, **free updates through v2** |

**Competitive caution.** EQK, EQBase, FineTune, CoreEQ, SOUND and AudiosteerEQ all already claim driverless or modern-API processing. "No driver" sets you apart from **Boom and eqMac**, but not from the 2026 newcomers. Against those, compete on **bass-specific tuning, design and meters, zero-config auto-calibration per Mac model** (something Boom 2 did in 2014 that newcomers lack), and the **Mac App Store's trust and one-click install**.

One open question: at least one tap-based app (Swara) says it relies on a **private permission API and can't ship on the MAS**. Before betting on a MAS launch, confirm that Bass Shake's tap and permission flow passes App Review [unverified risk; see research file 03].

---

## 6. Recommended 90-day go-to-market plan

Assume T0 = start of the private beta. The public launch is on **Day 75 (a Tuesday)**, which leaves room for a Product Hunt relaunch on Day ~90.

### Phase 0: Pre-work (before Day 0, ~1–2 weeks)

- **Landing page** at bassshake.app with a 15-second before/after audio demo (MacBook speakers), an email waitlist, Privacy Policy and ToS. The policies are required for r/macapps Tier 2 and look professional to press.
- **Press kit**: icon, 6 screenshots, 30s video, founder bio, a technical one-pager ("how process taps let us skip the driver").
- Set up **analytics** (privacy-friendly: TelemetryDeck/Plausible), **Sparkle** for direct builds, and **Paddle/Lemon Squeezy** for licenses.
- **Decide open-core vs closed** (precedents: Rectangle, eqMac). A small **open-source companion** (for example a `ProcessTapKit` Swift package or an AutoEQ preset repo) can collect GitHub stars and qualify for the r/macapps 100-star tier and, later, a Homebrew cask, without opening the app itself.

### Phase 1: Private beta (Days 0–30) → goal: 300–500 beta users and a polished product

| Week | Actions |
|---|---|
| 1 | Invite waitlist and friends. Seed a **Discord or GitHub Discussions** community. Post build-in-public threads on X/Bluesky/Threads/Mastodon ("Day 1 of building a Boom alternative with no driver") |
| 1–2 | Answer existing "Boom alternative" / "EQ for Mac" / "MacBook speakers quiet" threads on r/macapps and r/MacOS **as a helpful human**, disclosing that you're the developer, to build karma. Avoid link spam |
| 2 | Post on Indie Hackers (EQBase precedent). Publish the technical blog post on process taps, which doubles as the future Show HN asset |
| 3 | **Mac TestFlight** (if going MAS) plus a direct DMG. Collect testimonials and a "measured 0 dropouts in 40h" stat |
| 4 | **Submit the Apple "Promote your app" / Featuring Nomination**, targeting launch Day 75 (≥6 weeks ahead) |

### Phase 2: Public beta (Days 31–60) → goal: 3–5K installs, 100+ GitHub stars on the companion repo, first reviews

| Week | Actions |
|---|---|
| 5 | **Show HN**: "Show HN: Bass Shake – driverless system-wide bass/EQ for macOS (process taps)". Tue–Thu, ~8–10am ET; add a founder comment at once. Expect ~3–5K visits |
| 5 | List on **AlternativeTo** (as an alternative to Boom 3D, Boom 2, eqMac, SoundSource, FineTune), MacUpdate, Softpedia, SaaSHub |
| 6 | **r/macapps** main-feed post once you meet a tier: "I built a free bass booster for Mac without a virtual driver – feedback wanted" |
| 6–7 | Press pitches: **9to5Mac Indie App Spotlight**, MacStories, TidBITS, Six Colors, MacRumors, **ifun.de/appgefahren/Sir Apfelot (DE)**, Indian tech sites (Beebom, 91mobiles, Digit). Personal emails with a beta build plus a Pro license |
| 7–8 | **Creator seeding**: 20–40 Mac/desk-setup/music-producer creators with free Pro and an affiliate link. Ask for a 10-second before/after on MacBook speakers |
| 8 | Publish SEO pages: "Boom 3D alternative", "eqMac alternative", "Best equalizer for Mac 2026", "How to make MacBook speakers louder" |

### Phase 3: Launch (Days 61–90) → goal: 10K+ installs, 500+ paid, 4.7★ on 100+ ratings

| Day | Actions |
|---|---|
| 61–74 | Localize the MAS page (DE, EN-IN/HI, JA, FR, ES, PT-BR). Finalize ASO (title/subtitle/keywords above). Turn on the review prompt (3rd successful session). Prepare a launch discount (Pro $9.99 for 7 days) |
| **75 (Tue)** | **v1.0 on the Mac App Store + direct**, with **Product Hunt launch the same day** (demo video, maker comment, ask the beta community to visit but not to "upvote"). Email the waitlist. Send an embargoed press note at 9am ET |
| 76–80 | Second wave: r/macapps launch post (if the rules allow a second post), Mastodon/Bluesky Apple community, Hacker News comments on any related threads (no reposting), German and Indian press follow-ups |
| 80–85 | **Apply to Setapp** (a build without IAP). Submit the **Homebrew cask** once the repo meets the bar or a fan submits. Ask satisfied users for App Store ratings via an in-app "What's new" note |
| 85–90 | **v1.1 "Smart Bass Presets"**. Use it for a PH "launch again" (the EQK pattern), a new Apple featuring nomination and a newsletter update. Consider a **MacStories or 9to5Mac sponsorship** (Boom 3D's channel) if conversion data justifies it |

### Channel priority (expected impact per hour, my judgment)

1. **r/macapps and Reddit help-first answers**: highest-intent Mac audience, and the place where "Boom alternative" demand already lives.
2. **Show HN with the technical write-up**: a burst of credibility, backlinks and GitHub stars.
3. **Press: 9to5Mac Indie Spotlight, German sites, MacStories**: durable SEO and trust.
4. **AlternativeTo and comparison SEO**: a compounding long tail.
5. **Product Hunt**: mostly social proof; relaunch on each major version.
6. **Apple editorial**: low probability, huge upside; submit every major version.
7. **Setapp and Homebrew**: steady, low-effort tail channels.
8. **Creators**: high variance, so seed many small ones.
9. **Paid ads**: not available for MAS apps. Skip unless an iOS companion exists.

### KPIs to watch

- Landing → download ≥10%
- Download → activation (bass toggled on within 1 min) ≥70%
- Day-7 retention ≥40%
- Free → Pro ≥4–6% (Mac one-time benchmark, 2006 Curio ~5% [dated])
- Refund rate <3%
- MAS rating ≥4.6★
- Crash-free sessions ≥99.8%

---

## Sources

- Global Delight, Boom 10th anniversary: https://www.globaldelight.com/boom/10th-anniversary/
- MacTech, "Macworld: Boom is new volume booster app for the Mac" (2011): https://www.mactech.com/2011/01/27/macworld-boom-is-new-volume-booster-app-for-the-mac
- Global Delight press, Boom on Mac App Store (2011): https://globaldelight.com/press/2011/Boom-Mac-App-Store.html
- TechCrunch, "Boom Makes Your Mac Speakers Go Up To 11" (2012): https://techcrunch.com/2012/08/13/mac-app-boom-makes-your-speakers-go-up-to-11
- Macdrifter, Boom sponsor (2012): https://www.macdrifter.com/2012/08/boom-sponsor.html
- TidBITS, Global Delight sponsoring: https://tidbits.com/?p=12530 ; Boom 2: https://tidbits.com/?p=15278
- MacTech, Boom 2 for OS X ready for Yosemite (2014): https://www.mactech.com/2014/12/03/boom-2-for-os-x-ready-for-yosemite/
- Global Delight press, Boom 2 (2014): https://globaldelight.com/press/2014/global-delight-releases-boom-2.html
- Global Delight press, Boom 3D (2017): https://www.globaldelight.com/press-pages/2017/globaldelight-releases-boom3d.php
- MacTech, Boom 3D release (2017): https://www.mactech.com/2017/06/07/global-delight-releases-boom-3d-a-surround-sound-audio-app-for-the-mac/amp/
- Global Delight press, Introducing Boom for iOS (2016): https://globaldelight.com/press-pages/2016/introducing-boom-for-ios
- Global Delight press, Boom iOS 60% off / India feature (2016): https://globaldelight.com/press-pages/2016/boom-the-audio-enhancing-app-for-iOS-now-at-60-off
- TechCrunch, Boom iOS (2016): https://techcrunch.com/2016/05/25/boom-makes-your-music-sound-boomin-andor-slammin/
- MacStories, Boom 3D sponsor: https://www.macstories.net/sponsored/boom-3d-enjoy-immersive-audio-on-your-mac-sponsor/
- Global Delight blog, Black Friday up to 75% off: https://blog.globaldelight.com/press-release/its-raining-discounts-with-global-delights-black-friday-deals
- StackSocial, Boom 3D: https://stacksocial.com/sales/boom-3d-for-mac
- Bundlehunt, Boom 3D: https://bundlehunt.com/deal/boom-3d-for-macos
- 9to5Mac/9to5Toys Bundlehunt (Boom 2): https://9to5mac.com/?p=408468
- Apple Magazine, Boom 3D review: https://applemagazine.com/software-review-boom-3d-for-macos-and-windows/
- Hongkiat, Boom3D review: https://www.hongkiat.com/blog/boom3d-mac-review/
- App Store, Boom: Bass Booster & Equalizer: https://apps.apple.com/app/id1065511007
- AppFollow, Bass Booster – Audio Equalizer listing: https://apps.appfollow.io/ios/bass-booster-audio-equalizer/1471431235?country=at
- AppFollow, Bass Booster EQ + Volume Boost: https://apps.appfollow.io/ios/bass-booster-eq-volume-boost/1484073254?country=ph
- App Store, Bass Booster: Volume Boost EQ: https://apps.apple.com/app/id6782662292
- Quartz, Boomplay/Universal deal: https://qz.com/africa/1452045/transsions-boomplay-inks-universal-music-deal-in-africa
- TechPoint Africa, Boomplay market: https://techpoint.africa/insight/boomplay-african-music-streaming-market/
- Music in Africa, Boomplay × MTN Nigeria: https://www.musicinafrica.net/node/212584
- TechCabal, Boomplay × Airtel Nigeria (2021): https://techcabal.com/2021/07/13/boomplay-announces-partnership-with-airtel-nigeria-to-offer-affordable-music-streaming-service
- APKMirror, UE BOOM: https://apkmirror.com/apk/logitech-europe-s-a/ue-boom
- FineTune README (raw): https://raw.githubusercontent.com/ronitsingh10/FineTune/main/README.md
- gittrend, FineTune: https://gittrend.io/repo/ronitsingh10/FineTune
- AlternativeTo, FineTune: https://alternativeto.net/software/finetune-1/about
- ifun.de, FineTune: https://www.ifun.de/finetune-erweitert-macos-um-umfassende-funktionen-zur-audiosteuerung-272961/
- JustGeek, FineTune: https://www.justgeek.fr/?p=145992
- eqMac Pro help: https://eqmac.app/help/pro/what-is-eqmac-pro
- awesome.ecosyste.ms, eqMac: https://awesome.ecosyste.ms/projects/github.com%2Fbitgapp%2FeqMac
- hunted.space, eqMac2 PH launch: https://www.hunted.space/product/eqmac/launches/eqmac2
- Rogue Amoeba 2021 status report: https://weblog.rogueamoeba.com/2021/01/19/rogue-amoebas-2021-status-report/
- Rogue Amoeba 20th anniversary: https://weblog.rogueamoeba.com/2022/09/18/celebrate-rogue-amoebas-20th-anniversary/
- Macworld, SoundSource 4 review: https://www.macworld.com/article/3407902/soundsource-4-review-the-mac-audio-control-app-apple-should-have-made.html
- Six Colors, Bartender new owner: https://sixcolors.com/link/2024/06/bartender-has-a-new-owner/
- appgefahren, Ice as Bartender alternative: https://www.appgefahren.de/ice-bartender-alternative-organisiert-eure-menueleiste-am-mac-359502.html
- nexasphere, Bartender alternatives 2026: https://nexasphere.io/blog/bartender-alternative-mac-2026
- Rectangle: https://rectangleapp.com/ ; https://github.com/rxhanson/Rectangle
- Raycast Series A (BusinessCloud): https://businesscloud.co.uk/news/developer-tool-raycast-launches-alongside-11-3m-series-a/
- hunted.space, Raycast API & Store: https://www.hunted.space/product/raycast/launches/raycast-api-and-store
- ayewo Substack, Raycast vs Slapdash Launch HN: https://ayewo.substack.com/p/cmd-r-versus-cmd-s-a-tale-of-two-startups
- Product Hunt, EQK: https://www.producthunt.com/products/eqk-eq-with-ai ; EQK 3.0: https://www.producthunt.com/p/eqk-eq-with-ai/eqk-3-0
- Indie Hackers, EQBase: https://www.indiehackers.com/product/eqbase
- Product Hunt, SOUND: https://www.producthunt.com/products/sound
- hunted.space, Mixio 2: https://hunted.space/product/mixio-2
- HackerNoon, failed → top-3 PH (Chunk): https://hackernoon.com/lite/i-turned-a-failed-product-hunt-launch-into-a-top-3-win-on-a-budget
- CompressX launch report: https://hieudinh.notion.site/CompressX-s-launch-report-learnings-765d14fed55c47bebd2501e36f6d4793
- dev.to, Paste Switch PH: https://dev.to/ahab_indieseek/why-my-product-hunt-launch-failed-10-votes-1-download-and-lessons-from-launching-paste-switch-31bc
- causo.ai, PH traffic data 2026: https://hub.causo.ai/guides/product-hunt-traffic-data-2026
- causo.ai, Show HN playbook 2026: https://hub.causo.ai/guides/show-hn-launch-playbook-technical-founders-2026
- successfulsoftware.net, HN effect: https://successfulsoftware.net/2019/10/07/the-hacker-news-effect-wide-but-not-deep/
- Indie Hackers, HN front page postmortem: https://www.indiehackers.com/post/front-page-of-hn-the-full-postmortem-traffic-lessons-surprises-cbe9e0a7f6
- r/macapps rules mirror (Redlib): https://redlib.groet-infra.nl/r/macapps
- GummySearch, r/macapps: https://gummysearch.com/r/macapps
- Homebrew Acceptable Casks: https://docs.brew.sh/Acceptable-Casks ; Package Acceptance Policy: https://docs.brew.sh/Package-Acceptance-Policy
- Setapp review guidelines: https://docs.setapp.com/docs/review-guidelines ; requirements: https://docs.setapp.com/docs/preparing-your-application-for-setapp
- Six Colors, Setapp model (2016): https://sixcolors.com/post/2016/12/setapp-a-subscription-take-on-the-mac-app-store/
- AlternativeTo news, Setapp iOS store 70/30 + 20%: https://alternativeto.net/news/2023/8/setapp-plans-independent-ios-app-store-for-eu-users-awaiting-digital-markets-act-approval/
- Apple Developer Forums, Apple Search Ads for macOS apps: https://developer.apple.com/forums/thread/806737 ; https://developer.apple.com/forums/thread/693552
- 9to5Mac, more App Store search ads (2026): https://9to5mac.com/2026/01/22/app-store-search-ads-more-ads-march/
- Apple HIG, Ratings and reviews: https://developer-mdn.apple.com/design/human-interface-guidelines/patterns/ratings-and-reviews
- Appbot, review prompting guide: https://appbot.co/blog/prompting-for-app-reviews-ratings-ios-android-ultimate-guide/
- AppFollow, How to get featured (2024): https://appfollow.io/blog/how-to-get-your-app-featured-on-the-app-store-in-2024-a-short-guide
- AppTweak, getting featured: https://www.apptweak.com/en/aso-blog/how-to-get-your-app-featured-on-the-app-store
- AppTweak, screenshot best practices: https://www.apptweak.com/en/aso-blog/how-to-optimize-your-app-screenshots
- Sonar, screenshot captions: https://trysonar.app/blog/app-store-screenshot-captions
- Foxdata, localization impact: https://foxdata.com/en/marketing-academy/an-in-depth-analysis-of-app-localization-/
- appsops.store, localization roundup: https://appsops.store/blog/aso-research-roundup
- Adapty, State of In-App Subscriptions 2026: https://adapty.io/state-of-in-app-subscriptions/
- Adapty, High-performing paywall 2026: https://adapty.io/blog/high-performing-paywall-2026/
- Airbridge, weekly vs annual (Adapty utilities 73.6%): https://www.airbridge.io/en/blog/weekly-vs-annual-subscription-app
- RevenueCat, State of Subscription Apps 2025: https://revenuecat.com/state-of-subscription-apps-2025
- RevenueCat, free trial length: https://www.revenuecat.com/blog/growth/free-trial-length
- SaaStr on RevenueCat trial data: https://saastr.com/what-17000-subscription-apps-tell-us-about-free-trial-length-annual-plans-convert-86-better-with-30-day-trials-monthly-tops-out-at-two-weeks-and-ai-apps-hit-a-wall-at-16-days
- autoappnotes Substack, buyout vs subscription 2026: https://autoappnotes.substack.com/p/ios-buyout-vs-subscription-a-4-app
- Zengobi, Curio conversion rates (2006): https://blog.zengobi.com/2006/06/conversion-rates.html
- Medium, Stand app stats: https://medium.com/@reddavis/stand-app-9ee0fc3355c
- Gigazine, macOS app sales fees (Paddle vs MAS): https://gigazine.net/gsc_news/en/20231226-macos-app-cost
- Michael Tsai, Selling outside the Mac App Store (2024): https://mjtsai.com/blog/2024/12/09/selling-outside-of-the-mac-app-store
- stealwhatworks, Mac apps making money: https://stealwhatworks.com/blogs/news/mac-apps-making-real-money-now
- 9to5Mac Indie App Spotlight example: https://9to5mac.com/2025/09/06/indie-app-spotlight-minutetick-menu-bar-productivity-app-for-mac/
- Indie Watch newsletter: https://blog.digitalbunker.dev/announcing-indie-watch-a-newsletter-for-indie-ios-devs/
- Recall.ai, Core Audio taps: https://www.recall.ai/blog/core-audio-taps
- AudioCap (process tap reference): https://gitblind.noratr.app/jwang0512/AudioCap
- Swara (tap-based mixer, private permission API note): https://gitblind.noratr.app/troazz/swara
- Apple Developer Forums, crackling/popping thread (Boom 3D driver anecdotes): https://developer.apple.com/forums/thread/132423?page=16
- SourceForge, Boom 3D reviews: https://sourceforge.net/projects/boom-3d-windows/
- Audirvana community, Boom 3D not working: https://community.audirvana.com/t/boom-3d-not-working/33135
