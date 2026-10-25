import Foundation

/// An educational description of a trading, investing or betting strategy. General information, not personal advice.
public struct Strategy: Sendable, Identifiable, Hashable {
    public enum Group: String, Sendable, CaseIterable {
        case foundations, stocks, prediction, sports

        public var title: String {
            switch self {
            case .foundations: "Foundations (every market)"
            case .stocks: "Stocks & ETFs"
            case .prediction: "Prediction markets"
            case .sports: "Sports betting"
            }
        }
    }

    public enum Complexity: String, Sendable, CaseIterable {
        case beginner, intermediate, advanced
        public var title: String { rawValue.capitalized }
    }

    public enum Availability: String, Sendable {
        /// Can be tried with practice money.
        case practice
        /// Has a calculator in the Learn tab.
        case calculator
        /// Explained only; the simulator can't model it.
        case educationOnly

        public var title: String {
            switch self {
            case .practice: "Try it in practice mode"
            case .calculator: "Calculator in the app"
            case .educationOnly: "Explained only"
            }
        }
    }

    public let id: String
    public let name: String
    public let group: Group
    public let summary: String
    public let howItWorks: String
    public let example: String
    public let whenUsed: String
    public let risks: [String]
    public let complexity: Complexity
    public let horizon: String
    public let availability: Availability
    public let practiceNote: String
}

public enum StrategyCatalog {
    public static let disclaimer = """
        General education, not personal financial advice. Every market in this app is simulated and uses practice money. \
        No strategy guarantees a profit, and past results don't predict future ones.
        """

    public static func strategies(in group: Strategy.Group) -> [Strategy] { all.filter { $0.group == group } }

    public static func find(_ id: String) -> Strategy? { all.first { $0.id == id } }

    public static let all: [Strategy] = foundations + stocks + prediction + sports

    // MARK: Foundations

