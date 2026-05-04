// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC4626Minimal {
    function balanceOf(address owner) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}
