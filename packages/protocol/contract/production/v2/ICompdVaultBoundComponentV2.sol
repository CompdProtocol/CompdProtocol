// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Shared, non-ERC165 identity surface for immutable Vault-bound V2 components.
interface ICompdVaultBoundComponentV2 {
    /// @dev Immutable by construction and without any setter; stored rather than Solidity `immutable`
    /// so the reviewed runtime code hash is independent of the fresh Vault address.
    function vault() external view returns (address);
    function COMPONENT_TYPE_ID() external view returns (bytes32);
    function COMPONENT_VERSION() external view returns (uint32);
}