    static let foundations: [Strategy] = [
        Strategy(
            id: "expected-value", name: "Expected value and edge", group: .foundations,
            summary: "Only take a bet or trade when its expected value is positive after costs.",
            howItWorks: "Expected value (EV) is the average result if you could repeat a decision many times: probability-weighted gains minus probability-weighted losses. Prices imply probabilities — a 40¢ contract implies 40 %, odds of +150 imply 40 %. You have an edge only if your estimate beats the price, and still beats it after spreads, fees and the bookmaker's margin.",
            example: "You think an event has a 50 % chance and YES costs 40¢: EV = 0.50 × 100¢ − 40¢ = +10¢ per contract. If the true chance is 35 %, the same trade has EV −5¢.",
            whenUsed: "It is the test behind every other strategy here.",
            risks: [
                "Your probability estimate is the weak point; overconfidence turns a perceived edge into a loss.",
                "Positive-EV decisions can still lose for long stretches (variance).",
                "Costs such as spreads, fees and margins are easy to underestimate.",
            ],
            complexity: .beginner, horizon: "Any", availability: .calculator,
            practiceNote: "Learn ▸ Expected value calculator; every prediction contract also shows the edge for your own probability."),
        Strategy(
            id: "position-sizing", name: "Fixed-fraction position sizing", group: .foundations,
            summary: "Risk the same small percentage of your bankroll on each position.",
            howItWorks: "Pick a fraction — often 1–2 % — and size every bet or trade so that losing it entirely costs that fraction of your current bankroll. Stakes shrink after losses and grow after wins, which makes losing everything very unlikely.",
            example: "With $10,000 and a 2 % rule, the most you risk is $200. After a drawdown to $9,000, the next maximum is $180.",
            whenUsed: "Almost universal among professional traders and bettors as the first line of risk control.",
            risks: [
                "It controls risk but doesn't create an edge; it sizes losing strategies too.",
                "Several positions on the same outcome add up to more risk than intended.",
                "Small fractions grow a bankroll slowly.",
            ],
            complexity: .beginner, horizon: "Any", availability: .practice,
            practiceNote: "Apply it by hand; your credit tier's order cap and your daily stake limit act as hard ceilings."),
        Strategy(
            id: "diversification", name: "Diversification", group: .foundations,
            summary: "Spread money across many positions whose outcomes don't move together.",
            howItWorks: "Combining assets or bets that aren't strongly correlated reduces the swings of the whole portfolio without necessarily reducing its expected return. An index fund applies this automatically across hundreds of companies.",
            example: "One company can fall 50 % on bad news; a fund holding 500 companies rarely moves that much in a day, because company-specific news averages out.",
            whenUsed: "The core of long-term investing; it also limits the damage from any single wrong bet.",
            risks: [
                "Correlations rise in crises, so many assets fall together.",
                "It doesn't protect against market-wide declines.",
                "Spreading into things you don't understand adds cost, not safety.",
            ],
            complexity: .beginner, horizon: "Long term", availability: .practice,
            practiceNote: "Compare one stock's daily moves with the TMKT index ETF using Next day."),
        Strategy(
            id: "loss-limits", name: "Loss limits and cool-offs", group: .foundations,
            summary: "Decide the most you will stake or lose before you start, and stop when you reach it.",
            howItWorks: "Committing in advance protects against chasing losses and decisions made in the heat of the moment. Regulated gambling operators offer deposit limits, cool-off periods and self-exclusion for this reason. This app enforces a daily stake limit, 24-hour or 7-day cool-offs and self-exclusion.",
            example: "With a $250 daily stake limit, the app refuses a $100 bet after $200 has already been staked that day.",
            whenUsed: "Standard in responsible gambling; just as useful for active trading.",
            risks: [
                "It only works if it can't be overridden, which is why cool-offs and self-exclusions here can't be shortened.",
                "A limit set too high provides no protection.",
            ],
            complexity: .beginner, horizon: "Any", availability: .practice,
            practiceNote: "Profile ▸ Responsible play."),
        Strategy(
            id: "record-keeping", name: "Keep records and review", group: .foundations,
            summary: "Log every position and your reasoning, then compare results with what you expected.",
            howItWorks: "Tracking win rate, average gain against average loss, and (for bettors) whether you got better odds than the final market price shows whether an edge is real or luck. Writing the reason down before the result is known prevents hindsight from rewriting it.",
            example: "After 100 bets at odds of −110 you need to win more than 52.4 % to profit; 54 wins is encouraging, but 100 bets is still a small sample.",
            whenUsed: "Anyone who wants to know whether their method works.",
            risks: [
                "Small samples mislead — luck dominates the first few hundred bets or trades.",
                "Selective memory: losses are easier to forget than wins.",
            ],
            complexity: .beginner, horizon: "Any", availability: .practice,
            practiceNote: "Markets ▸ Portfolio keeps the full history of orders, bets and settlements."),
    ]

    // MARK: Stocks & ETFs

