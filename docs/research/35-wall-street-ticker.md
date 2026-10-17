# Wall Street: from tape to briefing

Investigation: 16 October 2026. Four agents examined source payloads, native
interaction, app integration and validation. Research and weighing ran from
09:53:55 to after 10:04 UTC before implementation began. Adam clarified the
purpose as technology, business and stock markets: a Wall Street mod within
his audio app.

## Decision

Keep the compact terminal tape and its rolling figures. Give it a still,
readable Market Briefing using the app's existing in-place panel pattern.
The tape establishes atmosphere and offers a glance; the briefing makes the
information usable without waiting for it to come around.

Keep small signed percentages and directional arrows colored at rest. Hover
slows the strips to a reading pace and colors only that quote's symbol and price in the same
direction. This reinforces a meaning already present. Unknown or cached
quotes stay neutral. No price flashes, expanding rows, glow or network
requests on hover. Movement means the stated comparison period, never a
prediction or a recommendation.

Adam's references are useful because their visual expression has a reference
frame: AQI has a numbered scale; tide has time; activity has a target. The
market equivalent is an instrument, unit, comparison, source time and genuine
history. Their lesson is more than saturated color. Preserve the app's tight
rhythm, SF type, native controls, theme palette and 20/26-point tape rows.

## What the investigation found

- Missing movement was converted to `0%`; absence and no change were indistinguishable.
- A partially successful batch made omitted, old symbols look freshly updated.
- AAPL's checked v8 payload showed a full-day move of +0.02%, while its regular
  session was −0.28%. The existing parser mixed an extended-hours comparison
  into a supposedly daily move.
- Quote time, fetched time, currency and instrument type were discarded.
  Gold and WTI are futures; index values are points, despite a USD metadata field.
- The news filter removed cuts, layoffs, fraud, lawsuits and other consequential
  business developments. A real BBC Business job-cuts story was excluded.
- Near-duplicate filtering at 60% shared words could hide distinct follow-up stories.
- The entire strip was hidden from accessibility. Reduce Motion and Power Saver
  left only the leading items visible, with no route to the rest.
- An experiment measuring native text widths at the existing speed found ten
  sampled Techmeme items alone contributed about 564 seconds to a complete
  tape circuit. It cannot be the only reading surface for a briefly opened app.

## Sources and data contract

Yahoo's richer **v7 spark batch** was tested with all 13 existing Yahoo symbols:
one roughly 35 KB response includes regular-session quote metadata and actual
five-minute samples. It is a better use of the current source, not a promise
that Yahoo has become a supported market-data API.

Use regular-market percentage change when supplied; otherwise derive it from
regular price and previous close. Never substitute `fullday*` fields. Preserve
the provider's quote timestamp separately from retrieval time. Use source
dates and exchange zones, not a hand-written weekday trading calendar.
Closed-market prices can legitimately be from the prior session. Missing
values remain unknown; missing symbols retain explicitly cached last values.
HTTP errors and malformed responses cannot count as successful updates.

The tested batch response had a 300-second cache lifetime. A five-minute Yahoo
cadence matches this; crypto remains at one minute, news at fifteen minutes.
Requests remain visible-only, with shared throttles and no new credentials.
Charts use the returned time/value pairs, preserve missing-value gaps, and
never fabricate points or smooth a series into a more exciting shape.

