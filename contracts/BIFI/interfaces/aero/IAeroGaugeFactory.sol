// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

interface IAeroGaugeFactory {
    struct PenaltyConfig {
        uint256 minStakeBlocks;
        uint256 penaltyRate;
    }

    function effectivePenaltyConfig(address gauge) external view returns (PenaltyConfig memory);
}
