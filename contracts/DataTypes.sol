// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title DataTypes
/// @notice Shared structs and enums for the lending protocol.
library DataTypes {
    /// @notice Per-asset reserve configuration and state.
    struct Reserve {
        address asset;              // underlying ERC-20
        address interestModel;      // interest rate model address
        address priceFeed;          // Chainlink aggregator
        uint256 totalDeposits;      // total supplied (principal + accrued)
        uint256 totalBorrows;       // total borrowed (principal + accrued)
        uint256 lastUpdateTimestamp;
        uint256 liquidityIndex;     // 1e27 ray, cumulative supply interest
        uint256 borrowIndex;        // 1e27 ray, cumulative borrow interest
        uint8 assetDecimals;        // for price math normalization
        bool active;
        bool borrowingEnabled;
        // risk parameters
        uint256 ltv;                // basis points, e.g. 8000 = 80%
        uint256 liquidationThreshold; // basis points, e.g. 8500 = 85%
        uint256 liquidationBonus;   // basis points, e.g. 500 = 5%
    }

    /// @notice Per-user per-asset position.
    struct UserReserve {
        uint256 depositAmount;      // scaled by liquidityIndex (ray)
        uint256 borrowAmount;       // scaled by borrowIndex (ray)
        bool useAsCollateral;       // whether deposits count toward HF
    }
}