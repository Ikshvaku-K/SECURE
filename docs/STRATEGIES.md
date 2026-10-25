# S.E.C.U.R.E: Strategy guide

The 27 strategies shown in the app's **Learn** tab, grouped by market. This file is generated from [`StrategyCatalog.swift`](../Packages/SecureKit/Sources/SecureConnect/StrategyCatalog.swift), so the text here and in the app are the same.

> **Disclaimer.** General education, not personal financial advice. Every market in this app is simulated and uses practice money. No strategy guarantees a profit, and past results don't predict future ones.

## Key concepts

| Concept | Meaning | Where it appears in the app |
|---|---|---|
| Implied probability | The chance a price stands for. A 40¢ contract implies 40 %; American odds of +150 imply 100 / 250 = 40 %; −200 implies 200 / 300 = 66.7 %. | Contract detail, bet slip ("Odds explained") |
| Bookmaker margin (overround) | The amount by which both sides' implied probabilities add up to more than 100 %. The simulated sportsbook prices about 4.5 %; removing it gives the "fair" probabilities. | Bet slip |
| Spread | The gap between buying and selling prices. Simulated stocks trade 0.05 % either side of the mid price; prediction contracts are quoted 1¢ either side, so YES ask + NO ask = 102¢. | Stock and contract detail |
| Expected value (EV) | Probability-weighted gain minus probability-weighted loss. For a contract: p × 100¢ − price. For a bet: p × profit − (1 − p) × stake. | Contract EV slider, Expected value calculator |
| Kelly fraction | The bankroll share that maximises long-run growth for a known edge: f* = (b·p − q) / b with b = decimal odds − 1. Many use half or quarter Kelly because p is never known exactly. | Kelly calculator |
| Variance | How far real results swing around the expected value. A positive-EV plan can lose for a long time. | Martingale simulator, DCA backtest |

## Contents

**Foundations (every market)**

