// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ███████╗ █████╗ ███████╗███████╗███████╗██╗    ██╗ █████╗ ██████╗
        ██╔════╝██╔══██╗██╔════╝██╔════╝██╔════╝██║    ██║██╔══██╗██╔══██╗
        ███████╗███████║█████╗  █████╗  ███████╗██║ █╗ ██║███████║██████╔╝
        ╚════██║██╔══██║██╔══╝  ██╔══╝  ╚════██║██║███╗██║██╔══██║██╔═══╝
        ███████║██║  ██║██║     ███████╗███████║╚███╔███╔╝██║  ██║██║
        ╚══════╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝
        ━━━━━━━━━  Gasless, MEV-protected swaps and liquidity.  ━━━━━━━━━

*/

import { ExecutionData } from "@BondRoute/Core.sol";
import { IERC20, TokenAmount, NATIVE_TOKEN, BONDROUTE_ADDRESS } from "@BondRouteProtected/BondRouteProtected.sol";
import { SafeTransferLib } from "@Solady/utils/SafeTransferLib.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ChainConfig } from "@ChainConfig/IChainConfig.sol";
import { CONFIG_SIGNER, SAFESWAP_ROUTER_KEY, SAFESWAP_NFT_KEY } from "@SafeSwapCommon/Definitions.sol";


// ━━━━  ERRORS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

error OnlyDelegatedExecution( address called_on );
error UnauthorizedRelayer( address caller, address expected );
error WrongHelper( address provided, address expected );
error UnsupportedProtocol( address protocol, address safe_swap_router, address safe_swap_nft );
error CreateDeadlineExpired( uint256 deadline, uint256 current_time );
error InvalidGaslessSignature( address recovered, address expected );
error UnexpectedNativeValue( uint256 sent );
error CommitmentMismatch( bytes32 expected, bytes32 actual );
error StakeMismatch( address expected_token, uint256 expected_amount, address actual_token, uint256 actual_amount );
error SigningInfoUnavailable( address protocol );
error GaslessTypeHashMismatch( bytes32 expected, bytes32 actual );
error ActionStructHashMismatch( bytes32 expected, bytes32 actual );
error InvalidProtocolTypedStringPrefix( bytes32 expected_prefix_hash, bytes32 provided_string_hash );


// ━━━━  SIGNED DATA  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @notice The single off-chain authorization the user signs for one gasless SafeSwap operation. It is an EIP-712 struct under
 *         this delegate's own "SafeSwap Gasless" domain — NOT BondRoute's `ExecuteBondAs` envelope (see the contract NatSpec
 *         for why the binding is relocated here). The trailing protocol action (the human-readable swap / liquidity intent)
 *         is appended to this struct's type so the wallet still renders it; on-chain it is carried as `action_struct_hash`.
 *
 * @dev    `helper` pins the signature to this exact delegate; `relayer` pins which relayer may submit; `relayer_fee` is the
 *         on-chain payment to that relayer; `stake` mirrors the bond stake; `create_deadline` bounds the commit; and
 *         `commitment_hash` is the BondRoute commitment this intent authorizes — the field that re-binds the full execution.
 */
struct SafeSwapGaslessBond {
    address helper;
    address relayer;
    TokenAmount relayer_fee;
    TokenAmount stake;
    uint256 create_deadline;
    bytes32 commitment_hash;
}