    static let stocks: [Strategy] = [
        Strategy(
            id: "buy-and-hold", name: "Buy and hold (index investing)", group: .stocks,
            summary: "Buy a broad, low-cost index fund and hold it for years regardless of short-term moves.",
            howItWorks: "Instead of picking winners, you own the whole market through an index ETF and accept its average return. Rare trading keeps costs and taxes low. Returns come from long-run economic growth and company profits.",
            example: "Buy TMKT, the simulated total-market ETF, and use Next day to watch a diversified fund move less than single stocks.",
            whenUsed: "The default approach for long-term saving such as retirement accounts.",
            risks: [
                "Large drawdowns happen: broad US stocks fell more than 50 % from peak to trough in 2007–09, and recoveries can take years.",
                "It takes discipline not to sell in a panic.",
                "Average returns aren't guaranteed over any particular period.",
            ],
            complexity: .beginner, horizon: "Years", availability: .practice, practiceNote: "Buy TMKT in Markets ▸ Stocks & ETFs."),
        Strategy(
            id: "dollar-cost-averaging", name: "Dollar-cost averaging (DCA)", group: .stocks,
            summary: "Invest a fixed amount at regular intervals instead of all at once.",
            howItWorks: "Buying the same dollar amount each period automatically buys more shares when prices are low and fewer when they are high, so the average cost per share ends up below the average price. It removes the decision of when to invest.",
            example: "Investing $100 a month at prices of $10, $5 and $10 buys 10 + 20 + 10 = 40 shares for $300: an average cost of $7.50, while the average price was $8.33.",
            whenUsed: "Investing from each paycheck; also used to move a lump sum into the market gradually.",
            risks: [
                "In markets that mostly rise, investing a lump sum straight away has historically come out ahead more often than not, because the money is invested for longer.",
                "It doesn't prevent losses in a long decline.",
                "Many small purchases can add fees in real accounts.",
            ],
            complexity: .beginner, horizon: "Years", availability: .calculator,
            practiceNote: "Learn ▸ DCA backtest compares DCA with a lump sum on the simulated price history."),
        Strategy(
            id: "allocation-rebalancing", name: "Asset allocation and rebalancing", group: .stocks,
            summary: "Choose a target mix (for example 60 % stocks, 40 % bonds) and trade back to it periodically.",
            howItWorks: "The mix sets your overall risk. As markets move it drifts; rebalancing sells some of what rose and buys what fell, which keeps the risk level constant and enforces buying low and selling high mechanically. Some rebalance on a calendar, others when a weight drifts past a band such as ±5 percentage points.",
            example: "$10,000 at 60/40: stocks grow to $7,200 while bonds stay at $4,000 (64/36). Moving $480 from stocks to bonds restores 60/40 of $11,200.",
            whenUsed: "Most diversified long-term portfolios and target-date funds.",
            risks: [
                "Trading costs and, outside tax-advantaged accounts, taxes.",
                "Still exposed when stocks and bonds fall together, as in 2022.",
                "Buying the asset that just fell feels wrong, which tempts people to abandon the plan.",
            ],
            complexity: .beginner, horizon: "Years", availability: .practice,
            practiceNote: "Hold TMKT (stocks) and AGGB (bonds) and rebalance after several Next day steps."),
        Strategy(
            id: "value-investing", name: "Value investing", group: .stocks,
            summary: "Buy companies that look cheap relative to their earnings, assets or cash flow.",
            howItWorks: "Value investors estimate what a business is worth and buy when the price is well below that estimate, leaving a margin of safety. Common screens are a low price-to-earnings (P/E) or price-to-book (P/B) ratio.",
            example: "A company earning $5 a share and trading at $40 has a P/E of 8. If similar companies trade at 15 times earnings, a value investor may see it as underpriced — and asks why the market is pessimistic.",
            whenUsed: "Patient, long-horizon investors; popularised by Benjamin Graham and Warren Buffett.",
            risks: [
                "Value traps: a stock is cheap because the business is in decline.",
                "Value styles can lag the market for many years.",
                "It requires real analysis of financial statements.",
            ],
            complexity: .intermediate, horizon: "Years", availability: .educationOnly,
            practiceNote: "Simulated companies have no financial statements, so this is explained but can't be practised."),
        Strategy(
            id: "growth-investing", name: "Growth investing", group: .stocks,
            summary: "Buy companies expected to grow revenue and earnings much faster than average.",
            howItWorks: "Growth investors accept high valuations today in exchange for expected growth, typically in expanding industries such as technology or medical innovation.",
            example: "A company growing earnings 30 % a year may justify a P/E of 40 if that growth continues for several years.",
            whenUsed: "Investors with long horizons and a high tolerance for volatility.",
            risks: [
                "High valuations fall sharply when growth slows or interest rates rise.",
                "Expected growth is often already in the price.",
                "Portfolios tend to concentrate in one sector.",
            ],
            complexity: .intermediate, horizon: "Years", availability: .practice,
            practiceNote: "ORBT and QNTA are the higher-volatility simulated tech stocks."),
        Strategy(
            id: "dividend-investing", name: "Dividend (income) investing", group: .stocks,
            summary: "Hold companies that pay regular, growing dividends, for income.",
            howItWorks: "Mature, profitable companies return cash to shareholders as dividends. Investors look at the dividend yield (annual dividend ÷ price), the payout ratio and the history of increases.",
            example: "A $50 stock paying $2 a year yields 4 %; $10,000 invested would pay about $400 a year before taxes.",
            whenUsed: "Income-focused investors, often retirees.",
            risks: [
                "Dividends can be cut.",
                "Very high yields often signal trouble (yield traps).",
                "Concentration in a few sectors such as utilities and consumer staples.",
            ],
            complexity: .beginner, horizon: "Years", availability: .educationOnly,
            practiceNote: "The simulator doesn't pay dividends, so this is explained only."),
        Strategy(
            id: "momentum", name: "Momentum (trend following)", group: .stocks,
            summary: "Buy what has been rising; avoid or sell what has been falling.",
            howItWorks: "Prices that moved strongly over recent months have historically tended to keep moving the same way for a while. Trend followers use rules such as \"hold while the price is above its 50-day average\".",
            example: "If ORBT closes above its 50-day average, a trend rule holds it; when it closes below, the rule sells.",
            whenUsed: "Systematic traders and some funds, across many asset classes.",
            risks: [
                "Sharp reversals (\"momentum crashes\") can erase months of gains.",
                "Frequent trading raises costs, and sideways markets trigger repeated small losses.",
                "The simulated prices are a random walk, so momentum has no built-in edge in practice mode.",
            ],
            complexity: .intermediate, horizon: "Weeks to months", availability: .practice,
            practiceNote: "Use each stock's chart and Next day to follow a trend rule."),
        Strategy(
            id: "mean-reversion", name: "Mean reversion", group: .stocks,
            summary: "Bet that prices that moved unusually far will move back toward their average.",
            howItWorks: "Traders measure how far a price has strayed from a moving average — often in standard deviations — and buy unusually low readings or sell unusually high ones, expecting a snap-back.",
            example: "A stock that normally trades within 5 % of its 20-day average suddenly sits 12 % below it; a mean-reversion trader buys, expecting a partial rebound.",
            whenUsed: "Short-term traders, often in range-bound markets.",
            risks: [
                "Prices can keep moving away; a fall can be the start of a new trend (\"catching a falling knife\").",
                "It needs strict exit rules.",
                "The simulated prices are a random walk, so mean reversion has no built-in edge in practice mode.",
            ],
            complexity: .intermediate, horizon: "Days to weeks", availability: .practice,
            practiceNote: "Watch for large one-day moves on the charts."),
        Strategy(
            id: "stop-loss", name: "Stop-loss and exit rules", group: .stocks,
            summary: "Decide in advance the price at which you will sell to cap a loss.",
            howItWorks: "A stop-loss is a planned exit, usually a fixed percentage below the purchase price or below a recent low. Combined with position sizing, it fixes the maximum loss per trade before you enter.",
            example: "Buy at $100 with a stop at $92, risking $8 a share. With a $200 risk budget you would buy 25 shares.",
            whenUsed: "Active traders; less common among long-term index investors.",
            risks: [
                "Prices can gap below the stop, making the loss larger than planned.",
                "Normal volatility can trigger a stop just before a recovery.",
                "Practice mode has no automatic stop orders, so exits are manual.",
            ],
            complexity: .beginner, horizon: "Days to months", availability: .practice, practiceNote: "Set your exit price and sell by hand."),
        Strategy(
            id: "options-overlays", name: "Options overlays (covered calls, protective puts)", group: .stocks,
            summary: "Use options on shares you own to earn income or buy protection.",
            howItWorks: "A covered call sells someone the right to buy your shares at a set price, earning a premium but capping your upside. A protective put buys the right to sell your shares at a set price, limiting losses in exchange for the premium paid.",
            example: "Owning 100 shares at $50, you sell a $55 call for $1.50 a share: you keep $150, but give up any gains above $55 until it expires.",
            whenUsed: "Experienced investors managing income or downside risk.",
            risks: [
                "Covered calls cap gains in strong rallies.",
                "Puts cost money that is lost if prices don't fall.",
                "Options pricing, expiry and assignment are complex.",
            ],
            complexity: .advanced, horizon: "Weeks to months", availability: .educationOnly,
            practiceNote: "Practice mode doesn't include options."),
    ]

