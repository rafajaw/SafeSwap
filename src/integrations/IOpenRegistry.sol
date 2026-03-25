// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Minimal read interface for OpenRegistry. Full interface lives in the OpenRegistry repository.
interface IOpenRegistry {
    function read_key( bytes32 namespace, bytes32 key ) external view returns ( bytes32 value );
    function try_read_key( bytes32 namespace, bytes32 key ) external view returns ( bytes32 value, bool exists );
}
