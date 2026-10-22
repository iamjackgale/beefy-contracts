// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

interface IAeroFactoryRegistry {
    function targetToGauge(address target) external view returns (address);
}
