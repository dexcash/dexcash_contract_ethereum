// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IDexCashPair {
    event NewLimitOrder(uint data); // new limit order was sent by an account
    event NewMarketOrder(uint data); // new market order was sent by an account
    event OrderChanged(uint data); // old orders in orderbook changed
    event RemoveOrder(uint data); // an order was removed from the orderbook
    event WithdrawReward(address pair, uint weekAndUser);
    
    function withdrawReserves() external;

    function getReserves() external view returns (uint112 reserveStock, uint112 reserveMoney, uint32 firstSellID);
    function getBooked() external view returns (uint112 bookedStock, uint112 bookedMoney, uint32 firstBuyID);
    function stock() external returns (address);
    function money() external returns (address);
    function symbol() external returns (string memory);

    // Return three prices in rational number form, i.e., numerator/denominator.
    // They are: the first sell order's price; the first buy order's price; the current price of the AMM pool.
    function getPrices() external returns (
        uint firstSellPriceNumerator,
        uint firstSellPriceDenominator,
        uint firstBuyPriceNumerator,
        uint firstBuyPriceDenominator);

    // This function queries a list of orders in orderbook. It starts from 'id' and iterates the single-linked list, util it reaches the end, 
    // or until it has found 'maxCount' orders. If 'id' is 0, it starts from the beginning of the single-linked list.
    // It may cost a lot of gas. So you'd not to call in on chain. It is mainly for off-chain query.
    // The first uint256 returned by this function is special: the lowest 24 bits is the first order's id and the the higher bits is block height.
    // THe other uint256s are all corresponding to an order record of the single-linked list.
    function getOrderList(bool isBuy, uint32 id, uint32 maxCount) external view returns (uint[] memory);

    // remove an order from orderbook and return its booked (i.e. frozen) money to maker
    // 'id' points to the order to be removed
    // prevKey points to 3 previous orders in the single-linked list
    function removeOrder(bool isBuy, uint32 id, uint72 positionID) external;

    function removeOrders(uint[] calldata rmList) external;

    // Try to deal a new limit order or insert it into orderbook
    // its suggested order id is 'id' and suggested positions are in 'prevKey'
    // prevKey points to 3 existing orders in the single-linked list
    // the order's sender is 'sender'. the order's amount is amount*stockUnit, which is the stock amount to be sold or bought.
    // the order's price is 'price32', which is decimal floating point value.
    function addLimitOrder(uint[3] calldata stock_money_to, bytes calldata data, address sender, uint otherInfo) external payable;

    // Try to deal a new market order. 'sender' pays 'inAmount' of 'inputToken', in exchange of the other token kept by this pair
    function addMarketOrder(uint[3] calldata stock_money_to, bytes calldata data, address inputToken, address sender, uint112 inAmount) external payable returns (uint);

    // Given the 'amount' of stock and decimal floating point price 'price32', calculate the 'stockAmount' and 'moneyAmount' to be traded
    function calcStockAndMoney(uint64 amount, uint32 price32) external pure returns (uint stockAmount, uint moneyAmount);
}
