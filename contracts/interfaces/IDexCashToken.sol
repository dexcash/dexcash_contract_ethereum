// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./IERC20.sol";

interface IDexCashToken is IERC20 {
    event OwnerChanged(address);

    function owner()external view returns (address);
    function newOwner()external view returns (address);
    function changeOwner(address ownerToSet) external;
    function updateOwner() external;

    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);
    function multiTransfer(uint256[] calldata mixedAddrVal) external returns (bool);
}
