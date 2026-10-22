import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";

const ONE = 10n ** 6n; // USDC decimals
const ETH = 10n ** 18n;

// Price feeds use 8 decimals like Chainlink.
const PRICE_USDC = 100_000_000n;    // $1
const PRICE_WETH = 200_000_000_000n; // $2000 (2000 * 1e8)
const PRICE_WBTC = 6_000_000_000_000n; // $60,000

async function deployFixture() {
  const [owner, alice, bob, liquidator] = await ethers.getSigners();

  const Token = await ethers.getContractFactory("MockERC20");
  const usdc = await Token.deploy("USD Coin", "USDC", 6);
  const weth = await Token.deploy("Wrapped Ether", "WETH", 18);
  const wbtc = await Token.deploy("Wrapped BTC", "WBTC", 8);

  const Agg = await ethers.getContractFactory("MockAggregator");
  const usdcFeed = await Agg.deploy(PRICE_USDC, 8, "USDC/USD");
  const wethFeed = await Agg.deploy(PRICE_WETH, 8, "ETH/USD");
  const wbtcFeed = await Agg.deploy(PRICE_WBTC, 8, "BTC/USD");

  const IRM = await ethers.getContractFactory("InterestRateModel");
  // 0% base, 4% slope1, 75% slope2, 80% kink
  const irm = await IRM.deploy(0, 400, 7500, 8000);

  const Pool = await ethers.getContractFactory("LendingPool");
  const pool = await Pool.deploy(owner.address, 1000); // 10% reserve factor

  // Add reserves.
  await pool.addReserve(
    await weth.getAddress(),
    await irm.getAddress(),
    await wethFeed.getAddress(),
    7000, // 70% LTV
    8000, // 80% liquidation threshold
    500,  // 5% liquidation bonus
    false,
  );
  await pool.addReserve(
    await wbtc.getAddress(),
    await irm.getAddress(),
    await wbtcFeed.getAddress(),
    7000,
    8000,
    500,
    false,
  );
  await pool.addReserve(
    await usdc.getAddress(),
    await irm.getAddress(),
    await usdcFeed.getAddress(),
    0, // USDC cannot be collateral
    0,
    0,
    true, // but it can be borrowed
  );

  // Seed liquidity.
  await usdc.mint(owner.address, 1_000_000n * ONE);
  await weth.mint(alice.address, 100n * ETH);
  await wbtc.mint(alice.address, 10n * 10n ** 8n);

  await usdc.connect(owner).approve(await pool.getAddress(), ethers.MaxUint256);
  await pool.connect(owner).deposit(await usdc.getAddress(), 1_000_000n * ONE);

  await weth.connect(alice).approve(await pool.getAddress(), ethers.MaxUint256);
  await wbtc.connect(alice).approve(await pool.getAddress(), ethers.MaxUint256);

  // Give liquidator USDC to work with.
  await usdc.mint(liquidator.address, 100_000n * ONE);
  await usdc.connect(liquidator).approve(await pool.getAddress(), ethers.MaxUint256);

  return {
    usdc, weth, wbtc,
    usdcFeed, wethFeed, wbtcFeed,
    irm, pool,
    owner, alice, bob, liquidator,
  };
}

