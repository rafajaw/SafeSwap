// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { IPoolManagerIntegrationTests } from "@test/Common/TestManifest.sol";
import "@SafeSwapCommon/Definitions.sol";
import { PoolManagerIntegration, ERC6909_INTERFACE_ID } from "@SafeSwapCommon/PoolManagerIntegration.sol";
import { ChainConfig as ChainConfigImplementation } from "@ChainConfigCore/ChainConfig.sol";
import {
    AddressEntry,
    Bytes32Entry,
    CHAINCONFIG_ADDRESS,
    ChainConfig,
    Config,
    UintEntry
} from "@ChainConfig/IChainConfig.sol";

// ━━━━  HARNESS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract PoolManagerIntegrationHarness is PoolManagerIntegration {

    function pool_manager( )
    external  view returns ( address )
    {
        return address(PoolManager);
    }
}

// ━━━━  MOCKS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockPoolManagerShape {

    address internal constant _PROTOCOL_FEE_CONTROLLER  =  address(0xC0FFEE);

    bool internal _fail_protocol_fee_controller;
    bool internal _malformed_protocol_fee_controller_return;
    bool internal _fail_extsload;
    bool internal _malformed_extsload_return;
    bool internal _non_empty_extsload_return;
    bool internal _fail_supports_interface;
    bool internal _supports_erc6909  =  true;

    function set_fail_protocol_fee_controller( bool value )
    external
    {
        _fail_protocol_fee_controller  =  value;
    }

    function set_malformed_protocol_fee_controller_return( bool value )
    external
    {
        _malformed_protocol_fee_controller_return  =  value;
    }

    function set_fail_extsload( bool value )
    external
    {
        _fail_extsload  =  value;
    }

    function set_malformed_extsload_return( bool value )
    external
    {
        _malformed_extsload_return  =  value;
    }

    function set_non_empty_extsload_return( bool value )
    external
    {
        _non_empty_extsload_return  =  value;
    }

    function set_fail_supports_interface( bool value )
    external
    {
        _fail_supports_interface  =  value;
    }

    function set_supports_erc6909( bool value )
    external
    {
        _supports_erc6909  =  value;
    }

    function protocolFeeController( )
    external  view returns ( address )
    {
        if(  _fail_protocol_fee_controller  )  revert( "protocol fee controller failed" );

        if(  _malformed_protocol_fee_controller_return  )
        {
            assembly ("memory-safe") {
                mstore( 0x00, 0 )
                return( 0x00, 31 )
            }
        }

        return _PROTOCOL_FEE_CONTROLLER;
    }

    function extsload( bytes32[] calldata slots )
    external  view returns ( bytes32[] memory values )
    {
        slots;

        if(  _fail_extsload  )  revert( "extsload failed" );

        if(  _malformed_extsload_return  )
        {
            assembly ("memory-safe") {
                mstore( 0x00, 0x20 )
                mstore( 0x20, 0 )
                return( 0x00, 63 )
            }
        }

        if(  _non_empty_extsload_return  )
        {
            values     =  new bytes32[](1);
            values[0]  =  bytes32(uint256(1));
            return values;
        }

        return new bytes32[](0);
    }

    function supportsInterface( bytes4 interface_id )
    external  view returns ( bool )
    {
        if(  _fail_supports_interface  )  revert( "supportsInterface failed" );

        return interface_id == ERC6909_INTERFACE_ID && _supports_erc6909;
    }
}

// ━━━━  TEST SUITE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract PoolManagerIntegrationTest is Test, IPoolManagerIntegrationTests {

    uint256 internal constant _DEFAULT_TIMESTAMP       =  1_700_000_000;
    address internal constant _ADDRESS_WITHOUT_CODE    =  address(0xBEEF);

    MockPoolManagerShape internal _pool_manager;

    function setUp( )
    public
    {
        vm.chainId( 31_337 );
        vm.warp( _DEFAULT_TIMESTAMP + 1 days );

        deployCodeTo( "lib/ChainConfig/src/ChainConfig.sol:ChainConfig", "", CHAINCONFIG_ADDRESS );

        _pool_manager  =  new MockPoolManagerShape();
    }

    function test_constructor_reads_pool_manager_from_chain_config( )
    external
    {
        _publish_pool_manager( address(_pool_manager) );

        PoolManagerIntegrationHarness harness  =  new PoolManagerIntegrationHarness();

        assertEq( harness.pool_manager(), address(_pool_manager), "constructor should store the PoolManager published by CONFIG_SIGNER" );
    }

    function test_constructor_reverts_when_pool_manager_has_no_code( )
    external
    {
        _publish_pool_manager( _ADDRESS_WITHOUT_CODE );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_reverts_when_protocol_fee_controller_call_fails( )
    external
    {
        _pool_manager.set_fail_protocol_fee_controller( true );
        _publish_pool_manager( address(_pool_manager) );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_reverts_when_protocol_fee_controller_return_is_malformed( )
    external
    {
        _pool_manager.set_malformed_protocol_fee_controller_return( true );
        _publish_pool_manager( address(_pool_manager) );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_reverts_when_extsload_call_fails( )
    external
    {
        _pool_manager.set_fail_extsload( true );
        _publish_pool_manager( address(_pool_manager) );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_reverts_when_empty_extsload_return_is_malformed( )
    external
    {
        _pool_manager.set_malformed_extsload_return( true );
        _publish_pool_manager( address(_pool_manager) );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_reverts_when_empty_extsload_returns_non_empty_array( )
    external
    {
        _pool_manager.set_non_empty_extsload_return( true );
        _publish_pool_manager( address(_pool_manager) );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_reverts_when_erc6909_interface_check_fails( )
    external
    {
        _pool_manager.set_fail_supports_interface( true );
        _publish_pool_manager( address(_pool_manager) );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_reverts_when_pool_manager_does_not_support_erc6909( )
    external
    {
        _pool_manager.set_supports_erc6909( false );
        _publish_pool_manager( address(_pool_manager) );

        _expect_invalid_pool_manager();

        new PoolManagerIntegrationHarness();
    }

    function test_constructor_accepts_valid_pool_manager_shape( )
    external
    {
        _publish_pool_manager( address(_pool_manager) );

        PoolManagerIntegrationHarness harness  =  new PoolManagerIntegrationHarness();

        assertEq( harness.pool_manager(), address(_pool_manager), "valid PoolManager shape should be accepted" );
    }

    function _publish_pool_manager( address value ) internal
    {
        AddressEntry[] memory addresses  =  new AddressEntry[](1);
        addresses[0]  =  AddressEntry({ key: "uniswap_v4/pool_manager", value: value });

        Config memory config;
        config.chain_id   =  block.chainid;
        config.timestamp  =  _DEFAULT_TIMESTAMP;
        config.addresses  =  addresses;
        config.bytes32s   =  new Bytes32Entry[](0);
        config.uints      =  new UintEntry[](0);

        vm.prank( CONFIG_SIGNER );
        ChainConfig.write_config( config );
    }

    function _expect_invalid_pool_manager( ) internal
    {
        vm.expectRevert( bytes("SafeSwap: Invalid pool_manager") );
    }
}