| Strategy | Complexity | In this app |
|---|---|---|
| [Expected value and edge](#expected-value) | Beginner | Calculator in the app |
| [Fixed-fraction position sizing](#position-sizing) | Beginner | Try it in practice mode |
| [Diversification](#diversification) | Beginner | Try it in practice mode |
| [Loss limits and cool-offs](#loss-limits) | Beginner | Try it in practice mode |
| [Keep records and review](#record-keeping) | Beginner | Try it in practice mode |

**Stocks & ETFs**

| Strategy | Complexity | In this app |
|---|---|---|
| [Buy and hold (index investing)](#buy-and-hold) | Beginner | Try it in practice mode |
| [Dollar-cost averaging (DCA)](#dollar-cost-averaging) | Beginner | Calculator in the app |
| [Asset allocation and rebalancing](#allocation-rebalancing) | Beginner | Try it in practice mode |
| [Value investing](#value-investing) | Intermediate | Explained only |
| [Growth investing](#growth-investing) | Intermediate | Try it in practice mode |
| [Dividend (income) investing](#dividend-investing) | Beginner | Explained only |
| [Momentum (trend following)](#momentum) | Intermediate | Try it in practice mode |
| [Mean reversion](#mean-reversion) | Intermediate | Try it in practice mode |
| [Stop-loss and exit rules](#stop-loss) | Beginner | Try it in practice mode |
| [Options overlays (covered calls, protective puts)](#options-overlays) | Advanced | Explained only |

**Prediction markets**

| Strategy | Complexity | In this app |
|---|---|---|
| [Probability edge (value trading)](#probability-edge) | Beginner | Try it in practice mode |
| [Event-driven (news) trading](#event-driven) | Intermediate | Try it in practice mode |
| [Market making (providing liquidity)](#market-making) | Advanced | Explained only |
| [Hedging a real-world risk](#hedging-real-risk) | Beginner | Try it in practice mode |
| [Arbitrage across prices](#price-arbitrage) | Intermediate | Explained only |
| [Fading longshots (favourite–longshot bias)](#longshot-bias) | Intermediate | Try it in practice mode |

**Sports betting**

| Strategy | Complexity | In this app |
|---|---|---|
| [Value betting](#value-betting) | Intermediate | Try it in practice mode |
| [Flat staking](#flat-staking) | Beginner | Try it in practice mode |
| [Kelly criterion (and fractional Kelly)](#kelly) | Advanced | Calculator in the app |
| [Hedging and cash-out](#hedging-cashout) | Intermediate | Try it in practice mode |
| [Martingale and other progressions (warning)](#martingale) | Beginner | Calculator in the app |
| [Line shopping](#line-shopping) | Beginner | Explained only |

## Foundations (every market)

<a id="expected-value"></a>
### Expected value and edge

*Only take a bet or trade when its expected value is positive after costs.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Any | Calculator in the app |

**How it works.** Expected value (EV) is the average result if you could repeat a decision many times: probability-weighted gains minus probability-weighted losses. Prices imply probabilities — a 40¢ contract implies 40 %, odds of +150 imply 40 %. You have an edge only if your estimate beats the price, and still beats it after spreads, fees and the bookmaker's margin.

**Example.** You think an event has a 50 % chance and YES costs 40¢: EV = 0.50 × 100¢ − 40¢ = +10¢ per contract. If the true chance is 35 %, the same trade has EV −5¢.

**When it's used.** It is the test behind every other strategy here.

**Risks**

- Your probability estimate is the weak point; overconfidence turns a perceived edge into a loss.
- Positive-EV decisions can still lose for long stretches (variance).
- Costs such as spreads, fees and margins are easy to underestimate.

**In practice mode.** Learn ▸ Expected value calculator; every prediction contract also shows the edge for your own probability.

<a id="position-sizing"></a>
### Fixed-fraction position sizing

*Risk the same small percentage of your bankroll on each position.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Any | Try it in practice mode |

**How it works.** Pick a fraction — often 1–2 % — and size every bet or trade so that losing it entirely costs that fraction of your current bankroll. Stakes shrink after losses and grow after wins, which makes losing everything very unlikely.

**Example.** With $10,000 and a 2 % rule, the most you risk is $200. After a drawdown to $9,000, the next maximum is $180.

**When it's used.** Almost universal among professional traders and bettors as the first line of risk control.

**Risks**

- It controls risk but doesn't create an edge; it sizes losing strategies too.
- Several positions on the same outcome add up to more risk than intended.
- Small fractions grow a bankroll slowly.

**In practice mode.** Apply it by hand; your credit tier's order cap and your daily stake limit act as hard ceilings.

<a id="diversification"></a>
### Diversification

*Spread money across many positions whose outcomes don't move together.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Long term | Try it in practice mode |

**How it works.** Combining assets or bets that aren't strongly correlated reduces the swings of the whole portfolio without necessarily reducing its expected return. An index fund applies this automatically across hundreds of companies.

**Example.** One company can fall 50 % on bad news; a fund holding 500 companies rarely moves that much in a day, because company-specific news averages out.

**When it's used.** The core of long-term investing; it also limits the damage from any single wrong bet.

**Risks**

- Correlations rise in crises, so many assets fall together.
- It doesn't protect against market-wide declines.
- Spreading into things you don't understand adds cost, not safety.

**In practice mode.** Compare one stock's daily moves with the TMKT index ETF using Next day.

<a id="loss-limits"></a>
### Loss limits and cool-offs

*Decide the most you will stake or lose before you start, and stop when you reach it.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Any | Try it in practice mode |

**How it works.** Committing in advance protects against chasing losses and decisions made in the heat of the moment. Regulated gambling operators offer deposit limits, cool-off periods and self-exclusion for this reason. This app enforces a daily stake limit, 24-hour or 7-day cool-offs and self-exclusion.

**Example.** With a $250 daily stake limit, the app refuses a $100 bet after $200 has already been staked that day.

**When it's used.** Standard in responsible gambling; just as useful for active trading.

**Risks**

- It only works if it can't be overridden, which is why cool-offs and self-exclusions here can't be shortened.
- A limit set too high provides no protection.

**In practice mode.** Profile ▸ Responsible play.

<a id="record-keeping"></a>
### Keep records and review

*Log every position and your reasoning, then compare results with what you expected.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Any | Try it in practice mode |

**How it works.** Tracking win rate, average gain against average loss, and (for bettors) whether you got better odds than the final market price shows whether an edge is real or luck. Writing the reason down before the result is known prevents hindsight from rewriting it.

**Example.** After 100 bets at odds of −110 you need to win more than 52.4 % to profit; 54 wins is encouraging, but 100 bets is still a small sample.

**When it's used.** Anyone who wants to know whether their method works.

**Risks**

- Small samples mislead — luck dominates the first few hundred bets or trades.
- Selective memory: losses are easier to forget than wins.

**In practice mode.** Markets ▸ Portfolio keeps the full history of orders, bets and settlements.

## Stocks & ETFs

<a id="buy-and-hold"></a>
### Buy and hold (index investing)

*Buy a broad, low-cost index fund and hold it for years regardless of short-term moves.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Years | Try it in practice mode |

**How it works.** Instead of picking winners, you own the whole market through an index ETF and accept its average return. Rare trading keeps costs and taxes low. Returns come from long-run economic growth and company profits.

**Example.** Buy TMKT, the simulated total-market ETF, and use Next day to watch a diversified fund move less than single stocks.

**When it's used.** The default approach for long-term saving such as retirement accounts.

**Risks**

- Large drawdowns happen: broad US stocks fell more than 50 % from peak to trough in 2007–09, and recoveries can take years.
- It takes discipline not to sell in a panic.
- Average returns aren't guaranteed over any particular period.

**In practice mode.** Buy TMKT in Markets ▸ Stocks & ETFs.

<a id="dollar-cost-averaging"></a>
### Dollar-cost averaging (DCA)

*Invest a fixed amount at regular intervals instead of all at once.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Years | Calculator in the app |

**How it works.** Buying the same dollar amount each period automatically buys more shares when prices are low and fewer when they are high, so the average cost per share ends up below the average price. It removes the decision of when to invest.

**Example.** Investing $100 a month at prices of $10, $5 and $10 buys 10 + 20 + 10 = 40 shares for $300: an average cost of $7.50, while the average price was $8.33.

**When it's used.** Investing from each paycheck; also used to move a lump sum into the market gradually.

**Risks**

- In markets that mostly rise, investing a lump sum straight away has historically come out ahead more often than not, because the money is invested for longer.
- It doesn't prevent losses in a long decline.
- Many small purchases can add fees in real accounts.

**In practice mode.** Learn ▸ DCA backtest compares DCA with a lump sum on the simulated price history.

<a id="allocation-rebalancing"></a>
### Asset allocation and rebalancing

*Choose a target mix (for example 60 % stocks, 40 % bonds) and trade back to it periodically.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Years | Try it in practice mode |

**How it works.** The mix sets your overall risk. As markets move it drifts; rebalancing sells some of what rose and buys what fell, which keeps the risk level constant and enforces buying low and selling high mechanically. Some rebalance on a calendar, others when a weight drifts past a band such as ±5 percentage points.

**Example.** $10,000 at 60/40: stocks grow to $7,200 while bonds stay at $4,000 (64/36). Moving $480 from stocks to bonds restores 60/40 of $11,200.

**When it's used.** Most diversified long-term portfolios and target-date funds.

**Risks**

- Trading costs and, outside tax-advantaged accounts, taxes.
- Still exposed when stocks and bonds fall together, as in 2022.
- Buying the asset that just fell feels wrong, which tempts people to abandon the plan.

**In practice mode.** Hold TMKT (stocks) and AGGB (bonds) and rebalance after several Next day steps.

<a id="value-investing"></a>
### Value investing

*Buy companies that look cheap relative to their earnings, assets or cash flow.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Years | Explained only |

**How it works.** Value investors estimate what a business is worth and buy when the price is well below that estimate, leaving a margin of safety. Common screens are a low price-to-earnings (P/E) or price-to-book (P/B) ratio.

**Example.** A company earning $5 a share and trading at $40 has a P/E of 8. If similar companies trade at 15 times earnings, a value investor may see it as underpriced — and asks why the market is pessimistic.

**When it's used.** Patient, long-horizon investors; popularised by Benjamin Graham and Warren Buffett.

**Risks**

- Value traps: a stock is cheap because the business is in decline.
- Value styles can lag the market for many years.
- It requires real analysis of financial statements.

**In practice mode.** Simulated companies have no financial statements, so this is explained but can't be practised.

<a id="growth-investing"></a>
### Growth investing

*Buy companies expected to grow revenue and earnings much faster than average.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Years | Try it in practice mode |

**How it works.** Growth investors accept high valuations today in exchange for expected growth, typically in expanding industries such as technology or medical innovation.

**Example.** A company growing earnings 30 % a year may justify a P/E of 40 if that growth continues for several years.

**When it's used.** Investors with long horizons and a high tolerance for volatility.

**Risks**

- High valuations fall sharply when growth slows or interest rates rise.
- Expected growth is often already in the price.
- Portfolios tend to concentrate in one sector.

**In practice mode.** ORBT and QNTA are the higher-volatility simulated tech stocks.

<a id="dividend-investing"></a>
### Dividend (income) investing

*Hold companies that pay regular, growing dividends, for income.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Years | Explained only |

**How it works.** Mature, profitable companies return cash to shareholders as dividends. Investors look at the dividend yield (annual dividend ÷ price), the payout ratio and the history of increases.

**Example.** A $50 stock paying $2 a year yields 4 %; $10,000 invested would pay about $400 a year before taxes.

**When it's used.** Income-focused investors, often retirees.

**Risks**

- Dividends can be cut.
- Very high yields often signal trouble (yield traps).
- Concentration in a few sectors such as utilities and consumer staples.

**In practice mode.** The simulator doesn't pay dividends, so this is explained only.

<a id="momentum"></a>
### Momentum (trend following)

*Buy what has been rising; avoid or sell what has been falling.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Weeks to months | Try it in practice mode |

**How it works.** Prices that moved strongly over recent months have historically tended to keep moving the same way for a while. Trend followers use rules such as "hold while the price is above its 50-day average".

**Example.** If ORBT closes above its 50-day average, a trend rule holds it; when it closes below, the rule sells.

**When it's used.** Systematic traders and some funds, across many asset classes.

**Risks**

- Sharp reversals ("momentum crashes") can erase months of gains.
- Frequent trading raises costs, and sideways markets trigger repeated small losses.
- The simulated prices are a random walk, so momentum has no built-in edge in practice mode.

**In practice mode.** Use each stock's chart and Next day to follow a trend rule.

<a id="mean-reversion"></a>
### Mean reversion

*Bet that prices that moved unusually far will move back toward their average.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Days to weeks | Try it in practice mode |

**How it works.** Traders measure how far a price has strayed from a moving average — often in standard deviations — and buy unusually low readings or sell unusually high ones, expecting a snap-back.

**Example.** A stock that normally trades within 5 % of its 20-day average suddenly sits 12 % below it; a mean-reversion trader buys, expecting a partial rebound.

**When it's used.** Short-term traders, often in range-bound markets.

**Risks**

- Prices can keep moving away; a fall can be the start of a new trend ("catching a falling knife").
- It needs strict exit rules.
- The simulated prices are a random walk, so mean reversion has no built-in edge in practice mode.

**In practice mode.** Watch for large one-day moves on the charts.

<a id="stop-loss"></a>
### Stop-loss and exit rules

*Decide in advance the price at which you will sell to cap a loss.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Days to months | Try it in practice mode |

**How it works.** A stop-loss is a planned exit, usually a fixed percentage below the purchase price or below a recent low. Combined with position sizing, it fixes the maximum loss per trade before you enter.

**Example.** Buy at $100 with a stop at $92, risking $8 a share. With a $200 risk budget you would buy 25 shares.

**When it's used.** Active traders; less common among long-term index investors.

**Risks**

- Prices can gap below the stop, making the loss larger than planned.
- Normal volatility can trigger a stop just before a recovery.
- Practice mode has no automatic stop orders, so exits are manual.

**In practice mode.** Set your exit price and sell by hand.

<a id="options-overlays"></a>
### Options overlays (covered calls, protective puts)

*Use options on shares you own to earn income or buy protection.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Advanced | Weeks to months | Explained only |

**How it works.** A covered call sells someone the right to buy your shares at a set price, earning a premium but capping your upside. A protective put buys the right to sell your shares at a set price, limiting losses in exchange for the premium paid.

**Example.** Owning 100 shares at $50, you sell a $55 call for $1.50 a share: you keep $150, but give up any gains above $55 until it expires.

**When it's used.** Experienced investors managing income or downside risk.

**Risks**

- Covered calls cap gains in strong rallies.
- Puts cost money that is lost if prices don't fall.
- Options pricing, expiry and assignment are complex.

**In practice mode.** Practice mode doesn't include options.

## Prediction markets

<a id="probability-edge"></a>
### Probability edge (value trading)

*Buy YES when you think the true chance is above the price; buy NO when it is below.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Days to weeks | Try it in practice mode |

**How it works.** A contract that pays $1 if an event happens and costs 40¢ means the market puts the chance at 40 %. If your well-researched estimate is 55 %, YES has positive expected value; if it is 25 %, NO (about 60¢) does.

**Example.** YES at 40¢ with your estimate at 55 %: EV = 0.55 × 100 − 40 = +15¢ per contract. Ten contracts cost $4.00 and pay $10.00 if you're right.

**When it's used.** The core of prediction-market trading.

**Risks**

- Markets combine many people's information; beating them consistently is hard.
- Overconfidence in your own estimate.
- Spreads and fees reduce the edge — practice mode buys 1¢ above and sells 1¢ below the midpoint.

**In practice mode.** Each contract has a "your probability" slider that shows the edge before you buy.

<a id="event-driven"></a>
### Event-driven (news) trading

*Trade quickly when new information changes an event's likelihood, before the price adjusts.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Hours to days | Try it in practice mode |

**How it works.** Prices move as news arrives — a forecast update, an announcement, a poll. Traders who interpret news faster or better than the crowd buy before the price catches up.

**Example.** A rain contract trades at 30¢; a new forecast raises the chance to 60 %. Buying at 31¢ before others react captures the move.

**When it's used.** Active traders with fast access to information.

**Risks**

- Others usually react faster; by the time you trade, the news is often in the price.
- Misreading the news.
- Practice mode has no news feed: prices drift toward the outcome as the close approaches, with noise.

**In practice mode.** Watch prices drift day by day as each event approaches its close.

<a id="market-making"></a>
### Market making (providing liquidity)

*Post both a buy and a sell price and earn the spread between them.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Advanced | Minutes to days | Explained only |

**How it works.** A market maker offers to buy at 48¢ and sell at 52¢. If both sides fill, they earn 4¢ without predicting the outcome. Profit depends on volume and on not being left holding the losing side.

**Example.** Buying and selling 100 contracts each at 48¢ and 52¢ earns $4.00 if the inventory nets out.

**When it's used.** Professional firms and sophisticated traders on exchanges.

**Risks**

- Adverse selection: informed traders trade with you just before the price moves against you.
- Inventory risk when the event resolves.
- Practice mode fills against fixed simulated quotes, so market making can't be practised.

**In practice mode.** Explained only: practice orders fill against the simulator's quotes.

<a id="hedging-real-risk"></a>
### Hedging a real-world risk

*Buy contracts that pay out if something bad for you happens.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Until the event | Try it in practice mode |

**How it works.** If an event would cost you money, a contract on that event offsets the loss, much like insurance. On average you expect to lose the premium, but the bad outcomes shrink.

**Example.** An outdoor event loses $500 if it rains. Buying 500 rain contracts at 30¢ costs $150 and pays $500 if it rains.

**When it's used.** Businesses and individuals exposed to measurable events such as weather or interest rates.

**Risks**

- Basis risk: the contract's exact definition may not match your actual loss.
- It costs money every time the bad event doesn't happen.
- There may not be enough liquidity for a large hedge.

**In practice mode.** The weather contracts work as practice hedges.

<a id="price-arbitrage"></a>
### Arbitrage across prices

*Lock in a profit when related prices don't add up.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Instant | Explained only |

**How it works.** YES and NO on the same event should cost about $1 together. If YES is 45¢ and NO is 50¢ — 95¢ in total — buying both guarantees $1 back, a 5¢ profit before fees. Similar mismatches appear between related markets or different exchanges.

**Example.** Buy 100 YES at 45¢ and 100 NO at 50¢ for $95; one side pays $100 at resolution, a $5 profit.

**When it's used.** Professional traders with fast execution.

**Risks**

- True arbitrage is rare and disappears quickly.
- Fees and execution delays erase thin margins.
- Different settlement rules across venues can make "identical" contracts differ.
- In practice mode the YES and NO buy prices always total 102¢, so arbitrage never appears — a lesson in itself.

**In practice mode.** Check any practice contract: the two buy prices add up to more than $1.

<a id="longshot-bias"></a>
### Fading longshots (favourite–longshot bias)

*Avoid, or bet against, very unlikely outcomes, which tend to be overpriced.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Until the event | Try it in practice mode |

**How it works.** Studies of horse racing and other betting markets have long found that low-probability outcomes trade above their true chances — people overpay for lottery-like payoffs — while favourites are slightly underpriced. Betting against longshots (buying NO at 90¢ or more) collects small, frequent gains.

**Example.** YES trades at 8¢ on an event that truly happens 4 % of the time. NO costs about 93¢, gains 7¢ most of the time and loses 93¢ in the rare case it happens: an expected +3¢.

**When it's used.** Patient traders seeking steady returns.

**Risks**

- The rare losses are large and can wipe out many small wins.
- The bias is a tendency, not a law; it varies by market and over time.
- The simulator prices events fairly on average, so the bias isn't built into practice mode.

**In practice mode.** Look for contracts trading below 10¢.

## Sports betting

<a id="value-betting"></a>
### Value betting

*Bet only when your estimated chance of an outcome beats the probability implied by the odds.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Per game | Try it in practice mode |

**How it works.** Convert odds to implied probability: +150 means 40 %, −200 means 66.7 %. Bookmakers build in a margin, so the implied probabilities of all outcomes add up to more than 100 %. A value bet needs your estimate to beat the implied probability by more than that margin.

**Example.** Odds of +150 imply 40 %. If you rate the team at 46 %, a $10 bet has EV = 0.46 × $15 − 0.54 × $10 = +$1.50.

**When it's used.** The basis of any long-term profitable betting, where it exists at all.

**Risks**

- Bookmaker margins (4.5 % in practice mode) mean most bettors lose over time.
- Your ratings may be worse than the market's.
- Real bookmakers often limit accounts that win consistently.

**In practice mode.** The bet slip shows implied and margin-free probabilities next to the odds.

<a id="flat-staking"></a>
### Flat staking

*Bet the same amount on every selection.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Any | Try it in practice mode |

**How it works.** A fixed stake — often 1–2 % of the starting bankroll — makes results easy to track and stops emotion from inflating stakes after wins or losses.

**Example.** With a $1,000 bankroll and $20 stakes, a ten-bet losing streak costs $200 and leaves plenty to continue.

**When it's used.** Recreational and disciplined bettors alike.

**Risks**

- It ignores differences in edge between bets.
- It doesn't turn a losing approach into a winning one.
- A fixed stake becomes a larger share of a shrinking bankroll.

**In practice mode.** Use the same stake on every practice bet.

<a id="kelly"></a>
### Kelly criterion (and fractional Kelly)

*Size each bet as a fraction of bankroll proportional to your edge.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Advanced | Any | Calculator in the app |

**How it works.** The Kelly formula f* = (b·p − q) / b gives the bankroll fraction that maximises long-run growth, where b is the net odds (decimal odds − 1), p is your win probability and q = 1 − p. Because probability estimates are uncertain, many people bet half or a quarter of the Kelly amount.

**Example.** At even money (b = 1) with p = 55 %: f* = (0.55 − 0.45) ÷ 1 = 10 % of bankroll; half Kelly is 5 %.

**When it's used.** Professional bettors and some investors who can estimate probabilities well.

**Risks**

- Very sensitive to errors in p: overestimating your edge leads to overbetting and deep drawdowns.
- Full Kelly is extremely volatile.
- It recommends no bet when there is no edge, which is most of the time.

**In practice mode.** Learn ▸ Kelly calculator.

<a id="hedging-cashout"></a>
### Hedging and cash-out

*Bet the other side (or take a cash-out offer) to lock in a profit or limit a loss.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Intermediate | Per game | Try it in practice mode |

**How it works.** If the odds have moved in your favour, a stake on the opposite outcome can guarantee a smaller profit whatever happens. Bookmakers' cash-out offers do the same in one step.

**Example.** You hold $10 at +200, which returns $30. After the odds move, the other side is +150; staking $12 on it also returns $30. You have staked $22 and get $30 back either way: +$8 guaranteed.

**When it's used.** Bettors managing risk on bets whose odds have shifted.

**Risks**

- Each hedge pays the bookmaker's margin again, lowering expected value.
- Cash-out offers are usually priced below fair value.
- Practice mode has no live in-game odds, so hedges are placed before the game.

**In practice mode.** Bet both sides of a practice game before its day.

<a id="martingale"></a>
### Martingale and other progressions (warning)

*Doubling the stake after every loss to win it all back — popular, and mathematically doomed.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Any | Calculator in the app |

**How it works.** After a loss the next stake doubles, so one win recovers all previous losses plus the original stake. Variants such as Fibonacci or d'Alembert raise stakes more slowly. None of them changes the expected value of a single bet; they only turn many small wins into rare, catastrophic losses.

**Example.** Starting at $10, seven losses in a row cost $1,270 and require an eighth stake of $1,280. At fair even odds, seven straight losses happen about once in every 128 sequences — so they do happen.

**When it's used.** Explained because it is widely promoted, not because it works.

**Risks**

- Losses grow exponentially; a finite bankroll or a table limit guarantees eventual ruin.
- With a bookmaker margin, every bet still has negative expected value.
- It feels safe because it usually wins small amounts — until it doesn't.

**In practice mode.** Learn ▸ Martingale simulator shows how often the bankroll runs out.

<a id="line-shopping"></a>
### Line shopping

*Compare odds across bookmakers and always take the best price.*

| Complexity | Time horizon | In this app |
|---|---|---|
| Beginner | Per bet | Explained only |

**How it works.** Bookmakers post different odds for the same game. Getting +110 instead of −110 on the same bet lowers the win rate you need to break even from 52.4 % to 47.6 %.

**Example.** At −110 you must win 52.4 % of bets to break even; at +110, only 47.6 %.

**When it's used.** Serious bettors with accounts at several bookmakers.

**Risks**

- It needs several accounts and quick comparisons.
- The gain per bet is small; it doesn't create an edge by itself.
- Practice mode has a single simulated bookmaker, so this is explained only.

**In practice mode.** Explained only: practice mode has one bookmaker.

## Help

Every market in S.E.C.U.R.E is simulated and uses practice money. If betting with real money stops being fun, the National Council on Problem Gambling ([ncpgambling.org](https://www.ncpgambling.org)) offers free, confidential help.
