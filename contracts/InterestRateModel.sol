// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

/// @title InterestRateModel
/// @notice Two-slope (kinked) interest rate model, the same shape used by
/// Aave v2 and Compound.
///
/// At low utilization the rate is low. When utilization crosses the kink
/// (usually 80%), the rate rises steeply to incentivize repayments and
/// additional deposits.
///
/// Math is in ray (1e27) to match Aave conventions. All APR values are
/// annualized.
contract InterestRateModel is IInterestRateModel {
    uint256 public constant RAY = 1e27;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant BPS = 10_000;

    uint256 public immutable baseRateRay;
    uint256 public immutable slope1Ray;
    uint256 public immutable slope2Ray;
    uint256 public immutable kinkBps; // e.g. 8000 = 80%

    constructor(
        uint256 baseRateBps_,
        uint256 slope1Bps_,
        uint256 slope2Bps_,
        uint256 kinkBps_
    ) {
        require(kinkBps_ > 0 && kinkBps_ <= BPS, "kink out of range");
        baseRateRay = (baseRateBps_ * RAY) / BPS;
        slope1Ray = (slope1Bps_ * RAY) / BPS;
        slope2Ray = (slope2Bps_ * RAY) / BPS;
        kinkBps = kinkBps_;
    }

    /// @inheritdoc IInterestRateModel
    function getBorrowRate(uint256 availableLiquidity, uint256 totalBorrows)
        public
        view
        override
        returns (uint256)
    {
        uint256 total = availableLiquidity + totalBorrows;
        if (total == 0) {
            return baseRateRay;
        }

        // utilization = totalBorrows / total, in bps
        uint256 utilizationBps = (totalBorrows * BPS) / total;

        if (utilizationBps <= kinkBps) {
            // Linear along slope1 from baseRate to baseRate+slope1.
            return baseRateRay + (slope1Ray * utilizationBps) / kinkBps;
        }

        // Beyond the kink, add slope2 for the remaining utilization.
        uint256 excess = utilizationBps - kinkBps;
        uint256 excessCap = BPS - kinkBps;
        return baseRateRay + slope1Ray + (slope2Ray * excess) / excessCap;
    }

    /// @inheritdoc IInterestRateModel
    function getSupplyRate(
        uint256 availableLiquidity,
        uint256 totalBorrows,
        uint256 reserveFactor
    ) external view override returns (uint256) {
        uint256 total = availableLiquidity + totalBorrows;
        if (total == 0) {
            return 0;
        }
        uint256 borrowRate = getBorrowRate(availableLiquidity, totalBorrows);
        uint256 utilizationRay = (totalBorrows * RAY) / total;
        uint256 gross = (borrowRate * utilizationRay) / RAY;
        // Reserve factor is taken by the protocol before passing to suppliers.
        return (gross * (BPS - reserveFactor)) / BPS;
    }
}