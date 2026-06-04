// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "@SafeSwapRouter/SafeSwapRouter.sol";
import "@SafeSwapRouter/libraries/SafeSwapCommon.sol";
import "@SafeSwapHook/SafeSwapHook.sol";
import "@SafeSwapNft/SafeSwapNft.sol";
import "@SafeSwapNft/ISafeSwapNft.sol";
import { CHAINCONFIG_ADDRESS } from "@ChainConfig/IChainConfig.sol";
import {
    CONFIG_SIGNER,
    POOL_MANAGER_KEY,
    INITIAL_TREASURY_KEY,
    SAFESWAP_ROUTER_KEY,
    SAFESWAP_NFT_KEY,
    SAFESWAP_HOOK_CODEHASH_KEY,
    SAFESWAP_HOOK_ADDRESS_MAGIC,
    HOOK_ADDRESS_MAGIC_SHIFT,
    HOOK_ADDRESS_REBATE_PROFILE_SHIFT,
    REQUIRED_HOOK_PERMISSIONS
} from "@SafeSwapRouter/Definitions.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@UniswapV4Core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta, toBalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";


uint160 constant SQRT_PRICE_1_1  =  79228162514264337593543950336;  // 2^96; Q96 encoding of price 1.0.


// ━━━━  MOCK ERC20  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping( address => uint256 ) public balanceOf;
    mapping( address => mapping( address => uint256 ) ) public allowance;

    constructor( string memory _name, string memory _symbol, uint8 _decimals )
    {
        name      =  _name;
        symbol    =  _symbol;
        decimals  =  _decimals;
    }

    function mint( address to, uint256 amount ) external
    {
        balanceOf[ to ]  =  balanceOf[ to ] + amount;
        totalSupply      =  totalSupply + amount;
        emit Transfer( address(0), to, amount );
    }

    function approve( address spender, uint256 value ) external returns ( bool )
    {
        allowance[ msg.sender ][ spender ]  =  value;
        emit Approval( msg.sender, spender, value );
        return true;
    }

    function transfer( address to, uint256 value ) external returns ( bool )
    {
        balanceOf[ msg.sender ]  =  balanceOf[ msg.sender ] - value;
        balanceOf[ to ]          =  balanceOf[ to ] + value;
        emit Transfer( msg.sender, to, value );
        return true;
    }

    function transferFrom( address from, address to, uint256 value ) external returns ( bool )
    {
        if(  allowance[ from ][ msg.sender ] != type(uint256).max  )
        {
            allowance[ from ][ msg.sender ]  =  allowance[ from ][ msg.sender ] - value;
        }
        balanceOf[ from ]  =  balanceOf[ from ] - value;
        balanceOf[ to ]    =  balanceOf[ to ] + value;
        emit Transfer( from, to, value );
        return true;
    }
}


// ━━━━  MOCK CHAIN CONFIG  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockChainConfig {
    mapping( address => mapping( bytes32 => address ) ) public addresses;
    mapping( address => mapping( bytes32 => bytes32 ) ) public bytes32s;

    function set_address( address signer, bytes32 key, address value ) external
    {
        addresses[ signer ][ key ]  =  value;
    }

    function set_bytes32( address signer, bytes32 key, bytes32 value ) external
    {
        bytes32s[ signer ][ key ]  =  value;
    }

    function read_address( address signer, bytes32 key ) external view returns ( address )
    {
        return addresses[ signer ][ key ];
    }

    function read_address( address signer, string calldata key ) external view returns ( address )
    {
        return addresses[ signer ][ bytes32(bytes(key)) ];
    }

    function read_bytes32( address signer, bytes32 key ) external view returns ( bytes32 )
    {
        return bytes32s[ signer ][ key ];
    }

    function read_bytes32( address signer, string calldata key ) external view returns ( bytes32 )
    {
        return bytes32s[ signer ][ bytes32(bytes(key)) ];
    }
}


// ━━━━  MOCK POOL MANAGER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    address public protocolFeeController;

    int128 public mock_swap_amount0;
    int128 public mock_swap_amount1;

    function set_mock_swap_amounts( int128 amount0, int128 amount1 ) external
    {
        mock_swap_amount0  =  amount0;
        mock_swap_amount1  =  amount1;
    }

    function unlock( bytes calldata data ) external returns ( bytes memory )
    {
        return IUnlockCallback(msg.sender).unlockCallback( data );
    }

    function initialize( PoolKey memory, uint160 ) external pure returns ( int24 )
    {
        return 0;
    }

    function swap( PoolKey memory, IPoolManager.SwapParams memory, bytes calldata )
    external view returns ( BalanceDelta )
    {
        return toBalanceDelta( mock_swap_amount0, mock_swap_amount1 );
    }

    function donate( PoolKey memory, uint256, uint256, bytes calldata ) external pure returns ( BalanceDelta )
    {
        return toBalanceDelta( 0, 0 );
    }

    function sync( Currency ) external { }

    function settle( ) external payable returns ( uint256 )
    {
        return 0;
    }

    function take( Currency currency, address to, uint256 amount ) external
    {
        address token  =  Currency.unwrap( currency );
        if(  amount == 0  )  return;
        bool success  =  MockERC20(token).transfer( to, amount );
        require( success, "Mock transfer failed" );
    }

    function extsload( bytes32 ) external pure returns ( bytes32 )
    {
        // slot0 packs sqrtPriceX96 in the low 160 bits; tick stays 0. Liquidity slot is read separately as zero below.
        return bytes32(uint256(SQRT_PRICE_1_1));
    }

    function extsload( bytes32[] calldata slots ) external pure returns ( bytes32[] memory )
    {
        return new bytes32[]( slots.length );
    }

    function supportsInterface( bytes4 interface_id ) external pure returns ( bool )
    {
        return interface_id == 0x01ffc9a7 || interface_id == 0x0f632fb3;
    }

    receive( ) external payable { }
}


