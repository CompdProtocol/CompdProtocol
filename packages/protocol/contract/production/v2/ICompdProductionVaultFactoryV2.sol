// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Public V2 factory identity only; deliberately exposes no custody or emergency authority.
interface ICompdProductionVaultFactoryV2 {
    function productionVault() external view returns (address);
    function compdToken() external view returns (address);
    function quoteToken() external view returns (address);
}
