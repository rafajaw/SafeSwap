// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "@SafeSwap/SafeSwap.sol";
import "@SafeSwap/libraries/SafeSwapCommon.sol";
import "@SafeSwap/libraries/ExactInputSwapLib.sol";
import "@SafeSwap/libraries/ExactOutputSwapLib.sol";
import "@SafeSwap/libraries/AddLiquidityLib.sol";
import "@SafeSwap/libraries/RemoveLiquidityLib.sol";
import { IPoolManager } from "@UniswapV4Core/interfaces/IPoolManager.sol";
import { IHooks } from "@UniswapV4Core/interfaces/IHooks.sol";
import { PoolKey } from "@UniswapV4Core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@UniswapV4Core/types/PoolId.sol";
import { Currency } from "@UniswapV4Core/types/Currency.sol";
import { BalanceDelta, toBalanceDelta } from "@UniswapV4Core/types/BalanceDelta.sol";
import { TickMath } from "@UniswapV4Core/libraries/TickMath.sol";


// ━━━━  MOCK ERC20  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

    function burn( address from, uint256 amount ) external
    {
        balanceOf[ from ]  =  balanceOf[ from ] - amount;
        totalSupply        =  totalSupply - amount;
        emit Transfer( from, address(0), amount );
    }

    function approve( address spender, uint256 value ) external returns ( bool )
    {
        allowance[ msg.sender ][ spender ]  =  value;
        emit Approval( msg.sender, spender, value );
        return true;
    }

    function transfer( address to, uint256 value ) external virtual returns ( bool )
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

    function set_address( address signer, bytes32 key, address value ) external
    {
        addresses[ signer ][ key ]  =  value;
    }

    function read_address( address signer, bytes32 key ) external view returns ( address )
    {
        return addresses[ signer ][ key ];
    }

    function read_address( address signer, string calldata key ) external view returns ( address )
    {
        return addresses[ signer ][ bytes32(bytes(key)) ];
    }
}