// ━━━━  MOCK BONDROUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockBondRoute {
    bool public skip_actual_transfer  =  true;

    function announce_protocol( string calldata, string calldata ) external payable { }

    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context )
    external returns ( uint256 updated_index, uint256 new_available_amount )
    {
        for(  uint i = 0  ;  i < context.fundings.length  ;  i = i + 1  )
        {
            if(  address(context.fundings[ i ].token) == address(token)  )
            {
                uint256 available  =  context.fundings[ i ].amount;
                require( available >= amount, "Insufficient funding" );
                return ( i, available - amount );
            }
        }
        revert( "Token not in fundings" );
    }

    receive( ) external payable { }
}


// ━━━━  TEST BASE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

abstract contract SafeSwapTestBase is Test {
    using PoolIdLibrary for PoolKey;

    SafeSwapRouter public router;
    SafeSwapHook public hook;
    SafeSwapNft public safeswap_nft;
    MockPoolManager public pool_manager;
    MockBondRoute public bond_route;
    MockChainConfig public chain_config;

    MockERC20 public token0;
    MockERC20 public token1;

    address public treasury;
    address public user;
    address public other_user;

    uint8 constant REBATE_PROFILE_50  =  5;     // 50%.
    uint8 constant BASE_FEE_BPS_030   =  30;    // 0.30%.
    int24 constant TICK_SPACING_60    =  60;
    uint256 constant INITIAL_BALANCE  =  1_000_000 ether;

    function setUp( ) public virtual
    {
        vm.roll( 1000 );
        vm.warp( 1000000 );

        treasury    =  makeAddr( "treasury" );
        user        =  makeAddr( "user" );
        other_user  =  makeAddr( "other_user" );

        chain_config  =  new MockChainConfig( );
        pool_manager  =  new MockPoolManager( );
        bond_route    =  new MockBondRoute( );

        vm.etch( CHAINCONFIG_ADDRESS, address(chain_config).code );
        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );

        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, POOL_MANAGER_KEY, address(pool_manager) );
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, INITIAL_TREASURY_KEY, treasury );

        // *NOTE*  -  Router needs the NFT and the NFT needs the router. Predetermine the router's CREATE address: the NFT
        //            deploy consumes the next nonce, so the router lands at the following one.
        uint64 nonce_before_nft  =  vm.getNonce( address(this) );
        address predicted_router  =  vm.computeCreateAddress( address(this), nonce_before_nft + 1 );
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, SAFESWAP_ROUTER_KEY, predicted_router );

        safeswap_nft  =  new SafeSwapNft( );
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( CONFIG_SIGNER, SAFESWAP_NFT_KEY, address(safeswap_nft) );

        router  =  new SafeSwapRouter( );
        require( address(router) == predicted_router, "router address prediction failed" );

        hook  =  _deploy_and_register_hook( REBATE_PROFILE_50 );

        token0  =  new MockERC20( "Token0", "TK0", 18 );
        token1  =  new MockERC20( "Token1", "TK1", 18 );
        if(  address(token0) > address(token1)  )  ( token0, token1 )  =  ( token1, token0 );

        token0.mint( user, INITIAL_BALANCE );
        token1.mint( user, INITIAL_BALANCE );
        token0.mint( address(pool_manager), INITIAL_BALANCE );
        token1.mint( address(pool_manager), INITIAL_BALANCE );
        token0.mint( address(router), 1 );
        token1.mint( address(router), 1 );
    }

    /// @dev Deploy a SafeSwapHook at the crafted address that encodes `profile`, publish its codehash, and register it.
    function _deploy_and_register_hook( uint8 profile ) internal returns ( SafeSwapHook deployed )
    {
        address crafted  =  hook_address_for_profile( profile );
        deployCodeTo( "SafeSwapHook.sol:SafeSwapHook", crafted );
        deployed  =  SafeSwapHook(crafted);

        MockChainConfig(CHAINCONFIG_ADDRESS).set_bytes32( CONFIG_SIGNER, SAFESWAP_HOOK_CODEHASH_KEY, crafted.codehash );

        deployed.initialize_once( );
    }

    function hook_address_for_profile( uint8 profile ) internal pure returns ( address )
    {
        uint160 bits  =  ( uint160(SAFESWAP_HOOK_ADDRESS_MAGIC) << HOOK_ADDRESS_MAGIC_SHIFT )
                         | ( uint160(profile) << HOOK_ADDRESS_REBATE_PROFILE_SHIFT )
                         | REQUIRED_HOOK_PERMISSIONS;
        return address(bits);
    }

    function _default_pool_info( ) internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ base_fee_bps: BASE_FEE_BPS_030, rebate_profile: REBATE_PROFILE_50, tick_spacing: TICK_SPACING_60 });
    }
}
