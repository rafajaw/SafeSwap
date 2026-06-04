// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


/**
 * @title TestERC20
 * @notice A real, standard OpenZeppelin ERC20 with an open `mint` for test setup. Used instead of a behavioral mock so
 *         that allowance / transferFrom semantics (the path real BondRoute funding takes) are exercised faithfully.
 */
contract TestERC20 is ERC20 {

    uint8 private immutable _decimals;

    constructor( string memory name_, string memory symbol_, uint8 decimals_ )
    ERC20( name_, symbol_ )
    {
        _decimals  =  decimals_;
    }

    function decimals( ) public view override returns ( uint8 )
    {
        return _decimals;
    }

    function mint( address to, uint256 amount ) external
    {
        _mint( to, amount );
    }
}
