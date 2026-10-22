// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {DataTypes} from "./DataTypes.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

/// @title LendingPool
/// @notice Aave v2-style lending pool with liquidation support.
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS = 10_000;
    uint256 public constant PRICE_FEED_DECIMALS = 8;
    uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;
    uint256 public constant CLOSE_FACTOR_BPS = 5_000; // 50% max repay per liquidation

    mapping(address => DataTypes.Reserve) public reserves;
    address[] public reserveList;
    mapping(address => bool) public isReserve;

    mapping(address => mapping(address => DataTypes.UserReserve)) public userReserves;
    mapping(address => address[]) public userAssets;
    mapping(address => mapping(address => bool)) public hasPosition;

    uint256 public reserveFactor;
    address public treasury;

    event ReserveAdded(address indexed asset);
    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, address indexed asset, uint256 amount);
    event Repay(address indexed user, address indexed asset, uint256 amount);
    event CollateralToggled(address indexed user, address indexed asset, bool enabled);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        address collateralAsset,
        address debtAsset,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    constructor(address treasury_, uint256 reserveFactor_) Ownable(msg.sender) {
        require(reserveFactor_ < BPS, "reserve factor too high");
        treasury = treasury_;
        reserveFactor = reserveFactor_;
    }

    // ============ Admin ============

    function addReserve(
        address asset,
        address interestModel,
        address priceFeed,
        uint256 ltvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        bool borrowingEnabled
    ) external onlyOwner {
        require(!isReserve[asset], "already added");
        // Non-collateral assets (like USDC borrow-only) may have LTV = threshold = 0.
        // For any other reserve, LTV must be strictly below the threshold:
        // you can never borrow more than the liquidation cutoff.
        if (!(ltvBps == 0 && liquidationThresholdBps == 0)) {
            require(ltvBps < liquidationThresholdBps, "ltv must be < threshold");
        }
        require(liquidationThresholdBps < BPS, "threshold must be < 100%");
        require(liquidationBonusBps < BPS / 2, "bonus too high");

        uint8 dec = _decimals(asset);
        reserves[asset] = DataTypes.Reserve({
            asset: asset,
            interestModel: interestModel,
            priceFeed: priceFeed,
            totalDeposits: 0,
            totalBorrows: 0,
            lastUpdateTimestamp: block.timestamp,
            liquidityIndex: RAY,
            borrowIndex: RAY,
            assetDecimals: dec,
            active: true,
            borrowingEnabled: borrowingEnabled,
            ltv: ltvBps,
            liquidationThreshold: liquidationThresholdBps,
            liquidationBonus: liquidationBonusBps
        });
        isReserve[asset] = true;
        reserveList.push(asset);
        emit ReserveAdded(asset);
    }

    // ============ User actions ============

    function deposit(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "amount = 0");
        DataTypes.Reserve storage r = reserves[asset];
        require(r.active, "not active");
        _accrueInterest(asset);

        DataTypes.UserReserve storage pos = userReserves[msg.sender][asset];
        uint256 scaled = (amount * RAY) / r.liquidityIndex;
        pos.depositAmount += scaled;

        if (!hasPosition[msg.sender][asset]) {
            hasPosition[msg.sender][asset] = true;
            userAssets[msg.sender].push(asset);
            pos.useAsCollateral = true;
        }

        r.totalDeposits += amount;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, asset, amount);
    }

    function withdraw(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "amount = 0");
        _accrueInterest(asset);
        DataTypes.Reserve storage r = reserves[asset];
        DataTypes.UserReserve storage pos = userReserves[msg.sender][asset];

        uint256 current = (pos.depositAmount * r.liquidityIndex) / RAY;
        require(amount <= current, "insufficient balance");
        require(amount <= r.totalDeposits - r.totalBorrows, "insufficient liquidity");

        uint256 scaled = (amount * RAY) / r.liquidityIndex;
        pos.depositAmount -= scaled;
        r.totalDeposits -= amount;

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, asset, amount);
        _requireHealthy(msg.sender);
    }

    function borrow(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "amount = 0");
        DataTypes.Reserve storage r = reserves[asset];
        require(r.active && r.borrowingEnabled, "borrow disabled");
        _accrueInterest(asset);
        require(amount <= r.totalDeposits - r.totalBorrows, "insufficient liquidity");

        // Enforce LTV before mutating state. HF check alone allows borrowing
        // up to the liquidation threshold (80%), but Aave-style protocols
        // cap new borrows at the LTV (70%). Without this, a user could open
        // a position that is immediately liquidatable.
        uint256 borrowValueUsd = _toUsd(amount, r.assetDecimals, _getPrice(r.priceFeed));
        (,, uint256 availableBorrowValue,,) = getUserAccountData(msg.sender);
        require(borrowValueUsd <= availableBorrowValue, "borrow exceeds LTV");

        DataTypes.UserReserve storage pos = userReserves[msg.sender][asset];
        uint256 scaled = (amount * RAY) / r.borrowIndex;
        pos.borrowAmount += scaled;

        if (!hasPosition[msg.sender][asset]) {
            hasPosition[msg.sender][asset] = true;
            userAssets[msg.sender].push(asset);
        }

        r.totalBorrows += amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, asset, amount);
        _requireHealthy(msg.sender);
    }

    function repay(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "amount = 0");
        _accrueInterest(asset);
        DataTypes.Reserve storage r = reserves[asset];
        DataTypes.UserReserve storage pos = userReserves[msg.sender][asset];

        uint256 current = (pos.borrowAmount * r.borrowIndex) / RAY;
        uint256 toRepay = amount > current ? current : amount;
        require(toRepay > 0, "nothing to repay");

        uint256 scaled = (toRepay * RAY) / r.borrowIndex;
        pos.borrowAmount -= scaled;
        r.totalBorrows -= toRepay;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), toRepay);
        emit Repay(msg.sender, asset, toRepay);
    }

    function setUseAsCollateral(address asset, bool enabled) external {
        require(hasPosition[msg.sender][asset], "no position");
        userReserves[msg.sender][asset].useAsCollateral = enabled;
        if (!enabled) _requireHealthy(msg.sender);
        emit CollateralToggled(msg.sender, asset, enabled);
    }

    /// @notice Liquidate an undercollateralized position.
    /// The caller repays `repayAmount` of debt and receives collateral worth
    /// `repayAmount * (1 + liquidationBonus)` at oracle prices.
    function liquidate(
        address user,
        address collateralAsset,
        address debtAsset,
        uint256 repayAmount
    ) external nonReentrant {
        require(isReserve[collateralAsset] && isReserve[debtAsset], "reserve not active");
        require(collateralAsset != debtAsset, "same asset");
        require(repayAmount > 0, "amount = 0");

        (,,, , uint256 hf) = getUserAccountData(user);
        require(hf < HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "user healthy");

        _accrueInterest(collateralAsset);
        _accrueInterest(debtAsset);

        DataTypes.Reserve storage debtR = reserves[debtAsset];
        DataTypes.Reserve storage collR = reserves[collateralAsset];
        DataTypes.UserReserve storage userDebt = userReserves[user][debtAsset];
        DataTypes.UserReserve storage userColl = userReserves[user][collateralAsset];

        uint256 userDebtCurrent = (userDebt.borrowAmount * debtR.borrowIndex) / RAY;
        uint256 userCollCurrent = (userColl.depositAmount * collR.liquidityIndex) / RAY;
        require(userDebtCurrent > 0 && userCollCurrent > 0, "nothing to liquidate");

        uint256 maxRepay = (userDebtCurrent * CLOSE_FACTOR_BPS) / BPS;
        uint256 toRepay = repayAmount > maxRepay ? maxRepay : repayAmount;

        uint256 debtPrice = _getPrice(debtR.priceFeed);
        uint256 collPrice = _getPrice(collR.priceFeed);

        uint256 debtValueUsd = _toUsd(toRepay, debtR.assetDecimals, debtPrice);
        uint256 seizedValueUsd = (debtValueUsd * (BPS + collR.liquidationBonus)) / BPS;
        uint256 collSeized =
            (seizedValueUsd * (10 ** collR.assetDecimals) * (10 ** PRICE_FEED_DECIMALS)) /
            (collPrice * 1e18);

        if (collSeized > userCollCurrent) {
            collSeized = userCollCurrent;
            uint256 actualSeizedUsd = _toUsd(collSeized, collR.assetDecimals, collPrice);
            uint256 actualDebtUsd = (actualSeizedUsd * BPS) / (BPS + collR.liquidationBonus);
            toRepay = (actualDebtUsd * (10 ** debtR.assetDecimals) * (10 ** PRICE_FEED_DECIMALS)) /
                (debtPrice * 1e18);
        }
        require(toRepay > 0 && collSeized > 0, "liquidation too small");

        uint256 debtScaled = (toRepay * RAY) / debtR.borrowIndex;
        userDebt.borrowAmount -= debtScaled;
        debtR.totalBorrows -= toRepay;

        uint256 collScaled = (collSeized * RAY) / collR.liquidityIndex;
        userColl.depositAmount -= collScaled;
        collR.totalDeposits -= collSeized;

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), toRepay);
        IERC20(collateralAsset).safeTransfer(msg.sender, collSeized);

        emit Liquidation(user, msg.sender, collateralAsset, debtAsset, toRepay, collSeized);
    }

    // ============ Views ============

    function getUserAccountData(address user)
        public
        view
        returns (
            uint256 totalCollateralValue,
            uint256 totalDebtValue,
            uint256 availableBorrowValue,
            uint256 currentLiquidationThreshold,
            uint256 healthFactor
        )
    {
        uint256 weightedThreshold;
        uint256 weightedLtv;

        address[] storage assets = userAssets[user];
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            DataTypes.Reserve storage r = reserves[asset];
            DataTypes.UserReserve storage pos = userReserves[user][asset];
            uint256 price = _getPrice(r.priceFeed);

            if (pos.depositAmount > 0 && pos.useAsCollateral) {
                uint256 current = (pos.depositAmount * r.liquidityIndex) / RAY;
                uint256 value = _toUsd(current, r.assetDecimals, price);
                totalCollateralValue += value;
                weightedThreshold += (value * r.liquidationThreshold) / BPS;
                weightedLtv += (value * r.ltv) / BPS;
            }
            if (pos.borrowAmount > 0) {
                uint256 current = (pos.borrowAmount * r.borrowIndex) / RAY;
                totalDebtValue += _toUsd(current, r.assetDecimals, price);
            }
        }

        currentLiquidationThreshold = totalCollateralValue == 0
            ? 0
            : (weightedThreshold * BPS) / totalCollateralValue;

        if (totalDebtValue == 0) {
            availableBorrowValue = weightedLtv;
            healthFactor = type(uint256).max;
        } else {
            availableBorrowValue = weightedLtv > totalDebtValue ? weightedLtv - totalDebtValue : 0;
            healthFactor = (weightedThreshold * 1e18) / totalDebtValue;
        }
    }

    function getUserPosition(address user, address asset)
        external
        view
        returns (uint256 depositAmount, uint256 borrowAmount, bool useAsCollateral)
    {
        DataTypes.Reserve storage r = reserves[asset];
        DataTypes.UserReserve storage pos = userReserves[user][asset];
        depositAmount = (pos.depositAmount * r.liquidityIndex) / RAY;
        borrowAmount = (pos.borrowAmount * r.borrowIndex) / RAY;
        useAsCollateral = pos.useAsCollateral;
    }

    function getReserveData(address asset)
        external
        view
        returns (
            uint256 totalDeposits,
            uint256 totalBorrows,
            uint256 availableLiquidity,
            uint256 liquidityIndex,
            uint256 borrowIndex,
            uint256 borrowRateRay,
            uint256 supplyRateRay
        )
    {
        DataTypes.Reserve storage r = reserves[asset];
        uint256 available = r.totalDeposits - r.totalBorrows;
        IInterestRateModel irm = IInterestRateModel(r.interestModel);
        return (
            r.totalDeposits,
            r.totalBorrows,
            available,
            r.liquidityIndex,
            r.borrowIndex,
            irm.getBorrowRate(available, r.totalBorrows),
            irm.getSupplyRate(available, r.totalBorrows, reserveFactor)
        );
    }

    function getReserveCount() external view returns (uint256) {
        return reserveList.length;
    }

    // ============ Internals ============

    function _accrueInterest(address asset) internal {
        DataTypes.Reserve storage r = reserves[asset];
        uint256 elapsed = block.timestamp - r.lastUpdateTimestamp;
        if (elapsed == 0) return;

        uint256 available = r.totalDeposits - r.totalBorrows;
        IInterestRateModel irm = IInterestRateModel(r.interestModel);
        uint256 borrowRateRay = irm.getBorrowRate(available, r.totalBorrows);
        uint256 supplyRateRay = irm.getSupplyRate(available, r.totalBorrows, reserveFactor);

        uint256 borrowDelta = (borrowRateRay * elapsed) / SECONDS_PER_YEAR;
        uint256 supplyDelta = (supplyRateRay * elapsed) / SECONDS_PER_YEAR;

        r.totalBorrows = r.totalBorrows + (r.totalBorrows * borrowDelta) / RAY;
        r.totalDeposits = r.totalDeposits + (r.totalDeposits * supplyDelta) / RAY;
        r.borrowIndex = r.borrowIndex + borrowDelta;
        r.liquidityIndex = r.liquidityIndex + supplyDelta;
        r.lastUpdateTimestamp = block.timestamp;
    }

    function _requireHealthy(address user) internal view {
        (,,, , uint256 hf) = getUserAccountData(user);
        require(hf >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "would be undercollateralized");
    }

    function _getPrice(address feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0, "bad price");
        require(updatedAt > 0, "stale price");
        return uint256(answer);
    }

    function _toUsd(uint256 amount, uint8 decimals_, uint256 price) internal pure returns (uint256) {
        return (amount * price * 1e18) / (10 ** decimals_ * 10 ** PRICE_FEED_DECIMALS);
    }

    function _decimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(success && data.length >= 32, "no decimals");
        return abi.decode(data, (uint8));
    }
}