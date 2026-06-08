// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { CONFIG_SIGNER, NATIVE_TOKEN_SYMBOL_KEY, NATIVE_TOKEN_DECIMALS_KEY } from "@SafeSwapCommon/Definitions.sol";
import { ChainConfig as ChainConfigImplementation } from "@ChainConfigCore/ChainConfig.sol";
import {
    AddressEntry,
    Bytes32Entry,
    CHAINCONFIG_ADDRESS,
    ChainConfig,
    Config,
    UintEntry
} from "@ChainConfig/IChainConfig.sol";


contract ChainConfigTestHelper is Test {

    uint256 internal constant _DEFAULT_CONFIG_TIMESTAMP  =  1_700_000_000;
    uint256 internal _next_config_timestamp;

    function _deploy_chain_config( ) internal
    {
        deployCodeTo( "lib/ChainConfig/src/ChainConfig.sol:ChainConfig", "", CHAINCONFIG_ADDRESS );
        _next_config_timestamp  =  _DEFAULT_CONFIG_TIMESTAMP;
    }

    function _publish_config_address( bytes32 key, address value ) internal
    {
        AddressEntry[] memory addresses  =  new AddressEntry[](1);
        addresses[0]  =  AddressEntry({ key: _bytes32_to_string( key ), value: value });

        Config memory config;
        config.chain_id   =  block.chainid;
        config.timestamp  =  _next_config_timestamp;
        config.addresses  =  addresses;
        config.bytes32s   =  new Bytes32Entry[](0);
        config.uints      =  new UintEntry[](0);

        _next_config_timestamp  =  _next_config_timestamp + 1;

        vm.prank( CONFIG_SIGNER );
        ChainConfig.write_config( config );
    }

    function _publish_config_bytes32( bytes32 key, bytes32 value ) internal
    {
        Bytes32Entry[] memory bytes32s  =  new Bytes32Entry[](1);
        bytes32s[0]  =  Bytes32Entry({ key: _bytes32_to_string( key ), value: value });

        Config memory config;
        config.chain_id   =  block.chainid;
        config.timestamp  =  _next_config_timestamp;
        config.addresses  =  new AddressEntry[](0);
        config.bytes32s   =  bytes32s;
        config.uints      =  new UintEntry[](0);

        _next_config_timestamp  =  _next_config_timestamp + 1;

        vm.prank( CONFIG_SIGNER );
        ChainConfig.write_config( config );
    }

    function _publish_config_uint( bytes32 key, uint256 value ) internal
    {
        UintEntry[] memory uints  =  new UintEntry[](1);
        uints[0]  =  UintEntry({ key: _bytes32_to_string( key ), value: value });

        Config memory config;
        config.chain_id   =  block.chainid;
        config.timestamp  =  _next_config_timestamp;
        config.addresses  =  new AddressEntry[](0);
        config.bytes32s   =  new Bytes32Entry[](0);
        config.uints      =  uints;

        _next_config_timestamp  =  _next_config_timestamp + 1;

        vm.prank( CONFIG_SIGNER );
        ChainConfig.write_config( config );
    }

    // Publish the native-token display config every descriptor constructor requires (defaults to an ETH/18 launch chain).
    function _publish_native_token_config( ) internal
    {
        _publish_config_bytes32( NATIVE_TOKEN_SYMBOL_KEY, bytes32("ETH") );
        _publish_config_uint( NATIVE_TOKEN_DECIMALS_KEY, 18 );
    }

    function _bytes32_to_string( bytes32 value ) private pure returns ( string memory )
    {
        uint256 length  =  0;

        while(  length < 32  &&  value[ length ] != 0  )
        {
            length  =  length + 1;
        }

        bytes memory buffer  =  new bytes(length);
        for(  uint256 i = 0  ;  i < length  ;  i = i + 1  )
        {
            buffer[ i ]  =  value[ i ];
        }

        return string(buffer);
    }
}
