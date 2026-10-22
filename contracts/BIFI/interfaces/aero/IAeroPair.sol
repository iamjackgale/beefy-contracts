// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

interface IAeroPair {
    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

    function POOL_TYPE() external view returns (bytes32);

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);

    function claimFees(address recipient) external returns (uint256 claimed0, uint256 claimed1);

    function pendingFees(address account) external view returns (uint256 pending0, uint256 pending1);
}