// ━━━━  MOCK POOL MANAGER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    address public protocolFeeController;

    struct PoolState {
        uint160 sqrt_price_x96;
        int24 tick;
        uint24 protocol_fee;
        uint24 lp_fee;
        uint128 liquidity;
        bool initialized;
    }

    mapping( PoolId => PoolState ) public pools;
    mapping( Currency => int256 ) public currency_deltas;
    mapping( Currency => uint256 ) public reserves;
    mapping( address => mapping( uint256 => uint256 ) ) public balanceOf;
    mapping( address => mapping( address => bool ) ) public isOperator;
    mapping( address => mapping( address => mapping( uint256 => uint256 ) ) ) public allowance;

    address public unlock_caller;
    bool public is_unlocked;

    int128 public mock_swap_amount0;
    int128 public mock_swap_amount1;
    int128 public mock_liquidity_amount0;
    int128 public mock_liquidity_amount1;

    bytes32 public last_modify_salt;

    event SwapExecuted( PoolId indexed pool_id, bool zero_for_one, int256 amount_specified );
    event LiquidityModified( PoolId indexed pool_id, int256 liquidity_delta );
    event UnlockCalled( address caller, bytes data );

    function initialize_pool( PoolKey memory key, uint160 sqrt_price_x96 ) external returns ( int24 tick )
    {
        PoolId pool_id  =  key.toId( );
        tick  =  TickMath.getTickAtSqrtPrice( sqrt_price_x96 );
        pools[ pool_id ]  =  PoolState({
            sqrt_price_x96: sqrt_price_x96,
            tick: tick,
            protocol_fee: 0,
            lp_fee: key.fee,
            liquidity: 0,
            initialized: true
        });
    }

    function set_mock_swap_amounts( int128 amount0, int128 amount1 ) external
    {
        mock_swap_amount0  =  amount0;
        mock_swap_amount1  =  amount1;
    }

    function set_mock_liquidity_amounts( int128 amount0, int128 amount1 ) external
    {
        mock_liquidity_amount0  =  amount0;
        mock_liquidity_amount1  =  amount1;
    }

    function unlock( bytes calldata data ) external returns ( bytes memory )
    {
        is_unlocked      =  true;
        unlock_caller    =  msg.sender;

        emit UnlockCalled( msg.sender, data );

        bytes memory result  =  IUnlockCallback(msg.sender).unlockCallback( data );

        is_unlocked  =  false;
        return result;
    }

    function swap( PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata )
    external returns ( BalanceDelta delta )
    {
        PoolId pool_id  =  key.toId( );
        emit SwapExecuted( pool_id, params.zeroForOne, params.amountSpecified );
        return toBalanceDelta( mock_swap_amount0, mock_swap_amount1 );
    }

    function modifyLiquidity( PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes calldata )
    external returns ( BalanceDelta delta, BalanceDelta fees_accrued )
    {
        PoolId pool_id  =  key.toId( );
        last_modify_salt  =  params.salt;
        emit LiquidityModified( pool_id, params.liquidityDelta );
        return ( toBalanceDelta( mock_liquidity_amount0, mock_liquidity_amount1 ), toBalanceDelta( 0, 0 ) );
    }

    function sync( Currency currency ) external
    {
        // Record the currency for settlement.
    }

    function settle( ) external payable returns ( uint256 )
    {
        return 0;
    }

    function take( Currency currency, address to, uint256 amount ) external
    {
        address token  =  Currency.unwrap( currency );
        if(  token == address(0)  )
        {
            payable(to).transfer( amount );
        }
        else
        {
            bool success  =  MockERC20(token).transfer( to, amount );
            require( success, "Mock transfer failed" );
        }
    }

    function extsload( bytes32 slot ) external view returns ( bytes32 )
    {
        // Return mock slot0 data for pool state queries.
        // StateLibrary uses specific slot calculations.
        return bytes32(0);
    }

    function extsload( bytes32 start_slot, uint256 n_slots ) external view returns ( bytes memory )
    {
        bytes memory result  =  new bytes( n_slots * 32 );
        return result;
    }

    function extsload( bytes32[] calldata slots ) external view returns ( bytes32[] memory )
    {
        return new bytes32[]( slots.length );
    }

    function get_slot0( PoolId pool_id ) external view returns ( uint160, int24, uint24, uint24 )
    {
        PoolState memory state  =  pools[ pool_id ];
        return ( state.sqrt_price_x96, state.tick, state.protocol_fee, state.lp_fee );
    }

    function supportsInterface( bytes4 interface_id ) external pure returns ( bool )
    {
        return interface_id == 0x01ffc9a7 || interface_id == 0x0f632fb3;
    }

    receive( ) external payable { }
}


// ━━━━  MOCK BONDROUTE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract MockBondRoute {
    event ProtocolAnnounced( string name, string description );
    event FundingTransferred( address to, address token, uint256 amount );

    mapping( address => mapping( IERC20 => uint256 ) ) public user_fundings;
    bool public skip_actual_transfer;

    function announce_protocol( string calldata name, string calldata description ) external payable
    {
        emit ProtocolAnnounced( name, description );
    }

    function set_skip_actual_transfer( bool skip ) external
    {
        skip_actual_transfer  =  skip;
    }

    function transfer_funding( address to, IERC20 token, uint256 amount, BondContext memory context )
    external returns ( uint256 updated_index, uint256 new_available_amount )
    {
        // Find the funding index for this token.
        for(  uint i = 0  ;  i < context.fundings.length  ;  i = i + 1  )
        {
            if(  address(context.fundings[ i ].token) == address(token)  )
            {
                uint256 available  =  context.fundings[ i ].amount;
                require( available >= amount, "Insufficient funding" );

                // Skip actual transfer in test mode - just track the accounting.
                if(  skip_actual_transfer == false  )
                {
                    if(  address(token) == address(0)  )
                    {
                        payable(to).transfer( amount );
                    }
                    else
                    {
                        bool success  =  token.transferFrom( context.user, to, amount );
                        require( success, "Mock funding transfer failed" );
                    }
                }

                emit FundingTransferred( to, address(token), amount );
                return ( i, available - amount );
            }
        }
        revert( "Token not in fundings" );
    }

    function set_user_funding( address user, IERC20 token, uint256 amount ) external
    {
        user_fundings[ user ][ token ]  =  amount;
    }

    receive( ) external payable { }
}


