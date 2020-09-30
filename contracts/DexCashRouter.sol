// SPDX-License-Identifier: GPL
pragma solidity 0.6.12;

import "./interfaces/IDexCashRouter.sol";
import "./interfaces/IDexCashFactory.sol";
import "./interfaces/IDexCashPair.sol";
import "./interfaces/IERC20.sol";
import "./libraries/SafeMath256.sol";
import "./libraries/DecFloat32.sol";


contract DexCashRouter is IDexCashRouter {
    using SafeMath256 for uint;
    address public immutable override factory;

    modifier ensure(uint deadline) {
        // solhint-disable-next-line not-rely-on-time,
        require(deadline >= block.timestamp, "DexCashRouter: EXPIRED");
        _;
    }

    constructor(address _factory) public {
        factory = _factory;
    }

    //function addMarketOrder(uint[3] calldata stock_money_to, bytes calldata data,
    //                        address inputToken, address sender, uint112 inAmount) external payable override lock returns (uint) {

    function marketOrder(address token, uint amountIn, uint amountOutMin, address pair,
        uint deadline) external payable override ensure(deadline) {

        if (token != address(0)) { require(msg.value == 0, 'DexCashRouter: NOT_ENTER_ETH_VALUE'); }
        // ensure pair exist
        _getTokensFromPair(pair);
        _safeTransferFrom(token, msg.sender, pair, amountIn);
	uint[3] memory uselessData;
        uint amount = IDexCashPair(pair).addMarketOrder(uselessData, bytes(""), token, msg.sender, uint112(amountIn));
        require(amount >= amountOutMin, "DexCashRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    }

    //function addLimitOrder(uint[3] calldata stock_money_to, bytes calldata data,
    //    		   address sender, uint otherInfo) external payable override lock {
    function limitOrder(address pair, uint info, uint deadline) external payable override ensure(deadline) {

        (address stock, address money) = _getTokensFromPair(pair);
	bool isBuy = (info&1)!=0;
	uint64 amount = uint64(info>>8);
	uint32 price32 = uint32(info>>(8+64));
        (uint _stockAmount, uint _moneyAmount) = IDexCashPair(pair).calcStockAndMoney(amount, price32);
        if (isBuy) {
            if (money != address(0)) { require(msg.value == 0, 'DexCashRouter: NOT_ENTER_ETH_VALUE'); }
            _safeTransferFrom(money, msg.sender, pair, _moneyAmount);
        } else {
            if (stock != address(0)) { require(msg.value == 0, 'DexCashRouter: NOT_ENTER_ETH_VALUE'); }
            _safeTransferFrom(stock, msg.sender, pair, _stockAmount);
        }
	uint[3] memory uselessData;
        IDexCashPair(pair).addLimitOrder(uselessData, bytes(""), msg.sender, info);
    }

    function _safeTransferFrom(address token, address from, address to, uint value) internal {
        if (token == address(0)) {
            _safeTransferETH(to, value);
            uint inputValue = msg.value;
            if (inputValue > value) { _safeTransferETH(msg.sender, inputValue - value); }
            return;
        }

        uint beforeAmount = IERC20(token).balanceOf(to);
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "DexCashRouter: TRANSFER_FROM_FAILED");
        uint afterAmount = IERC20(token).balanceOf(to);
        require(afterAmount == beforeAmount + value, "DexCashRouter: TRANSFER_FAILED");
    }

    function _safeTransferETH(address to, uint value) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    function _getTokensFromPair(address pair) internal view returns(address stock, address money) {
        (stock, money) = IDexCashFactory(factory).getTokensFromPair(pair);
        require(stock != address(0) || money != address(0), "DexCashRouter: PAIR_NOT_EXIST");
    }
}