// ━━━━  DELEGATE  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * @title SafeSwap7702Delegate
 * @notice EIP-7702 delegate for gasless SafeSwap execution. A relayer pays the gas; the user only signs. The user's EOA
 *         delegates to this code (7702 style), so every line below runs *as the user's own account*: it stakes the user's
 *         own tokens, pays the relayer its signed fee, and drives the bond through BondRoute — all from the EOA, which is
 *         why the bond is created and executed with the plain (msg.sender-owned) `create_bond` / `execute_bond`, not the
 *         third-party `execute_bond_as`.
 *
 *         *TWO PHASES.*  The relayer submits two type-0x04 transactions against the user's EOA: first
 *         `create_bond_from_user_stake` (hidden commit), then — after BondRoute's reveal delay — `execute_bond_from_user`.
 *         The one `SafeSwapGaslessBond` signature authorizes both.
 *
 *         *WHY THE SIGNATURE IS SAFE FOR A USER-STAKING CREATE.*  An earlier design rejected a delegate that staked the
 *         user's funds because it would have reused BondRoute's `execute_bond_as` signature, which binds fundings/call via
 *         their EIP-712 hashes while the commitment binds them via different (plain) hashes — leaving the commitment's
 *         hashes unsigned, so a griefer could lock the user's stake into an unexecutable bond. This delegate instead gates
 *         on a *dedicated* `SafeSwapGaslessBond` signature taken over the `commitment_hash` itself. At execute time
 *         `_validate_execution_data_matches_intent` recomputes the commitment from the revealed `ExecutionData` and asserts
 *         equality, so the full execution is provably the signed commitment's preimage — closing the griefing surface.
 *
 *         *SIGNATURE SCHEME.*  The intent is recovered against `address(this)` (the EOA) via ECDSA, never EIP-1271: only an
 *         EOA can author a 7702 authorization, and an EIP-1271 callback would re-enter this delegate, which exposes no
 *         `isValidSignature`. The delegate also validates the protocol on-chain (router/NFT only) and that the submitter is
 *         the signed `relayer`.
 */