// ━━━━  FAILING ERC20 (for testing transfer failures)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract FailingERC20 is MockERC20 {
    bool public should_fail_transfer;

    constructor( ) MockERC20( "Failing", "FAIL", 18 ) { }

    function set_should_fail( bool _should_fail ) external
    {
        should_fail_transfer  =  _should_fail;
    }

    function transfer( address to, uint256 value ) external override returns ( bool )
    {
        if(  should_fail_transfer  )  return false;
        balanceOf[ msg.sender ]  =  balanceOf[ msg.sender ] - value;
        balanceOf[ to ]          =  balanceOf[ to ] + value;
        emit Transfer( msg.sender, to, value );
        return true;
    }
}


// ━━━━  REJECTING RECIPIENT (for testing native transfer failures)  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

contract RejectingRecipient {
    receive( ) external payable
    {
        revert( "I reject ETH" );
    }
}


// ━━━━  TESTABLE SAFESWAPHOOK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// @dev Wrapper that bypasses BondRoute for direct testing.
contract TestableSafeSwap is SafeSwap {

    bool private _bypass_bondroute;
    BondContext private _mock_context;

    constructor( address initial_collector ) SafeSwap( initial_collector ) { }

    function set_bypass_bondroute( bool bypass ) external
    {
        _bypass_bondroute  =  bypass;
    }

    function set_mock_context( BondContext memory context ) external
    {
        _mock_context  =  context;
    }

    function get_mock_context( ) external view returns ( BondContext memory )
    {
        return _mock_context;
    }

    function test_set_protected_context( bool is_protected ) external
    {
        _set_protected_context( is_protected );
    }

    function test_is_within_protected_context( ) external view returns ( bool )
    {
        return _is_within_protected_context( );
    }

    function test_execute_exact_input_swap( BondContext memory context, ExactInputSwapParams memory params ) external
    {
        _set_protected_context( true );
        ExactInputSwapLib.execute( context, params, PoolManager, address(this) );
        _set_protected_context( false );
    }

    function test_execute_exact_output_swap( BondContext memory context, ExactOutputSwapParams memory params ) external
    {
        _set_protected_context( true );
        ExactOutputSwapLib.execute( context, params, PoolManager, address(this) );
        _set_protected_context( false );
    }

    function test_execute_add_liquidity( BondContext memory context, AddLiquidityParams memory params ) external
    {
        _set_protected_context( true );
        AddLiquidityLib.execute( context, params, PoolManager, address(this) );
        _set_protected_context( false );
    }

    function test_execute_remove_liquidity( BondContext memory context, RemoveLiquidityParams memory params ) external
    {
        _set_protected_context( true );
        RemoveLiquidityLib.execute( context, params, PoolManager, address(this) );
        _set_protected_context( false );
    }

    function test_build_pool_key( IERC20 token_in, IERC20 token_out, uint24 fee, int24 tick_spacing )
    external view returns ( PoolKey memory )
    {
        return SafeSwapCommon.build_pool_key( token_in, token_out, fee, tick_spacing, address(this) );
    }

    function test_calculate_swap_stake( IERC20 token, uint256 amount )
    external pure returns ( TokenAmount memory )
    {
        return SafeSwapCommon.calculate_swap_stake( token, amount );
    }

    function test_calculate_liquidity_stake( IERC20 token, uint256 amount )
    external pure returns ( TokenAmount memory )
    {
        return SafeSwapCommon.calculate_liquidity_stake( token, amount );
    }

    function test_position_salt( address _user, bytes32 salt )
    external pure returns ( bytes32 )
    {
        return SafeSwapCommon._position_salt( _user, salt );
    }
}


