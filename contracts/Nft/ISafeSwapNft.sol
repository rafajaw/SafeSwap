// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC721 } from "@OpenZeppelin/token/ERC721/IERC721.sol";
import { SafeSwapPositionInfo } from "@SafeSwapCommon/Types.sol";


interface ISafeSwapNft is IERC721 {
    function get_lp_position( uint256 token_id ) external view returns ( SafeSwapPositionInfo memory position_info );
}
