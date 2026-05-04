// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IMToken {
    function balanceOfUnderlying(address owner) external returns (uint256);
}