    // MARK: Prediction markets

    static let prediction: [Strategy] = [
        Strategy(
            id: "probability-edge", name: "Probability edge (value trading)", group: .prediction,
            summary: "Buy YES when you think the true chance is above the price; buy NO when it is below.",
            howItWorks: "A contract that pays $1 if an event happens and costs 40¢ means the market puts the chance at 40 %. If your well-researched estimate is 55 %, YES has positive expected value; if it is 25 %, NO (about 60¢) does.",
            example: "YES at 40¢ with your estimate at 55 %: EV = 0.55 × 100 − 40 = +15¢ per contract. Ten contracts cost $4.00 and pay $10.00 if you're right.",
            whenUsed: "The core of prediction-market trading.",
            risks: [
                "Markets combine many people's information; beating them consistently is hard.",
                "Overconfidence in your own estimate.",
                "Spreads and fees reduce the edge — practice mode buys 1¢ above and sells 1¢ below the midpoint.",
            ],
            complexity: .beginner, horizon: "Days to weeks", availability: .practice,
            practiceNote: "Each contract has a \"your probability\" slider that shows the edge before you buy."),
        Strategy(
            id: "event-driven", name: "Event-driven (news) trading", group: .prediction,
            summary: "Trade quickly when new information changes an event's likelihood, before the price adjusts.",
            howItWorks: "Prices move as news arrives — a forecast update, an announcement, a poll. Traders who interpret news faster or better than the crowd buy before the price catches up.",
            example: "A rain contract trades at 30¢; a new forecast raises the chance to 60 %. Buying at 31¢ before others react captures the move.",
            whenUsed: "Active traders with fast access to information.",
            risks: [
                "Others usually react faster; by the time you trade, the news is often in the price.",
                "Misreading the news.",
                "Practice mode has no news feed: prices drift toward the outcome as the close approaches, with noise.",
            ],
            complexity: .intermediate, horizon: "Hours to days", availability: .practice,
            practiceNote: "Watch prices drift day by day as each event approaches its close."),
        Strategy(
            id: "market-making", name: "Market making (providing liquidity)", group: .prediction,
            summary: "Post both a buy and a sell price and earn the spread between them.",
            howItWorks: "A market maker offers to buy at 48¢ and sell at 52¢. If both sides fill, they earn 4¢ without predicting the outcome. Profit depends on volume and on not being left holding the losing side.",
            example: "Buying and selling 100 contracts each at 48¢ and 52¢ earns $4.00 if the inventory nets out.",
            whenUsed: "Professional firms and sophisticated traders on exchanges.",
            risks: [
                "Adverse selection: informed traders trade with you just before the price moves against you.",
                "Inventory risk when the event resolves.",
                "Practice mode fills against fixed simulated quotes, so market making can't be practised.",
            ],
            complexity: .advanced, horizon: "Minutes to days", availability: .educationOnly,
            practiceNote: "Explained only: practice orders fill against the simulator's quotes."),
        Strategy(
            id: "hedging-real-risk", name: "Hedging a real-world risk", group: .prediction,
            summary: "Buy contracts that pay out if something bad for you happens.",
            howItWorks: "If an event would cost you money, a contract on that event offsets the loss, much like insurance. On average you expect to lose the premium, but the bad outcomes shrink.",
            example: "An outdoor event loses $500 if it rains. Buying 500 rain contracts at 30¢ costs $150 and pays $500 if it rains.",
            whenUsed: "Businesses and individuals exposed to measurable events such as weather or interest rates.",
            risks: [
                "Basis risk: the contract's exact definition may not match your actual loss.",
                "It costs money every time the bad event doesn't happen.",
                "There may not be enough liquidity for a large hedge.",
            ],
            complexity: .beginner, horizon: "Until the event", availability: .practice,
            practiceNote: "The weather contracts work as practice hedges."),
        Strategy(
            id: "price-arbitrage", name: "Arbitrage across prices", group: .prediction,
            summary: "Lock in a profit when related prices don't add up.",
            howItWorks: "YES and NO on the same event should cost about $1 together. If YES is 45¢ and NO is 50¢ — 95¢ in total — buying both guarantees $1 back, a 5¢ profit before fees. Similar mismatches appear between related markets or different exchanges.",
            example: "Buy 100 YES at 45¢ and 100 NO at 50¢ for $95; one side pays $100 at resolution, a $5 profit.",
            whenUsed: "Professional traders with fast execution.",
            risks: [
                "True arbitrage is rare and disappears quickly.",
                "Fees and execution delays erase thin margins.",
                "Different settlement rules across venues can make \"identical\" contracts differ.",
                "In practice mode the YES and NO buy prices always total 102¢, so arbitrage never appears — a lesson in itself.",
            ],
            complexity: .intermediate, horizon: "Instant", availability: .educationOnly,
            practiceNote: "Check any practice contract: the two buy prices add up to more than $1."),
        Strategy(
            id: "longshot-bias", name: "Fading longshots (favourite–longshot bias)", group: .prediction,
            summary: "Avoid, or bet against, very unlikely outcomes, which tend to be overpriced.",
            howItWorks: "Studies of horse racing and other betting markets have long found that low-probability outcomes trade above their true chances — people overpay for lottery-like payoffs — while favourites are slightly underpriced. Betting against longshots (buying NO at 90¢ or more) collects small, frequent gains.",
            example: "YES trades at 8¢ on an event that truly happens 4 % of the time. NO costs about 93¢, gains 7¢ most of the time and loses 93¢ in the rare case it happens: an expected +3¢.",
            whenUsed: "Patient traders seeking steady returns.",
            risks: [
                "The rare losses are large and can wipe out many small wins.",
                "The bias is a tendency, not a law; it varies by market and over time.",
                "The simulator prices events fairly on average, so the bias isn't built into practice mode.",
            ],
            complexity: .intermediate, horizon: "Until the event", availability: .practice,
            practiceNote: "Look for contracts trading below 10¢."),
    ]

