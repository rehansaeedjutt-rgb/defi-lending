import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Deploys the full lending stack on a single chain:
//   1. Mock USDC / WETH / WBTC  (on a real chain, point at the real ones)
//   2. Three mock Chainlink aggregators
//   3. InterestRateModel
//   4. LendingPool with the three reserves registered
//
// Writes addresses to deployments/<network>.json.

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Network: ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance: ${ethers.formatEther(bal)} ETH\n`);

  const Token = await ethers.getContractFactory("MockERC20");
  const usdc = await Token.deploy("USD Coin", "USDC", 6);
  const weth = await Token.deploy("Wrapped Ether", "WETH", 18);
  const wbtc = await Token.deploy("Wrapped BTC", "WBTC", 8);
  await Promise.all([usdc.waitForDeployment(), weth.waitForDeployment(), wbtc.waitForDeployment()]);

  const Agg = await ethers.getContractFactory("MockAggregator");
  const usdcFeed = await Agg.deploy(100_000_000n, 8, "USDC/USD");
  const wethFeed = await Agg.deploy(200_000_000_000n, 8, "ETH/USD");
  const wbtcFeed = await Agg.deploy(6_000_000_000_000n, 8, "BTC/USD");
  await Promise.all([usdcFeed.waitForDeployment(), wethFeed.waitForDeployment(), wbtcFeed.waitForDeployment()]);

  const IRM = await ethers.getContractFactory("InterestRateModel");
  const irm = await IRM.deploy(0, 400, 7500, 8000);
  await irm.waitForDeployment();

  const Pool = await ethers.getContractFactory("LendingPool");
  const pool = await Pool.deploy(deployer.address, 1000);
  await pool.waitForDeployment();

  await (await pool.addReserve(
    await weth.getAddress(),
    await irm.getAddress(),
    await wethFeed.getAddress(),
    7000, 8000, 500, false,
  )).wait();
  await (await pool.addReserve(
    await wbtc.getAddress(),
    await irm.getAddress(),
    await wbtcFeed.getAddress(),
    7000, 8000, 500, false,
  )).wait();
  await (await pool.addReserve(
    await usdc.getAddress(),
    await irm.getAddress(),
    await usdcFeed.getAddress(),
    0, 0, 0, true,
  )).wait();

  const outDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const payload = {
    network: network.name,
    chainId: Number((await ethers.provider.getNetwork()).chainId),
    deployedAt: new Date().toISOString(),
    contracts: {
      usdc: await usdc.getAddress(),
      weth: await weth.getAddress(),
      wbtc: await wbtc.getAddress(),
      usdcFeed: await usdcFeed.getAddress(),
      wethFeed: await wethFeed.getAddress(),
      wbtcFeed: await wbtcFeed.getAddress(),
      interestRateModel: await irm.getAddress(),
      lendingPool: await pool.getAddress(),
    },
  };
  fs.writeFileSync(path.join(outDir, `${network.name}.json`), JSON.stringify(payload, null, 2));
  console.log("Deployed:");
  for (const [k, v] of Object.entries(payload.contracts)) console.log(`  ${k.padEnd(20)} ${v}`);
  console.log(`\nWritten to deployments/${network.name}.json`);
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });