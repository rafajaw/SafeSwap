// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC721 } from "@OpenZeppelin/token/ERC721/IERC721.sol";
import { SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";
import { CollectFeesParams } from "@SafeSwapNft/libraries/ModifyLiquidityLib.sol";


interface ISafeSwapNft is IERC721 {
    function collect_fees( CollectFeesParams calldata params ) external;
    function get_lp_position( uint256 token_id ) external view returns ( SafeSwapPositionInfo memory position_info );
    function get_lp_fee_totals( uint256 token_id ) external view returns ( uint256 earned0, uint256 earned1 );
}