// ━━━━  TEST BASE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

abstract contract SafeSwapTestBase is Test {
    using PoolIdLibrary for PoolKey;

    // Contracts.
    TestableSafeSwap public hook;
    MockPoolManager public pool_manager;
    MockBondRoute public bond_route;
    MockChainConfig public chain_config;

    // Tokens.
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;
    FailingERC20 public failing_token;

    // Addresses.
    address public collector;
    address public user;
    address public other_user;
    address public treasury;

    // Constants.
    uint24 constant POOL_FEE_030       =  3000;    // 0.30%.
    uint24 constant POOL_FEE_005       =  500;     // 0.05%.
    uint24 constant POOL_FEE_001       =  100;     // 0.01%.
    uint24 constant POOL_FEE_100       =  10000;   // 1.00%.
    int24 constant TICK_SPACING_60     =  60;
    int24 constant TICK_SPACING_10     =  10;
    uint160 constant SQRT_PRICE_1_1    =  79228162514264337593543950336;  // 1:1 price.
    uint256 constant INITIAL_BALANCE   =  1_000_000 ether;

    address constant CHAINCONFIG_ADDRESS  =  0x5Afec0de00EB1c5323C7faA110f67499F744467b;
    bytes32 constant POOL_MANAGER_KEY     =  bytes32("v4.pool_manager.address");

    function setUp( ) public virtual
    {
        // Set block number and timestamp to sensible values.
        vm.roll( 1000 );
        vm.warp( 1000000 );

        // Create addresses.
        collector   =  makeAddr( "collector" );
        user        =  makeAddr( "user" );
        other_user  =  makeAddr( "other_user" );
        treasury    =  makeAddr( "treasury" );

        // Deploy mocks.
        chain_config   =  new MockChainConfig( );
        pool_manager   =  new MockPoolManager( );
        bond_route     =  new MockBondRoute( );

        // Deploy mock code at expected addresses.
        vm.etch( CHAINCONFIG_ADDRESS, address(chain_config).code );
        vm.etch( BONDROUTE_ADDRESS, address(bond_route).code );

        // Set pool manager in ChainConfig.
        MockChainConfig(CHAINCONFIG_ADDRESS).set_address( collector, POOL_MANAGER_KEY, address(pool_manager) );

        // Set skip_actual_transfer to true on the etched BondRoute.
        MockBondRoute(payable(BONDROUTE_ADDRESS)).set_skip_actual_transfer( true );

        // Deploy tokens - ensure token0 < token1 for proper ordering.
        token0         =  new MockERC20( "Token0", "TK0", 18 );
        token1         =  new MockERC20( "Token1", "TK1", 18 );
        token2         =  new MockERC20( "Token2", "TK2", 18 );
        failing_token  =  new FailingERC20( );

        // Ensure token0 < token1.
        if(  address(token0) > address(token1)  )
        {
            ( token0, token1 )  =  ( token1, token0 );
        }

        // Deploy hook.
        vm.prank( collector );
        hook  =  new TestableSafeSwap( collector );

        // Initialize pool in mock pool manager.
        PoolKey memory pool_key  =  PoolKey({
            currency0: Currency.wrap( address(token0) ),
            currency1: Currency.wrap( address(token1) ),
            fee: POOL_FEE_030,
            tickSpacing: TICK_SPACING_60,
            hooks: IHooks(address(hook))
        });
        pool_manager.initialize_pool( pool_key, SQRT_PRICE_1_1 );

        // Mint tokens to users.
        token0.mint( user, INITIAL_BALANCE );
        token1.mint( user, INITIAL_BALANCE );
        token0.mint( other_user, INITIAL_BALANCE );
        token1.mint( other_user, INITIAL_BALANCE );
        token0.mint( address(pool_manager), INITIAL_BALANCE );
        token1.mint( address(pool_manager), INITIAL_BALANCE );

        // Mint dust to addresses that start at 0 to avoid 0→nonzero SSTORE costs.
        token0.mint( address(hook), 1 );
        token1.mint( address(hook), 1 );
        token0.mint( treasury, 1 );
        token1.mint( treasury, 1 );

        // Approve hook to spend tokens.
        vm.startPrank( user );
        token0.approve( address(hook), type(uint256).max );
        token1.approve( address(hook), type(uint256).max );
        token0.approve( address(bond_route), type(uint256).max );
        token1.approve( address(bond_route), type(uint256).max );
        vm.stopPrank( );

        // Fund pool manager with ETH.
        vm.deal( address(pool_manager), 100 ether );
    }

    function _create_bond_context( address _user, uint256 amount ) internal view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[]( 1 );
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount });

        return BondContext({
            user: _user,
            stake: TokenAmount({ token: token0, amount: amount / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }

    function _create_bond_context_two_fundings( address _user, uint256 amount0, uint256 amount1 )
    internal view returns ( BondContext memory )
    {
        TokenAmount[] memory fundings  =  new TokenAmount[]( 2 );
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount0 });
        fundings[ 1 ]  =  TokenAmount({ token: token1, amount: amount1 });

        return BondContext({
            user: _user,
            stake: TokenAmount({ token: token0, amount: amount0 / 100 }),
            fundings: fundings,
            creation_block: block.number - 5,
            creation_timestamp: block.timestamp - 1 hours
        });
    }

    function _create_exact_input_params( uint256 min_out )
    internal view returns ( ExactInputSwapParams memory )
    {
        return ExactInputSwapParams({
            token_out: token1,
            minimum_amount_out: min_out,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
    }

    function _create_exact_output_params( uint256 amount_out )
    internal view returns ( ExactOutputSwapParams memory )
    {
        return ExactOutputSwapParams({
            token_out: token1,
            amount_out: amount_out,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 })
        });
    }

    function _create_add_liquidity_params( )
    internal pure returns ( AddLiquidityParams memory )
    {
        return AddLiquidityParams({
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            amount0_min: 0,
            amount1_min: 0,
            salt: bytes32(0)
        });
    }

    function _create_remove_liquidity_params( uint128 liquidity )
    internal view returns ( RemoveLiquidityParams memory )
    {
        return RemoveLiquidityParams({
            token0: token0,
            token1: token1,
            pool_info: PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 }),
            tick_lower: -TICK_SPACING_60 * 10,
            tick_upper: TICK_SPACING_60 * 10,
            liquidity: liquidity,
            amount0_min: 0,
            amount1_min: 0,
            salt: bytes32(0)
        });
    }

    function _create_swap_fundings( uint256 amount_in )
    internal view returns ( TokenAmount[] memory fundings )
    {
        fundings       =  new TokenAmount[](1);
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount_in });
    }

    function _create_liquidity_fundings( uint256 amount0, uint256 amount1 )
    internal view returns ( TokenAmount[] memory fundings )
    {
        fundings       =  new TokenAmount[](2);
        fundings[ 0 ]  =  TokenAmount({ token: token0, amount: amount0 });
        fundings[ 1 ]  =  TokenAmount({ token: token1, amount: amount1 });
    }

    function _default_pool_info( )
    internal pure returns ( PoolInfo memory )
    {
        return PoolInfo({ fee: POOL_FEE_030, tick_spacing: TICK_SPACING_60 });
    }

    function _encode_exact_input_calldata( ExactInputSwapParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.swap_exact_input.selector, params );
    }

    function _encode_exact_output_calldata( ExactOutputSwapParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.swap_exact_output.selector, params );
    }

    function _encode_add_liquidity_calldata( AddLiquidityParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.add_liquidity.selector, params );
    }

    function _encode_remove_liquidity_calldata( RemoveLiquidityParams memory params )
    internal view returns ( bytes memory )
    {
        return abi.encodeWithSelector( hook.remove_liquidity.selector, params );
    }
}