contract SafeSwap7702Delegate is EIP712 {

    using SafeTransferLib for address;

    uint256 constant INFINITE_TOKEN_AMOUNT  =  type(uint256).max;

    bytes32 constant TOKEN_AMOUNT_TYPE_HASH  =  keccak256( "TokenAmount(address token,uint256 amount)" );

    /// @dev The exact leading run of BondRoute's `ExecuteBondAs` type string, stripped before re-parenting the action tail.
    string constant BONDROUTE_SIGNING_PREFIX  =  "ExecuteBondAs(TokenAmount[] fundings,TokenAmount stake,uint256 salt,address protocol,";

    /// @dev This delegate's own leading struct fields, spliced in front of the protocol action tail to form the signed type.
    string constant SAFESWAP_GASLESS_PREFIX  =
        "SafeSwapGaslessBond(address helper,address relayer,TokenAmount relayer_fee,TokenAmount stake,uint256 create_deadline,bytes32 commitment_hash,";

    /**
     * @dev This contract's own deployed address, captured at construction and baked into the runtime bytecode (immutable).
     *      Under 7702 delegation the code runs *as the user's EOA*, so `address(this)` is that EOA and never equals this
     *      value — the inequality is precisely what proves we are executing as a delegate rather than being called directly
     *      on the deployed artifact.
     */
    address private immutable THIS_DELEGATE;

    /// @dev The only two protocols this delegate will drive, resolved from ChainConfig at deploy (canonical SafeSwap source,
    ///      same as the router/NFT read their own dependencies). Checked on-chain against `execution_data.protocol`.
    address public immutable SafeSwapRouter;
    address public immutable SafeSwapNft;

    constructor( )
    EIP712( "SafeSwap Gasless", "1" )
    {
        THIS_DELEGATE     =  address(this);
        SafeSwapRouter  =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_ROUTER_KEY );
        SafeSwapNft     =  ChainConfig.read_address( CONFIG_SIGNER, SAFESWAP_NFT_KEY );
    }

    /**
     * @notice Accept native value released back to the user's EOA mid-execution — a native-output swap, a remove/collect
     *         payout, or a stake/refund return at settlement — which arrives as an empty-calldata value transfer. Without
     *         this the payout (and the whole execution) would revert, and the delegated account would bounce ordinary ETH
     *         while the 7702 delegation persists.
     *
     * @dev    *SECURITY*  -  `receive()` only, no payable `fallback()`: native payouts use empty calldata, so this keeps the
     *                        "no arbitrary call surface" property.
     */
    receive( ) external payable { }

    /**
     * @notice Phase 1 — create the hidden BondRoute commitment, staking the user's own tokens and paying the relayer fee.
     * @param intent             The signed gasless authorization (binds helper, relayer, fee, stake, deadline, commitment).
     * @param gasless_type_hash  keccak of the spliced `SafeSwapGaslessBond(...)` type string (re-derived and checked).
     * @param action_struct_hash The protocol action's EIP-712 struct hash (re-derived and checked at execute).
     * @param signature          The user's ECDSA signature over `intent` under this delegate's domain.
     */
    function create_bond_from_user_stake(
        SafeSwapGaslessBond calldata intent,
        bytes32 gasless_type_hash,
        bytes32 action_struct_hash,
        bytes calldata signature
    )
    external  payable
    {
        _require_no_native_value( );
        _require_delegated_context( );
        _validate_create_authorization( intent, gasless_type_hash, action_struct_hash, signature );

        _pay_relayer_fee( intent.relayer_fee, intent.relayer );
        _approve_max_to_bond_route( intent.stake.token );

        IBondRouteSingleton( BONDROUTE_ADDRESS ).create_bond{ value: _calculate_native_amount( intent.stake ) }({
            commitment_hash:  intent.commitment_hash,
            stake:            intent.stake
        });
    }

    /**
     * @notice Phase 2 — reveal and execute the bond after BondRoute's delay. All fundings, refunds, and protocol output
     *         flow to the user's EOA (this account).
     * @param intent             The same signed authorization used at create.
     * @param gasless_type_hash  keccak of the spliced type string (re-derived and checked).
     * @param action_struct_hash The protocol action's struct hash (re-derived and checked against the revealed call).
     * @param signature          The user's signature over `intent`.
     * @param execution_data     The revealed execution; its commitment must equal `intent.commitment_hash`.
     */
    function execute_bond_from_user(
        SafeSwapGaslessBond calldata intent,
        bytes32 gasless_type_hash,
        bytes32 action_struct_hash,
        bytes calldata signature,
        ExecutionData calldata execution_data
    )
    external  payable  returns ( uint8 status, bytes memory output )
    {
        _require_no_native_value( );
        _require_delegated_context( );
        _validate_common_authorization( intent, gasless_type_hash, action_struct_hash, signature );
        _validate_execution_data_matches_intent( intent, gasless_type_hash, action_struct_hash, execution_data );

        for(  uint256 i = 0  ;  i < execution_data.fundings.length  ;  i++  )
        {
            _approve_max_to_bond_route( execution_data.fundings[ i ].token );
        }

        return IBondRouteSingleton( BONDROUTE_ADDRESS ).execute_bond{ value: _calculate_native_funding_amount( execution_data.fundings ) }( execution_data );
    }


    // ━━━━  AUTHORIZATION  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _validate_create_authorization(
        SafeSwapGaslessBond calldata intent,
        bytes32 gasless_type_hash,
        bytes32 action_struct_hash,
        bytes calldata signature
    ) private view
    {
        _validate_common_authorization( intent, gasless_type_hash, action_struct_hash, signature );

        if(  block.timestamp > intent.create_deadline  )    // forge-lint: disable-line(block-timestamp)
        {
            revert CreateDeadlineExpired({ deadline: intent.create_deadline, current_time: block.timestamp });
        }
    }

    function _validate_common_authorization(
        SafeSwapGaslessBond calldata intent,
        bytes32 gasless_type_hash,
        bytes32 action_struct_hash,
        bytes calldata signature
    ) private view
    {
        if(  intent.helper != THIS_DELEGATE  )  revert WrongHelper({ provided: intent.helper, expected: THIS_DELEGATE });
        if(  msg.sender != intent.relayer  )            revert UnauthorizedRelayer({ caller: msg.sender, expected: intent.relayer });

        bytes32 digest     =  _hashTypedDataV4( _hash_gasless_intent( intent, gasless_type_hash, action_struct_hash ) );
        address recovered  =  ECDSA.recover( digest, signature );

        if(  recovered != address(this)  )  revert InvalidGaslessSignature({ recovered: recovered, expected: address(this) });
    }

    function _validate_execution_data_matches_intent(
        SafeSwapGaslessBond calldata intent,
        bytes32 gasless_type_hash,
        bytes32 action_struct_hash,
        ExecutionData calldata execution_data
    ) private view
    {
        _validate_supported_protocol( address(execution_data.protocol) );

        bytes32 actual_commitment_hash  =  IBondRouteSingleton( BONDROUTE_ADDRESS ).__OFF_CHAIN__calc_commitment_hash({
            user:            address(this),
            execution_data:  execution_data
        });

        if(  actual_commitment_hash != intent.commitment_hash  )
        {
            revert CommitmentMismatch({ expected: intent.commitment_hash, actual: actual_commitment_hash });
        }

        if(  address(execution_data.stake.token) != address(intent.stake.token)  ||  execution_data.stake.amount != intent.stake.amount  )
        {
            revert StakeMismatch({
                expected_token:   address(intent.stake.token),
                expected_amount:  intent.stake.amount,
                actual_token:     address(execution_data.stake.token),
                actual_amount:    execution_data.stake.amount
            });
        }

        ( string memory protocol_typed_string, bytes32 actual_action_struct_hash )  =  _get_protocol_signing_info({
            protocol:  address(execution_data.protocol),
            call:      execution_data.call
        });

        bytes32 expected_gasless_type_hash  =  _calculate_gasless_type_hash( protocol_typed_string );

        if(  expected_gasless_type_hash != gasless_type_hash  )
        {
            revert GaslessTypeHashMismatch({ expected: expected_gasless_type_hash, actual: gasless_type_hash });
        }

        if(  actual_action_struct_hash != action_struct_hash  )
        {
            revert ActionStructHashMismatch({ expected: actual_action_struct_hash, actual: action_struct_hash });
        }
    }

    function _validate_supported_protocol( address protocol ) private view
    {
        if(  protocol == SafeSwapRouter  )  return;
        if(  protocol == SafeSwapNft  )     return;

        revert UnsupportedProtocol({ protocol: protocol, safe_swap_router: SafeSwapRouter, safe_swap_nft: SafeSwapNft });
    }

    /// @dev Revert unless running as a 7702-delegated EOA, not a direct call on the deployed artifact (see `THIS_DELEGATE`).
    function _require_delegated_context( ) private view
    {
        if(  address(this) == THIS_DELEGATE  )  revert OnlyDelegatedExecution({ called_on: address(this) });
    }

    /// @dev The relayer attaches no value; native stake/fundings are paid from the EOA's own balance via `{ value: ... }`.
    function _require_no_native_value( ) private view
    {
        if(  msg.value > 0  )  revert UnexpectedNativeValue({ sent: msg.value });
    }


    // ━━━━  EIP-712  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /**
     * @dev Hash the `SafeSwapGaslessBond` struct. The trailing protocol action appears in the type string (so the wallet
     *      renders it) but is carried here as its precomputed `action_struct_hash`, exactly how EIP-712 encodes a nested
     *      struct field — so this matches a wallet that hashes the full decoded intent.
     */
    function _hash_gasless_intent(
        SafeSwapGaslessBond calldata intent,
        bytes32 gasless_type_hash,
        bytes32 action_struct_hash
    ) private pure returns ( bytes32 )
    {
        return keccak256(
            abi.encode(
                gasless_type_hash,
                intent.helper,
                intent.relayer,
                _hash_token_amount( intent.relayer_fee ),
                _hash_token_amount( intent.stake ),
                intent.create_deadline,
                intent.commitment_hash,
                action_struct_hash
            )
        );
    }

    function _hash_token_amount( TokenAmount calldata token_amount ) private pure returns ( bytes32 )
    {
        return keccak256( abi.encode( TOKEN_AMOUNT_TYPE_HASH, address(token_amount.token), token_amount.amount ) );
    }


    // ━━━━  PROTOCOL SIGNING CHECK  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _get_protocol_signing_info( address protocol, bytes calldata call ) private view returns ( string memory typed_string, bytes32 action_struct_hash )
    {
        try IBondRouteProtectedSigning( protocol ).BondRoute_get_signing_info( call ) returns (
            string memory returned_typed_string,
            bytes32 returned_struct_hash,
            uint256
        )
        {
            if(  bytes(returned_typed_string).length == 0  )  revert SigningInfoUnavailable({ protocol: protocol });

            typed_string         =  returned_typed_string;
            action_struct_hash  =  returned_struct_hash;
        }
        catch
        {
            revert SigningInfoUnavailable({ protocol: protocol });
        }
    }

    /**
     * @dev Build the signed `gasless_type_hash` from the protocol's `ExecuteBondAs` type string: validate it starts with the
     *      canonical BondRoute prefix, strip that prefix, and re-parent the remaining action tail under the SafeSwap gasless
     *      struct prefix. Reverts if the protocol string does not carry the expected prefix.
     */
    function _calculate_gasless_type_hash( string memory protocol_typed_string ) internal pure returns ( bytes32 )
    {
        bytes memory protocol_typed_string_bytes  =  bytes( protocol_typed_string );
        bytes memory bondroute_prefix_bytes       =  bytes( BONDROUTE_SIGNING_PREFIX );
        bytes memory gasless_prefix_bytes         =  bytes( SAFESWAP_GASLESS_PREFIX );

        bool has_valid_prefix  =  _starts_with( protocol_typed_string_bytes, bondroute_prefix_bytes );

        if(  has_valid_prefix == false  )
        {
            revert InvalidProtocolTypedStringPrefix({
                expected_prefix_hash:  keccak256( bondroute_prefix_bytes ),
                provided_string_hash:  keccak256( protocol_typed_string_bytes )
            });
        }

        // Assemble `SAFESWAP_GASLESS_PREFIX ++ <action tail>` in one buffer: copy the gasless prefix to the front, then copy
        // the protocol string's bytes that follow the BondRoute prefix straight after it — a single allocation and two MCOPYs,
        // no per-char loop and no intermediate `string.concat`.
        uint256 bondroute_prefix_length  =  bondroute_prefix_bytes.length;
        uint256 gasless_prefix_length    =  gasless_prefix_bytes.length;
        uint256 tail_length              =  protocol_typed_string_bytes.length - bondroute_prefix_length;

        bytes memory spliced  =  new bytes( gasless_prefix_length + tail_length );

        assembly ("memory-safe") {
            mcopy( add( spliced, 0x20 ), add( gasless_prefix_bytes, 0x20 ), gasless_prefix_length )
            mcopy(
                add( add( spliced, 0x20 ), gasless_prefix_length ),
                add( add( protocol_typed_string_bytes, 0x20 ), bondroute_prefix_length ),
                tail_length
            )
        }

        return keccak256( spliced );
    }

    function _starts_with( bytes memory subject, bytes memory prefix ) private pure returns ( bool )
    {
        if(  subject.length < prefix.length  )  return false;

        for(  uint256 i = 0  ;  i < prefix.length  ;  i++  )
        {
            if(  subject[ i ] != prefix[ i ]  )  return false;
        }

        return true;
    }


    // ━━━━  VALUE MOVEMENT  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function _pay_relayer_fee( TokenAmount calldata relayer_fee, address relayer ) private
    {
        if(  relayer_fee.amount == 0  )  return;

        if(  _is_native( relayer_fee.token )  )
        {
            SafeTransferLib.safeTransferETH( relayer, relayer_fee.amount );
            return;
        }

        address(relayer_fee.token).safeTransfer( relayer, relayer_fee.amount );
    }

    /**
     * @dev Set an infinite BondRoute allowance. `safeApproveWithRetry` resets to zero first and retries for tokens (e.g.
     *      USDT) that forbid overwriting a non-zero allowance. Native token needs no allowance.
     */
    function _approve_max_to_bond_route( IERC20 token ) private
    {
        if(  _is_native( token )  )  return;

        address(token).safeApproveWithRetry( BONDROUTE_ADDRESS, INFINITE_TOKEN_AMOUNT );
    }

    function _calculate_native_amount( TokenAmount calldata token_amount ) private pure returns ( uint256 )
    {
        if(  _is_native( token_amount.token )  )  return token_amount.amount;

        return 0;
    }

    function _calculate_native_funding_amount( TokenAmount[] calldata fundings ) private pure returns ( uint256 native_funding_amount )
    {
        native_funding_amount  =  0;

        for(  uint256 i = 0  ;  i < fundings.length  ;  i++  )
        {
            if(  _is_native( fundings[ i ].token )  )  native_funding_amount += fundings[ i ].amount;
        }
    }

    function _is_native( IERC20 token ) private pure returns ( bool )
    {
        return address(token) == address(NATIVE_TOKEN);
    }
}


// ━━━━  INTERFACES  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

interface IBondRouteSingleton {

    function create_bond( bytes32 commitment_hash, TokenAmount calldata stake )
    external  payable;

    function execute_bond( ExecutionData calldata execution_data )
    external  payable  returns ( uint8 status, bytes memory output );

    function __OFF_CHAIN__calc_commitment_hash( address user, ExecutionData calldata execution_data )
    external view returns ( bytes32 commitment_hash );

}

interface IBondRouteProtectedSigning {

    function BondRoute_get_signing_info( bytes calldata call )
    external view returns ( string memory typed_string, bytes32 struct_hash, uint256 TokenAmount_offset );

}