CoinGecko's documented `include_last_updated_at` field supplies crypto quote
time. Its movement is explicitly **24 hours**, unlike the Yahoo comparison
against previous close. See [simple price](https://docs.coingecko.com/demo/reference/simple-price)
and [rate limits](https://docs.coingecko.com/docs/errors-and-rate-limits).

Retain Techmeme's editorial selection and BBC Technology; replace broad BBC
Top Stories with BBC Business. Keep publication time, original publisher
when provided, and the source link. Preserve business news with negative
implications and explanatory analysis. Deduplicate exact normalized titles
and exact URLs rather than guessing that similar stories are identical.
Retain last results per feed when another feed succeeds.
See [Techmeme's editorial process](https://www.techmeme.com/about) and
[BBC Business RSS](https://feeds.bbci.co.uk/news/business/rss.xml).

## Why not switch providers now?

The checked alternatives introduce setup or tradeoffs without being a clear
drop-in improvement for this personal mod:

- [Alpha Vantage](https://www.alphavantage.co/support/) lists 25 requests/day
  on its ordinary free tier; timely US data has paid entitlements.
- [Twelve Data](https://twelvedata.com/pricing) lists 8 credits/minute and
  800/day for Basic; quote credits are per symbol. Its
  [default US coverage](https://support.twelvedata.com/en/articles/9935903-us-equities-market-data)
  and [display rights](https://support.twelvedata.com/en/articles/5332349-commercial-and-personal-usage)
  need an explicit product decision, not an interchangeable URL.
- [Alpaca](https://docs.alpaca.markets/us/docs/about-market-data-api) requires
  authentication and provides an IEX-only free equity feed; it does not replace
  the current indices, FX and futures breadth.
- [SEC filings](https://www.sec.gov/search-filings/edgar-application-programming-interfaces)
  are authoritative but need interpretation. Adding filing identifiers to this
  tape would increase noise before addressing the basic reading problem.

Yahoo remains an undocumented, best-effort dependency. Broader distribution
would need a deliberate licensed data strategy; see
[Yahoo's redistribution policy](https://help.yahoo.com/kb/SLN2352.html).
No provider account, subscription or deployment was created for this work.

## Interaction and scope

The permanent list control opens the briefing, and a quote opens it preselected.
The briefing uses the existing popup window with Back navigation; it avoids
nested popovers and the non-key drawer's keyboard limitations. Full headlines
and every enabled quote are reachable without animation. The chart is
secondary to price, comparison, date and source. Empty and failed states say
what is unavailable.

Preserve the settings toggle, category defaults, theme ownership, layout
ordering and audio behavior. The first expansion is a trustworthy briefing,
not a portfolio, trading surface, sentiment score or generated explanation
of why a stock moved. A user-chosen watchlist could be worthwhile later if
the fixed technology-heavy universe proves limiting.

Apple references informing the interaction:
[color](https://developer.apple.com/design/human-interface-guidelines/color),
[accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[charts](https://developer.apple.com/design/human-interface-guidelines/charts),
[popovers](https://developer.apple.com/design/human-interface-guidelines/popovers).

## Verification

Use `mac/scripts/market-data-check.sh` for production parser and cache
regressions without network or app startup. Verify the actual native tape and
briefing with an isolated render harness, then build the app. Normal startup
is unsuitable for screenshots: it can terminate the installed build, load
real preferences and bootstrap audio.

The 37 parser/cache checks passed, including regular-session comparisons,
missing and rounded-flat movement, chart gaps, partial failures, source dates,
publisher attribution and distinct follow-up headlines. The isolated native
harness verified the briefing control and its accessibility label, selected
quote routing, and suppression during holds, drags and rearranging. Native
renders of the actual tape and briefing were inspected for fit and legibility.
The complete release build passed. These are local changes; the installed app
and its audio session were not restarted, and no beta was published.

## Initial hover motion refinement

A further five-minute pass reviewed stop/start timing, interruption, wrapping,
click accuracy and reduced motion. This first version eased to rest over 160 ms and
resumed over 240 ms. At full speed the quote row coasted 1.92 points, and the
headline row 1.2 points. The motion stays monotonic, with no spring or overshoot.
Rapid pointer changes continue from the current position and speed. Clicking
freezes the target immediately; hidden views, Power Saver and Reduce Motion
also stop immediately. One check after settling refreshes the hovered symbol.
Core Animation handles the frames and the scheduled return to steady scrolling;
no per-frame timer or SwiftUI updates were added. The approach follows Apple's
[animation timing guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/AdvancedAnimationTricks/AdvancedAnimationTricks.html).

Validation passed: 35 focused motion checks, 10 actual native presentation
samples, the existing click/hold/drag/rearrange checks, and a complete release
build. Native sampling confirmed that the delayed cruise does not override
the resume ramp, including a nonzero loop phase and a stop across the seam.
The isolated test window closed and its process exited normally.

## Recording-led motion refinement

The October 17 recording showed the older installed beta, but the initial local
160 ms coast also had too little visible travel to feel soft. A further ten-minute
motion pass changed the stop to 560 ms and the restart to 700 ms. Velocity follows
smoothstep, with zero acceleration at each stable endpoint; its integral gives
the position curve. At normal speed, quotes coast 6.72 points and news 4.2 points.
This remains a finite, monotonic landing without bounce or a long drifting tail.

Both rows now settle together anywhere inside the panel, including its divider
and briefing button. A 100 ms exit grace absorbs accidental edge crossings.
Rapid re-entry preserves the current position and speed; the final hover target
is refreshed even when the pointer briefly leaves during the coast. Direct clicks,
hidden panels and reduced motion still stop immediately. Core Animation receives
the complete sampled curve once and handles playback without per-frame Swift work.

Validation stayed focused on feel: a nine-second native capture of the actual
panel showed the coast, hold and restart, and the release build passed. A signed
local review bundle is staged at `build/review-20261017/The Bass Shaker.app`
(local build 175.1). The installed beta and its running audio session were not
replaced. The review bundle also includes the artwork effects and automatic
black/transparent border trimming from this session.

## Hover at a slow roll

Adam's follow-up replaces the full hover stop with 20% of each row's normal
speed: quotes at 4.8 points/second and headlines at 3. Both ease down over
750 ms and return over 700 ms, preserving position and velocity on interruption.
The 100 ms exit grace remains. Mouse-down no longer brakes the tape; the pressed
item is latched so movement and incoming data cannot redirect the click.

A stationary pointer refreshes its highlight, tooltip and cursor after the ramp,
then at the next item edge or gap. These sparse callbacks use the actual band
position; Core Animation still draws every frame. Layout and data changes
reschedule the callback. Hidden panels, Power Saver and Reduce Motion remain
fully stationary, with all items available in Market Briefing.

Validation: the release build and 19 isolated native checks passed, covering
interrupted easing, relayout continuity, stationary-pointer edges and gaps,
loop wrapping, latched clicks across refresh, and stopping when hidden or still.
The actual presentation layer advanced 2.89 points in 600 ms at hover pace.
The fixture closed without starting the full app or its audio session.
