// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IDexCashBuyback {
    event BurnDXCH(uint256 burntAmt);

    function dxch() external pure returns (address);
    function router() external pure returns (address);
    function factory() external pure returns (address);

    function addMainToken(address token) external;
    function removeMainToken(address token) external;
    function isMainToken(address token) external view returns (bool);
    function mainTokens() external view returns (address[] memory list);

    function withdrawReserves(address[] calldata pairs) external;
    function swapForMainToken(address[] calldata pairs) external;
    function swapForDXCHAndBurn(address[] calldata pairs) external;
}