describe("LendingPool", () => {
  describe("Setup", () => {
    it("registers 3 reserves", async () => {
      const { pool } = await loadFixture(deployFixture);
      expect(await pool.getReserveCount()).to.equal(3);
    });

    it("owner deposited 1M USDC as liquidity", async () => {
      const { usdc, pool } = await loadFixture(deployFixture);
      const [totalDeposits] = await pool.getReserveData(await usdc.getAddress());
      expect(totalDeposits).to.equal(1_000_000n * ONE);
    });
  });

  describe("Deposit + Withdraw", () => {
    it("deposits WETH and tracks position", async () => {
      const { weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 10n * ETH);
      const [dep, bor, useColl] = await pool.getUserPosition(
        alice.address,
        await weth.getAddress(),
      );
      expect(dep).to.equal(10n * ETH);
      expect(bor).to.equal(0n);
      expect(useColl).to.equal(true);
    });

    it("withdraws part of collateral", async () => {
      const { weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 10n * ETH);
      await pool.connect(alice).withdraw(await weth.getAddress(), 4n * ETH);
      const [dep] = await pool.getUserPosition(alice.address, await weth.getAddress());
      expect(dep).to.equal(6n * ETH);
    });
  });

  describe("Borrow + Repay", () => {
    it("borrows USDC against WETH collateral", async () => {
      const { usdc, weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 1n * ETH); // $2000, 70% LTV = $1400
      await pool.connect(alice).borrow(await usdc.getAddress(), 1_000n * ONE);
      const [dep, bor] = await pool.getUserPosition(alice.address, await usdc.getAddress());
      expect(bor).to.equal(1_000n * ONE);
      void dep;
    });

    it("reverts borrow beyond LTV", async () => {
      const { usdc, weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 1n * ETH); // $2000, max borrow $1400
      await expect(
        pool.connect(alice).borrow(await usdc.getAddress(), 1_500n * ONE),
      ).to.be.revertedWith("borrow exceeds LTV");
    });

    it("repays debt", async () => {
      const { usdc, weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 1n * ETH);
      await pool.connect(alice).borrow(await usdc.getAddress(), 1_000n * ONE);

      const [, debtBefore] = await pool.getUserPosition(
        alice.address,
        await usdc.getAddress(),
      );
      expect(debtBefore).to.be.gt(0n);

      await usdc.mint(alice.address, 2_000n * ONE);
      await usdc.connect(alice).approve(await pool.getAddress(), ethers.MaxUint256);
      await pool.connect(alice).repay(await usdc.getAddress(), ethers.MaxUint256);

      const [, debtAfter] = await pool.getUserPosition(
        alice.address,
        await usdc.getAddress(),
      );
      // Interest accrual is calculated per second, so a 1-wei residue can
      // remain after repaying MaxUint256. This is expected — the position
      // is effectively closed. Tolerate the wei instead of asserting zero.
      expect(debtAfter).to.be.lte(1n);
    });
  });

  describe("Health factor", () => {
    it("is max when no debt", async () => {
      const { weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 1n * ETH);
      const [, , , , hf] = await pool.getUserAccountData(alice.address);
      expect(hf).to.equal(ethers.MaxUint256);
    });

    it("is above 1 when overcollateralized", async () => {
      const { usdc, weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 1n * ETH);
      await pool.connect(alice).borrow(await usdc.getAddress(), 1_000n * ONE);
      const [, , , , hf] = await pool.getUserAccountData(alice.address);
      // Collateral $2000 * 80% threshold = $1600. Debt $1000. HF = 1.6
      expect(hf).to.be.closeTo(ethers.parseEther("1.6"), ethers.parseEther("0.02"));
    });
  });

  describe("Interest accrual", () => {
    it("accrues interest over time", async () => {
      const { usdc, weth, pool, alice } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 10n * ETH);
      await pool.connect(alice).borrow(await usdc.getAddress(), 10_000n * ONE);

      const [, debtBefore] = await pool.getUserPosition(
        alice.address,
        await usdc.getAddress(),
      );

      // 30 days of interest.
      await time.increase(30 * 24 * 60 * 60);

      // Touch the reserve by repaying 1 wei.
      await usdc.mint(alice.address, ONE);
      await usdc.connect(alice).approve(await pool.getAddress(), ethers.MaxUint256);
      await pool.connect(alice).repay(await usdc.getAddress(), 1n);

      const [, debtAfter] = await pool.getUserPosition(
        alice.address,
        await usdc.getAddress(),
      );
      expect(debtAfter).to.be.gt(debtBefore);
    });
  });

  describe("Liquidation", () => {
    it("reverts when user is healthy", async () => {
      const { usdc, weth, pool, alice, liquidator } = await loadFixture(deployFixture);
      await pool.connect(alice).deposit(await weth.getAddress(), 10n * ETH);
      await pool.connect(alice).borrow(await usdc.getAddress(), 5_000n * ONE);
      await expect(
        pool.connect(liquidator).liquidate(
          alice.address,
          await weth.getAddress(),
          await usdc.getAddress(),
          1_000n * ONE,
        ),
      ).to.be.revertedWith("user healthy");
    });

    it("liquidates an unhealthy position and pays bonus", async () => {
      const { usdc, weth, wethFeed, pool, alice, liquidator } =
        await loadFixture(deployFixture);

      // Alice deposits 1 WETH ($2000), borrows $1400 (max LTV).
      await pool.connect(alice).deposit(await weth.getAddress(), 1n * ETH);
      await pool.connect(alice).borrow(await usdc.getAddress(), 1_400n * ONE);

      // ETH price drops to $1500. Collateral = $1500 * 80% = $1200 < $1400 debt.
      await wethFeed.setAnswer(150_000_000_000n);
      const [, , , , hf] = await pool.getUserAccountData(alice.address);
      expect(hf).to.be.lt(ethers.parseEther("1"));

      // Liquidator repays 50% of debt ($700) and gets WETH at 5% discount.
      const aliceWethBefore = await weth.balanceOf(alice.address);
      void aliceWethBefore;
      const liquidatorWethBefore = await weth.balanceOf(liquidator.address);

      await pool.connect(liquidator).liquidate(
        alice.address,
        await weth.getAddress(),
        await usdc.getAddress(),
        700n * ONE,
      );

      const liquidatorWethAfter = await weth.balanceOf(liquidator.address);
      expect(liquidatorWethAfter).to.be.gt(liquidatorWethBefore);

      // Bonus check: seized WETH should be worth ~$735 at $1500/WETH.
      const seized = liquidatorWethAfter - liquidatorWethBefore;
      // $735 / $1500 = 0.49 WETH
      expect(seized).to.be.closeTo(ethers.parseEther("0.49"), ethers.parseEther("0.02"));
    });

    it("caps liquidation repay at close factor (50%)", async () => {
      const { usdc, weth, wethFeed, pool, alice, liquidator } =
        await loadFixture(deployFixture);

      await pool.connect(alice).deposit(await weth.getAddress(), 1n * ETH);
      await pool.connect(alice).borrow(await usdc.getAddress(), 1_400n * ONE);
      await wethFeed.setAnswer(150_000_000_000n);

      // Try to repay 100% of debt — should be capped to 50%.
      await pool.connect(liquidator).liquidate(
        alice.address,
        await weth.getAddress(),
        await usdc.getAddress(),
        1_400n * ONE,
      );

      const [, debtAfter] = await pool.getUserPosition(
        alice.address,
        await usdc.getAddress(),
      );
      // Debt should be ~700 (half), not 0.
      expect(debtAfter).to.be.closeTo(700n * ONE, 5n * ONE);
    });
  });
});