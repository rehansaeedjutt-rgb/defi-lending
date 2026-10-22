# defi-lending

> Aave-style DeFi lending protocol: deposits, borrows, utilization-based interest, liquidation.

[![CI](https://github.com/rehansaeedjutt-rgb/defi-lending/actions/workflows/ci.yml/badge.svg)](https://github.com/rehansaeedjutt-rgb/defi-lending/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.27-blue.svg)](https://soliditylang.org/)

## What this is

A lending protocol in the shape of Aave v2. Users deposit collateral
(WETH, WBTC), borrow against it (USDC), and interest accrues via a
utilization-based rate model. Positions that fall below the health
factor threshold can be liquidated for a bonus.

The whole point is the invariant: **you cannot take the protocol's money
without posting more collateral than you're borrowing.** Everything else
— interest rates, liquidation bonuses, health factors — exists to
enforce that invariant and to make it economically rational for the
protocol to keep enforcing it under stress.

## Why this project

Aave, Compound, Morpho, Spark, Euler, Silo — every lending protocol has
the same core math. Building one from scratch means understanding:

- Why collateral and borrow assets are separate
- Why LTV must be strictly less than the liquidation threshold (otherwise
  every new borrow is immediately liquidatable)
- Why the interest rate curve has a kink (to prevent utilization from
  reaching 100%, at which point borrowers cannot withdraw)
- Why liquidation bonus exists (it pays for the gas and risk of doing
  the liquidation, which is what keeps the protocol solvent)

None of that is obvious from reading Aave's docs. All of it becomes
obvious when you write it and the tests break.

## Live demo (local Hardhat node)

    npx hardhat node                                   # Terminal 1
    npx hardhat run scripts/deploy.ts --network localhost   # Terminal 2

Example output:

    Network: localhost
    Deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    Balance: 10000.0 ETH

    Deployed:
      usdc                 0x5FbDB2315678afecb367f032d93F642f64180aa3
      weth                 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
      wbtc                 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
      usdcFeed             0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
      wethFeed             0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
      wbtcFeed             0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
      interestRateModel    0x0165878A594ca255338adfa4d48449f69242Eb8F
      lendingPool          0xa513E6E4b8f2a923D98304ec87F64353C4D5C853

## What is in here

- **LendingPool.sol** — deposits, withdrawals, borrows, repayments,
  liquidation. Enforces LTV, health factor, and close factor.
- **InterestRateModel.sol** — two-slope (kinked) rate model. Same shape
  as Aave v2 and Compound. Ray math (1e27).
- **DataTypes.sol** — shared reserve and user-position structs.
- **Mocks** — MockERC20 with configurable decimals, MockAggregator for
  Chainlink prices (so tests can move the price).
- **13 tests** covering setup, deposit/withdraw, borrow/repay, health
  factor, interest accrual, and liquidation (bonus + close factor).
- **Deploy script** that wires up the full stack on a local node or
  Sepolia.
- **GitHub Actions CI** on Node 22.

## What is NOT here (deliberately)

- **No flash loans.** Aave v2's most distinctive feature, and it would
  double the contract size. The math is separate from the lending
  invariant; it belongs in a dedicated project.
- **No eMode / isolation mode.** Aave v3 features. Out of scope.
- **No aTokens.** Deposits here are tracked as scaled balances with a
  liquidity index, not as a transferable receipt token. Adding aTokens
  is a matter of wrapping the accounting, not the lending math.
- **No oracle fallback.** Single Chainlink aggregator per reserve. A
  production system needs fallbacks (Chainlink + Pyth + TWAP).
- **No governance.** `onlyOwner` throughout. Real Aave is a DAO.
- **Not audited.** Do not deploy to mainnet with real money.

## Architecture

    User
      |  deposit(WETH) / borrow(USDC) / repay / withdraw
      v
    +----------------+
    | LendingPool    | <--- InterestRateModel (per reserve)
    |                | <--- Chainlink price feed (per reserve)
    |  - reserves    |
    |  - user state  |
    |  - health      |
    +----------------+
      |  liquidate(user, coll, debt, amount)
      v
    Liquidator  -- repays debt, seizes collateral at a discount

## Design notes

**LTV < liquidation threshold, strictly.** If they were equal, every new
borrow would be immediately liquidatable — the position would be born
underwater. Aave uses 80% LTV / 85% threshold on most majors; this
project uses 70% / 80%. The gap is the safety margin.

**Close factor = 50%.** A liquidator can repay at most half the debt per
call. This is Aave v2's choice, and it is deliberate: without it, a
liquidation cascade could wipe out a large position in a single block
and tank the market further.

**Liquidation bonus = 5%.** The liquidator receives collateral worth
5% more than the debt they repaid. This pays for gas and risk; without
it, no one liquidates, and the protocol eats the bad debt.

**Two-slope interest model.** At low utilization the rate is flat-ish.
Beyond the kink (80%), the rate rises steeply to incentivize repayments
and additional deposits. A linear model would either charge too much at
low utilization (killing borrowing) or too little at high utilization
(risking liquidity exhaustion).

**Ray math.** All interest indices are 1e27, not 1e18. This is Aave
convention, and it matters because interest compounds in sub-wei amounts
over years — 1e18 loses precision on long time horizons.

**`viaIR: true`.** `getUserAccountData` returns 5 values and uses
several locals. The legacy pipeline cannot compile it ("stack too deep").
Aave also uses viaIR.

**Oracle manipulation is the real risk.** This project has none of the
defenses a real protocol needs (TWAP, fallback oracles, circuit
breakers). Anyone who can move the Chainlink price can drain this pool.
That is why it is labeled a demo.

## Testing

    npx hardhat test

13 tests, all offline. Coverage of the happy path, the LTV rejection,
the interest accrual, and the liquidation math (bonus calculation and
close-factor cap).

## Roadmap

- [ ] Flash loans
- [ ] aToken receipt tokens
- [ ] eMode (correlated assets share a risk tier)
- [ ] Oracle fallback (TWAP + Pyth)
- [ ] Governance module
- [ ] Formal verification of the liquidation invariant with Certora
- [ ] Deploy to Sepolia with real WETH/WBTC/USDC and real Chainlink feeds

## Disclaimer

**Educational project. Not audited. Do not deploy to mainnet with real
funds.** Every lending protocol that has been exploited in the last two
years was more carefully reviewed than this one. Use this to learn how
the math works, not to lend real money.

## License

MIT - see [LICENSE](LICENSE).

## Author

**Muhammad Rehan Saeed** - [GitHub](https://github.com/rehansaeedjutt-rgb)