    // MARK: Sports betting

    static let sports: [Strategy] = [
        Strategy(
            id: "value-betting", name: "Value betting", group: .sports,
            summary: "Bet only when your estimated chance of an outcome beats the probability implied by the odds.",
            howItWorks: "Convert odds to implied probability: +150 means 40 %, −200 means 66.7 %. Bookmakers build in a margin, so the implied probabilities of all outcomes add up to more than 100 %. A value bet needs your estimate to beat the implied probability by more than that margin.",
            example: "Odds of +150 imply 40 %. If you rate the team at 46 %, a $10 bet has EV = 0.46 × $15 − 0.54 × $10 = +$1.50.",
            whenUsed: "The basis of any long-term profitable betting, where it exists at all.",
            risks: [
                "Bookmaker margins (4.5 % in practice mode) mean most bettors lose over time.",
                "Your ratings may be worse than the market's.",
                "Real bookmakers often limit accounts that win consistently.",
            ],
            complexity: .intermediate, horizon: "Per game", availability: .practice,
            practiceNote: "The bet slip shows implied and margin-free probabilities next to the odds."),
        Strategy(
            id: "flat-staking", name: "Flat staking", group: .sports,
            summary: "Bet the same amount on every selection.",
            howItWorks: "A fixed stake — often 1–2 % of the starting bankroll — makes results easy to track and stops emotion from inflating stakes after wins or losses.",
            example: "With a $1,000 bankroll and $20 stakes, a ten-bet losing streak costs $200 and leaves plenty to continue.",
            whenUsed: "Recreational and disciplined bettors alike.",
            risks: [
                "It ignores differences in edge between bets.",
                "It doesn't turn a losing approach into a winning one.",
                "A fixed stake becomes a larger share of a shrinking bankroll.",
            ],
            complexity: .beginner, horizon: "Any", availability: .practice, practiceNote: "Use the same stake on every practice bet."),
        Strategy(
            id: "kelly", name: "Kelly criterion (and fractional Kelly)", group: .sports,
            summary: "Size each bet as a fraction of bankroll proportional to your edge.",
            howItWorks: "The Kelly formula f* = (b·p − q) / b gives the bankroll fraction that maximises long-run growth, where b is the net odds (decimal odds − 1), p is your win probability and q = 1 − p. Because probability estimates are uncertain, many people bet half or a quarter of the Kelly amount.",
            example: "At even money (b = 1) with p = 55 %: f* = (0.55 − 0.45) ÷ 1 = 10 % of bankroll; half Kelly is 5 %.",
            whenUsed: "Professional bettors and some investors who can estimate probabilities well.",
            risks: [
                "Very sensitive to errors in p: overestimating your edge leads to overbetting and deep drawdowns.",
                "Full Kelly is extremely volatile.",
                "It recommends no bet when there is no edge, which is most of the time.",
            ],
            complexity: .advanced, horizon: "Any", availability: .calculator, practiceNote: "Learn ▸ Kelly calculator."),
        Strategy(
            id: "hedging-cashout", name: "Hedging and cash-out", group: .sports,
            summary: "Bet the other side (or take a cash-out offer) to lock in a profit or limit a loss.",
            howItWorks: "If the odds have moved in your favour, a stake on the opposite outcome can guarantee a smaller profit whatever happens. Bookmakers' cash-out offers do the same in one step.",
            example: "You hold $10 at +200, which returns $30. After the odds move, the other side is +150; staking $12 on it also returns $30. You have staked $22 and get $30 back either way: +$8 guaranteed.",
            whenUsed: "Bettors managing risk on bets whose odds have shifted.",
            risks: [
                "Each hedge pays the bookmaker's margin again, lowering expected value.",
                "Cash-out offers are usually priced below fair value.",
                "Practice mode has no live in-game odds, so hedges are placed before the game.",
            ],
            complexity: .intermediate, horizon: "Per game", availability: .practice,
            practiceNote: "Bet both sides of a practice game before its day."),
        Strategy(
            id: "martingale", name: "Martingale and other progressions (warning)", group: .sports,
            summary: "Doubling the stake after every loss to win it all back — popular, and mathematically doomed.",
            howItWorks: "After a loss the next stake doubles, so one win recovers all previous losses plus the original stake. Variants such as Fibonacci or d'Alembert raise stakes more slowly. None of them changes the expected value of a single bet; they only turn many small wins into rare, catastrophic losses.",
            example: "Starting at $10, seven losses in a row cost $1,270 and require an eighth stake of $1,280. At fair even odds, seven straight losses happen about once in every 128 sequences — so they do happen.",
            whenUsed: "Explained because it is widely promoted, not because it works.",
            risks: [
                "Losses grow exponentially; a finite bankroll or a table limit guarantees eventual ruin.",
                "With a bookmaker margin, every bet still has negative expected value.",
                "It feels safe because it usually wins small amounts — until it doesn't.",
            ],
            complexity: .beginner, horizon: "Any", availability: .calculator,
            practiceNote: "Learn ▸ Martingale simulator shows how often the bankroll runs out."),
        Strategy(
            id: "line-shopping", name: "Line shopping", group: .sports,
            summary: "Compare odds across bookmakers and always take the best price.",
            howItWorks: "Bookmakers post different odds for the same game. Getting +110 instead of −110 on the same bet lowers the win rate you need to break even from 52.4 % to 47.6 %.",
            example: "At −110 you must win 52.4 % of bets to break even; at +110, only 47.6 %.",
            whenUsed: "Serious bettors with accounts at several bookmakers.",
            risks: [
                "It needs several accounts and quick comparisons.",
                "The gain per bet is small; it doesn't create an edge by itself.",
                "Practice mode has a single simulated bookmaker, so this is explained only.",
            ],
            complexity: .beginner, horizon: "Per bet", availability: .educationOnly,
            practiceNote: "Explained only: practice mode has one bookmaker."),
    ]
}
