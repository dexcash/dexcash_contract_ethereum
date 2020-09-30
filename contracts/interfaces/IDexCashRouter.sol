// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IDexCashRouter {
    function factory() external pure returns (address);

    function marketOrder(
        address token,
        uint amountIn,
        uint amountOutMin,
        address pair,
        uint deadline
    ) external payable;

    function limitOrder(
        address pair,
        uint info,
        uint deadline
    ) external payable;
}
