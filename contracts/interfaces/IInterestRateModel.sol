// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IInterestRateModel
/// @notice Computes borrow and supply rates from utilization.
interface IInterestRateModel {
    /// @notice Annualized borrow rate in ray (1e27), given current utilization.
    /// @param availableLiquidity Total deposited but not borrowed.
    /// @param totalBorrows Total outstanding borrows.
    /// @return rate Annualized borrow rate as a ray (1e27 = 100%).
    function getBorrowRate(uint256 availableLiquidity, uint256 totalBorrows)
        external
        view
        returns (uint256 rate);

    /// @notice Annualized supply rate in ray, given utilization and reserve factor.
    /// @dev supplyRate = borrowRate * utilization * (1 - reserveFactor).
    function getSupplyRate(
        uint256 availableLiquidity,
        uint256 totalBorrows,
        uint256 reserveFactor
    ) external view returns (uint256 rate);
}