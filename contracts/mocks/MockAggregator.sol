// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title MockAggregator
/// @notice Test-only Chainlink price feed. The owner can set any price.
/// Real deployments point to the official Chainlink aggregator per asset.
contract MockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint8 private immutable _decimals;
    string private _description;

    constructor(int256 initialAnswer, uint8 decimals_, string memory description_) {
        _answer = initialAnswer;
        _decimals = decimals_;
        _description = description_;
    }

    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external pure override returns (uint256) {
        return 4;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, block.timestamp, block.timestamp, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}