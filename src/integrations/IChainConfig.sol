// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
         ██████╗██╗  ██╗ █████╗ ██╗███╗   ██╗     ██████╗ ██████╗ ███╗   ██╗███████╗██╗ ██████╗
        ██╔════╝██║  ██║██╔══██╗██║████╗  ██║    ██╔════╝██╔═══██╗████╗  ██║██╔════╝██║██╔════╝
        ██║     ███████║███████║██║██╔██╗ ██║    ██║     ██║   ██║██╔██╗ ██║█████╗  ██║██║  ███╗
        ██║     ██╔══██║██╔══██║██║██║╚██╗██║    ██║     ██║   ██║██║╚██╗██║██╔══╝  ██║██║   ██║
        ╚██████╗██║  ██║██║  ██║██║██║ ╚████║    ╚██████╗╚██████╔╝██║ ╚████║██║     ██║╚██████╔╝
         ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝     ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝
        ━━━━━━━━━━━━━━━━━━━━━━  drop-in consumer interface  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    Drop-in consumer interface for the canonical ChainConfig deployment.

    QUICK USE:

        import { ChainConfig } from "<path>/IChainConfig.sol";

        contract MyContract {
            address immutable USDC  =  ChainConfig.read_address( SIGNER, "USDC_ADDRESS" );
            uint256 immutable FEE   =  ChainConfig.read_uint(    SIGNER, "FEE_BPS"      );
        }

    The `ChainConfig` constant below is typed `IChainConfig` and points at the canonical
    CREATE2 address on every supported EVM chain. No instance, no address copy-paste.

    For tests, deploy the actual ChainConfig contract at `CHAINCONFIG_ADDRESS` via
    `vm.etch` or Foundry's `deployCodeTo`.

    No external dependencies. Single file. Drop-in copy-paste or import as a foundry lib.
*/


// ━━━━  STRUCTS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct AddressEntry {
    string key;
    address value;
}

struct Bytes32Entry {
    string key;
    bytes32 value;
}

struct UintEntry {
    string key;
    uint256 value;
}

struct Config {
    uint256 chain_id;
    uint256 timestamp;
    AddressEntry[] addresses;
    Bytes32Entry[] bytes32s;
    UintEntry[] uints;
}


// ━━━━  ENUMS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum ValueType {
    NONE,
    ADDRESS,
    BYTES32,
    UINT
}


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error EmptyKey( );
error KeyTooLong( string key, uint256 length );

error ChainIdMismatch( uint256 signed_chain_id, uint256 block_chain_id );
error EmptyConfig( );
error InvalidSignature( address signer, bytes32 digest, bytes signature );
error KeyNotSet( address signer, bytes32 key );
error KeyTypeMismatch( address signer, bytes32 key, ValueType current_value_type, ValueType expected_value_type );
error StaleConfig( address signer, bytes32 key, uint256 signed_timestamp, uint256 prev_timestamp );
error TimestampInFuture( uint256 signed_timestamp, uint256 block_timestamp );


// ━━━━  INTERFACE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IChainConfig {

    event AddressWritten( address indexed signer, bytes32 indexed key, address value );
    event Bytes32Written( address indexed signer, bytes32 indexed key, bytes32 value );
    event UintWritten(    address indexed signer, bytes32 indexed key, uint256 value );


    // ─── Writes ────────────────────────────────────────────────────────────────────────────────────────────────────────────────

    function write_config( Config calldata config ) external;

    function write_config_as( Config calldata config, address signer, bytes calldata signature, bool is_eip1271 ) external;


    // ─── Reads ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────

    function read_address( address signer, string calldata key ) external view returns ( address );
    function read_address( address signer, bytes32 key )        external view returns ( address );

    function read_bytes32( address signer, string calldata key ) external view returns ( bytes32 );
    function read_bytes32( address signer, bytes32 key )        external view returns ( bytes32 );

    function read_uint( address signer, string calldata key ) external view returns ( uint256 );
    function read_uint( address signer, bytes32 key )        external view returns ( uint256 );


    // ─── Off-chain helpers ─────────────────────────────────────────────────────────────────────────────────────────────────────

    function DOMAIN_SEPARATOR( ) external view returns ( bytes32 );

    function __OFF_CHAIN__hash_config( Config calldata config ) external view returns ( bytes32 digest );

}


// ━━━━  CANONICAL DEPLOYMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// Same address on every supported EVM chain (deterministic CREATE2 deployment).
address constant CHAINCONFIG_ADDRESS  =  0x5Afec0de00EB1c5323C7faA110f67499F744467b;

IChainConfig constant ChainConfig     =  IChainConfig( CHAINCONFIG_ADDRESS );
