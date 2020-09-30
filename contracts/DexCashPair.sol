// SPDX-License-Identifier: GPL
pragma solidity 0.6.12;

import "./libraries/Math.sol";
import "./libraries/SafeMath256.sol";
import "./libraries/DecFloat32.sol";
import "./libraries/ProxyData.sol";
import "./interfaces/IDexCashFactory.sol";
import "./interfaces/IDexCashToken.sol";
import "./interfaces/IDexCashPair.sol";
import "./interfaces/IERC20.sol";

interface IDexCashCallee {
    function externCall(address sender, uint amount0, uint amount1, bytes calldata data) external;
}

// An order can be compressed into 256 bits and saved using one SSTORE instruction
// The orders form a single-linked list. The preceding order points to the following order with nextID
struct Order { //total 256 bits
    address sender; //160 bits, sender creates this order
    uint32 price; // 32-bit decimal floating point number
    uint64 amount; // 42 bits are used, the stock amount to be sold or bought
    uint32 nextID; // 22 bits are used
}

// When the match engine of orderbook runs, it uses follow context to cache data in memory
struct Context {
    // this order is a limit order
    bool isLimitOrder;
    // the new order's id, it is only used when a limit order is not fully dealt
    uint32 newOrderID;
    // for buy-order, it's remained money amount; for sell-order, it's remained stock amount
    uint remainAmount;
    // it points to the first order in the opposite order book against current order
    uint32 firstID;
    // it points to the first order in the buy-order book
    uint32 firstBuyID;
    // it points to the first order in the sell-order book
    uint32 firstSellID;
    // the total dealt money and stock in the order book
    uint dealMoneyInBook;
    uint dealStockInBook;
    // cache these values from storage to memory
    uint reserveMoney;
    uint reserveStock;
    uint bookedMoney;
    uint bookedStock;
    // reserveMoney or reserveStock is changed
    bool reserveChanged;
    // the taker has dealt in the orderbook
    bool hasDealtInOrderBook;
    // the current taker order
    Order order;
    // user-expected amount which goes to taker
    uint expectedAmountToTaker;
    // the following data come from proxy
    uint64 stockUnit;
    uint64 priceMul;
    uint64 priceDiv;
    address stockToken;
    address moneyToken;
    address dxch;
    address factory;
}

contract DexCashPair is IDexCashPair {
    uint internal _unusedVar0;
    uint internal _unusedVar1;
    uint internal _unusedVar2;
    uint internal _unusedVar3;
    uint internal _unusedVar4;
    uint internal _unusedVar5;
    uint internal _unusedVar6;
    uint internal _unusedVar7;
    uint internal _unusedVar8;
    uint internal _unusedVar9;
    uint internal _unlocked;

    modifier lock() {
        require(_unlocked == 1, "DexCash: LOCKED");
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    bytes4 internal constant _SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));

    // reserveMoney and reserveStock are both uint112, id is 22 bits; they are compressed into a uint256 word
    uint internal _reserveStockAndMoneyAndFirstSellID;
    // bookedMoney and bookedStock are both uint112, id is 22 bits; they are compressed into a uint256 word
    uint internal _bookedStockAndMoneyAndFirstBuyID;

    // the orderbooks. Gas is saved when using array to store them instead of mapping
    uint[1<<22] private _sellOrders;
    uint[1<<22] private _buyOrders;

    uint32 private constant _MAX_ID = (1<<22)-1; // the maximum value of an order ID

    function stock() external override returns (address) {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+0));
        return ProxyData.stock(proxyData);
    }

    function money() external override returns (address) {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+0));
        return ProxyData.money(proxyData);
    }

    function withdrawReserves() external override {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+0));
        uint temp = _reserveStockAndMoneyAndFirstSellID;
        address factory = ProxyData.factory(proxyData);
        address dxch = ProxyData.dxch(proxyData);
        uint112 reserveStock = uint112(temp);
        uint112 reserveMoney = uint112(temp>>112);
        uint32 firstSellID = uint32(temp>>224);
        address feeTo = IDexCashFactory(factory).feeTo();
        _safeTransfer(ProxyData.money(proxyData), feeTo, uint(reserveMoney), dxch);
        _safeTransfer(ProxyData.stock(proxyData), feeTo, uint(reserveStock), dxch);
        _reserveStockAndMoneyAndFirstSellID = uint(firstSellID)<<224;
    }

    // the following 4 functions load&store compressed storage
    function getReserves() public override view returns (uint112 reserveStock, uint112 reserveMoney, uint32 firstSellID) {
        uint temp = _reserveStockAndMoneyAndFirstSellID;
        reserveStock = uint112(temp);
        reserveMoney = uint112(temp>>112);
        firstSellID = uint32(temp>>224);
    }
    function _setReserves(uint stockAmount, uint moneyAmount, uint32 firstSellID) internal {
        require(stockAmount < uint(1<<112) && moneyAmount < uint(1<<112), "DexCash: OVERFLOW");
        uint temp = (moneyAmount<<112)|stockAmount;
        temp = (uint(firstSellID)<<224)| temp;
        _reserveStockAndMoneyAndFirstSellID = temp;
    }
    function getBooked() public override view returns (uint112 bookedStock, uint112 bookedMoney, uint32 firstBuyID) {
        uint temp = _bookedStockAndMoneyAndFirstBuyID;
        bookedStock = uint112(temp);
        bookedMoney = uint112(temp>>112);
        firstBuyID = uint32(temp>>224);
    }
    function _setBooked(uint stockAmount, uint moneyAmount, uint32 firstBuyID) internal {
        require(stockAmount < uint(1<<112) && moneyAmount < uint(1<<112), "DexCash: OVERFLOW");
        _bookedStockAndMoneyAndFirstBuyID = (uint(firstBuyID)<<224)|(moneyAmount<<112)|stockAmount;
    }

    function _myBalance(address token) internal view returns (uint) {
        if(token==address(0)) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }

    // safely transfer ERC20 tokens, or ETH (when token==0)
    function _safeTransfer(address token, address to, uint value, address dxch) internal {
        if(value==0) {return;}
        if(token==address(0)) {
            // limit gas to 9000 to prevent gastoken attacks
            // solhint-disable-next-line avoid-low-level-calls 
            to.call{value: value, gas: 9000}(new bytes(0)); //we ignore its return value purposely
            return;
        }
        // solhint-disable-next-line avoid-low-level-calls 
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(_SELECTOR, to, value));
        success = success && (data.length == 0 || abi.decode(data, (bool)));
        if(!success) { // for failsafe
            address onesOwner = IDexCashToken(dxch).owner();
            // solhint-disable-next-line avoid-low-level-calls 
            (success, data) = token.call(abi.encodeWithSelector(_SELECTOR, onesOwner, value));
            require(success && (data.length == 0 || abi.decode(data, (bool))), "DexCash: TRANSFER_FAILED");
        }
    }

    function _expandPrice(uint32 price32, uint[5] memory proxyData) private pure returns (RatPrice memory price) {
        price = DecFloat32.expandPrice(price32);
        price.numerator *= ProxyData.priceMul(proxyData);
        price.denominator *= ProxyData.priceDiv(proxyData);
    }

    function _expandPrice(Context memory ctx, uint32 price32) private pure returns (RatPrice memory price) {
        price = DecFloat32.expandPrice(price32);
        price.numerator *= ctx.priceMul;
        price.denominator *= ctx.priceDiv;
    }

    function symbol() external override returns (string memory) {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+0));
        string memory s = "ETH";
        address stockToken = ProxyData.stock(proxyData);
        if(stockToken != address(0)) {
            s = IERC20(stockToken).symbol();
        }
        string memory m = "ETH";
        address moneyToken = ProxyData.money(proxyData);
        if(moneyToken != address(0)) {
            m = IERC20(moneyToken).symbol();
        }
        return string(abi.encodePacked(s, "/", m));  //to concat strings
    }

    // when emitting events, solidity's ABI pads each entry to uint256, which is so wasteful
    // we compress the entries into one uint256 to save gas
    function _emitNewLimitOrder(
        uint64 addressLow, /*255~192*/
        uint64 totalStockAmount, /*191~128*/
        uint64 remainedStockAmount, /*127~64*/
        uint32 price, /*63~32*/
        uint32 orderID, /*31~8*/
        bool isBuy /*7~0*/) private {
        uint data = uint(addressLow);
        data = (data<<64) | uint(totalStockAmount);
        data = (data<<64) | uint(remainedStockAmount);
        data = (data<<32) | uint(price);
        data = (data<<32) | uint(orderID<<8);
        if(isBuy) {
            data = data | 1;
        }
        emit NewLimitOrder(data);
    }
    function _emitNewMarketOrder(
        uint136 addressLow, /*255~120*/
        uint112 amount, /*119~8*/
        bool isBuy /*7~0*/) private {
        uint data = uint(addressLow);
        data = (data<<112) | uint(amount);
        data = data<<8;
        if(isBuy) {
            data = data | 1;
        }
        emit NewMarketOrder(data);
    }
    function _emitOrderChanged(
        uint64 makerLastAmount, /*159~96*/
        uint64 makerDealAmount, /*95~32*/
        uint32 makerOrderID, /*31~8*/
        bool isBuy /*7~0*/) private {
        uint data = uint(makerLastAmount);
        data = (data<<64) | uint(makerDealAmount);
        data = (data<<32) | uint(makerOrderID<<8);
        if(isBuy) {
            data = data | 1;
        }
        emit OrderChanged(data);
    }
    function _emitRemoveOrder(
        uint64 remainStockAmount, /*95~32*/
        uint32 orderID, /*31~8*/
        bool isBuy /*7~0*/) private {
        uint data = uint(remainStockAmount);
        data = (data<<32) | uint(orderID<<8);
        if(isBuy) {
            data = data | 1;
        }
        emit RemoveOrder(data);
    }

    // compress an order into a 256b integer
    function _order2uint(Order memory order) internal pure returns (uint) {
        uint n = uint(order.sender);
        n = (n<<32) | order.price;
        n = (n<<42) | order.amount;
        n = (n<<22) | order.nextID;
        return n;
    }

    // extract an order from a 256b integer
    function _uint2order(uint n) internal pure returns (Order memory) {
        Order memory order;
        order.nextID = uint32(n & ((1<<22)-1));
        n = n >> 22;
        order.amount = uint64(n & ((1<<42)-1));
        n = n >> 42;
        order.price = uint32(n & ((1<<32)-1));
        n = n >> 32;
        order.sender = address(n);
        return order;
    }

    // returns true if this order exists
    function _hasOrder(bool isBuy, uint32 id) internal view returns (bool) {
        if(isBuy) {
            return _buyOrders[id] != 0;
        } else {
            return _sellOrders[id] != 0;
        }
    }

    // load an order from storage, converting its compressed form into an Order struct
    function _getOrder(bool isBuy, uint32 id) internal view returns (Order memory order, bool findIt) {
        if(isBuy) {
            order = _uint2order(_buyOrders[id]);
            return (order, order.price != 0);
        } else {
            order = _uint2order(_sellOrders[id]);
            return (order, order.price != 0);
        }
    }

    // save an order to storage, converting it into compressed form
    function _setOrder(bool isBuy, uint32 id, Order memory order) internal {
        if(isBuy) {
            _buyOrders[id] = _order2uint(order);
        } else {
            _sellOrders[id] = _order2uint(order);
        }
    }

    // delete an order from storage
    function _deleteOrder(bool isBuy, uint32 id) internal {
        if(isBuy) {
            delete _buyOrders[id];
        } else {
            delete _sellOrders[id];
        }
    }

    function _getFirstOrderID(Context memory ctx, bool isBuy) internal pure returns (uint32) {
        if(isBuy) {
            return ctx.firstBuyID;
        }
        return ctx.firstSellID;
    }

    function _setFirstOrderID(Context memory ctx, bool isBuy, uint32 id) internal pure {
        if(isBuy) {
            ctx.firstBuyID = id;
        } else {
            ctx.firstSellID = id;
        }
    }

    function removeOrders(uint[] calldata rmList) external override lock {
        uint[5] memory proxyData;
        uint expectedCallDataSize = 4+32*(ProxyData.COUNT+2+rmList.length);
        ProxyData.fill(proxyData, expectedCallDataSize);
        for(uint i = 0; i < rmList.length; i++) {
            uint rmInfo = rmList[i];
            bool isBuy = uint8(rmInfo) != 0;
            uint32 id = uint32(rmInfo>>8);
            uint72 prevKey = uint72(rmInfo>>40);
            _removeOrder(isBuy, id, prevKey, proxyData);
        }
    }

    function removeOrder(bool isBuy, uint32 id, uint72 prevKey) external override lock {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+3));
        _removeOrder(isBuy, id, prevKey, proxyData);
    }

    function _removeOrder(bool isBuy, uint32 id, uint72 prevKey, uint[5] memory proxyData) private {
        Context memory ctx;
        (ctx.bookedStock, ctx.bookedMoney, ctx.firstBuyID) = getBooked();
        if(!isBuy) {
            (ctx.reserveStock, ctx.reserveMoney, ctx.firstSellID) = getReserves();
        }
        Order memory order = _removeOrderFromBook(ctx, isBuy, id, prevKey); // this is the removed order
        require(msg.sender == order.sender, "DexCash: NOT_OWNER");
        uint64 stockUnit = ProxyData.stockUnit(proxyData);
        uint stockAmount = uint(order.amount)/*42bits*/ * uint(stockUnit);
        address dxch = ProxyData.dxch(proxyData);
        if(isBuy) {
            RatPrice memory price = _expandPrice(order.price, proxyData);
            uint moneyAmount = stockAmount * price.numerator/*54+64bits*/ / price.denominator;
            ctx.bookedMoney -= moneyAmount;
            _safeTransfer(ProxyData.money(proxyData), order.sender, moneyAmount, dxch);
        } else {
            ctx.bookedStock -= stockAmount;
            _safeTransfer(ProxyData.stock(proxyData), order.sender, stockAmount, dxch);
        }
        _setBooked(ctx.bookedStock, ctx.bookedMoney, ctx.firstBuyID);
    }

    // remove an order from orderbook and return it
    function _removeOrderFromBook(Context memory ctx, bool isBuy,
                                 uint32 id, uint72 prevKey) internal returns (Order memory) {
        (Order memory order, bool ok) = _getOrder(isBuy, id);
        require(ok, "DexCash: NO_SUCH_ORDER");
        if(prevKey == 0) {
            uint32 firstID = _getFirstOrderID(ctx, isBuy);
            require(id == firstID, "DexCash: NOT_FIRST");
            _setFirstOrderID(ctx, isBuy, order.nextID);
            if(!isBuy) {
                _setReserves(ctx.reserveStock, ctx.reserveMoney, ctx.firstSellID);
            }
        } else {
            (uint32 currID, Order memory prevOrder, bool findIt) = _getOrder3Times(isBuy, prevKey);
            require(findIt, "DexCash: INVALID_POSITION");
            while(prevOrder.nextID != id) {
                currID = prevOrder.nextID;
                require(currID != 0, "DexCash: REACH_END");
                (prevOrder, ) = _getOrder(isBuy, currID);
            }
            prevOrder.nextID = order.nextID;
            _setOrder(isBuy, currID, prevOrder);
        }
        _emitRemoveOrder(order.amount, id, isBuy);
        _deleteOrder(isBuy, id);
        return order;
    }

    // insert an order at the head of single-linked list
    // this function does not check price, use it carefully
    function _insertOrderAtHead(Context memory ctx, bool isBuy, Order memory order, uint32 id) private {
        order.nextID = _getFirstOrderID(ctx, isBuy);
        _setOrder(isBuy, id, order);
        _setFirstOrderID(ctx, isBuy, id);
    }

    // prevKey contains 3 orders. try to get the first existing order
    function _getOrder3Times(bool isBuy, uint72 prevKey) private view returns (
        uint32 currID, Order memory prevOrder, bool findIt) {
        currID = uint32(prevKey&_MAX_ID);
        (prevOrder, findIt) = _getOrder(isBuy, currID);
        if(!findIt) {
            currID = uint32((prevKey>>24)&_MAX_ID);
            (prevOrder, findIt) = _getOrder(isBuy, currID);
            if(!findIt) {
                currID = uint32((prevKey>>48)&_MAX_ID);
                (prevOrder, findIt) = _getOrder(isBuy, currID);
            }
        }
    }

    // Given a valid start position, find a proper position to insert order
    // prevKey contains three suggested order IDs, each takes 24 bits.
    // We try them one by one to find a valid start position
    // can not use this function to insert at head! if prevKey is all zero, it will return false
    function _insertOrderFromGivenPos(bool isBuy, Order memory order,
                                     uint32 id, uint72 prevKey) private returns (bool inserted) {
        (uint32 currID, Order memory prevOrder, bool findIt) = _getOrder3Times(isBuy, prevKey);
        if(!findIt) {
            return false;
        }
        return _insertOrder(isBuy, order, prevOrder, id, currID);
    }
    
    // Starting from the head of orderbook, find a proper position to insert order
    function _insertOrderFromHead(Context memory ctx, bool isBuy, Order memory order,
                                 uint32 id) private returns (bool inserted) {
        uint32 firstID = _getFirstOrderID(ctx, isBuy);
        bool canBeFirst = (firstID == 0);
        Order memory firstOrder;
        if(!canBeFirst) {
            (firstOrder, ) = _getOrder(isBuy, firstID);
            canBeFirst = (isBuy && (firstOrder.price < order.price)) ||
                (!isBuy && (firstOrder.price > order.price));
        }
        if(canBeFirst) {
            order.nextID = firstID;
            _setOrder(isBuy, id, order);
            _setFirstOrderID(ctx, isBuy, id);
            return true;
        }
        return _insertOrder(isBuy, order, firstOrder, id, firstID);
    }

    // starting from 'prevOrder', whose id is 'currID', find a proper position to insert order
    function _insertOrder(bool isBuy, Order memory order, Order memory prevOrder,
                         uint32 id, uint32 currID) private returns (bool inserted) {
        while(currID != 0) {
            bool canFollow = (isBuy && (order.price <= prevOrder.price)) ||
                (!isBuy && (order.price >= prevOrder.price));
            if(!canFollow) {break;} 
            Order memory nextOrder;
            if(prevOrder.nextID != 0) {
                (nextOrder, ) = _getOrder(isBuy, prevOrder.nextID);
                bool canPrecede = (isBuy && (nextOrder.price < order.price)) ||
                    (!isBuy && (nextOrder.price > order.price));
                canFollow = canFollow && canPrecede;
            }
            if(canFollow) {
                order.nextID = prevOrder.nextID;
                _setOrder(isBuy, id, order);
                prevOrder.nextID = id;
                _setOrder(isBuy, currID, prevOrder);
                return true;
            }
            currID = prevOrder.nextID;
            prevOrder = nextOrder;
        }
        return false;
    }

    // to query the first sell price, the first buy price and the price of pool
    function getPrices() external override returns (
        uint firstSellPriceNumerator,
        uint firstSellPriceDenominator,
        uint firstBuyPriceNumerator,
        uint firstBuyPriceDenominator) {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+0));
        firstSellPriceNumerator = 0;
        firstSellPriceDenominator = 0;
        firstBuyPriceNumerator = 0;
        firstBuyPriceDenominator = 0;
        uint32 id = uint32(_reserveStockAndMoneyAndFirstSellID>>224);
        if(id!=0) {
            uint order = _sellOrders[id];
            RatPrice memory price = _expandPrice(uint32(order>>64), proxyData);
            firstSellPriceNumerator = price.numerator;
            firstSellPriceDenominator = price.denominator;
        }
        id = uint32(_bookedStockAndMoneyAndFirstBuyID>>224);
        if(id!=0) {
            uint order = _buyOrders[id];
            RatPrice memory price = _expandPrice(uint32(order>>64), proxyData);
            firstBuyPriceNumerator = price.numerator;
            firstBuyPriceDenominator = price.denominator;
        }
    }

    // Get the orderbook's content, starting from id, to get no more than maxCount orders
    function getOrderList(bool isBuy, uint32 id, uint32 maxCount) external override view returns (uint[] memory) {
        if(id == 0) {
            if(isBuy) {
                id = uint32(_bookedStockAndMoneyAndFirstBuyID>>224);
            } else {
                id = uint32(_reserveStockAndMoneyAndFirstSellID>>224);
            }
        }
        uint[1<<22] storage orderbook;
        if(isBuy) {
            orderbook = _buyOrders;
        } else {
            orderbook = _sellOrders;
        }
        //record block height at the first entry
        uint order = (block.number<<24) | id;
        uint addrOrig; // start of returned data
        uint addrLen; // the slice's length is written at this address
        uint addrStart; // the address of the first entry of returned slice
        uint addrEnd; // ending address to write the next order
        uint count = 0; // the slice's length
        // solhint-disable-next-line no-inline-assembly
        assembly {
            addrOrig := mload(0x40) // There is a “free memory pointer” at address 0x40 in memory
            mstore(addrOrig, 32) //the meaningful data start after offset 32
        }
        addrLen = addrOrig + 32;
        addrStart = addrLen + 32;
        addrEnd = addrStart;
        while(count < maxCount) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                mstore(addrEnd, order) //write the order
            }
            addrEnd += 32;
            count++;
            if(id == 0) {break;}
            order = orderbook[id];
            require(order!=0, "DexCash: INCONSISTENT_BOOK");
            id = uint32(order&_MAX_ID);
        }
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(addrLen, count) // record the returned slice's length
            let byteCount := sub(addrEnd, addrOrig)
            return(addrOrig, byteCount)
        }
    }

    // Get an unused id to be used with new order
    function _getUnusedOrderID(bool isBuy, uint32 id) internal view returns (uint32) {
        if(id == 0) { // 0 is reserved
            // solhint-disable-next-line avoid-tx-origin
            id = uint32(uint(blockhash(block.number-1))^uint(tx.origin)) & _MAX_ID; //get a pseudo random number
        }
        for(uint32 i = 0; i < 100 && id <= _MAX_ID; i++) { //try 100 times
            if(!_hasOrder(isBuy, id)) {
                return id;
            }
            id++;
        }
        require(false, "DexCash: CANNOT_FIND_VALID_ID");
        return 0;
    }

    function calcStockAndMoney(uint64 amount, uint32 price32) external pure override returns (uint stockAmount, uint moneyAmount) {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+2));
        (stockAmount, moneyAmount, ) = _calcStockAndMoney(amount, price32, proxyData);
    }

    function _calcStockAndMoney(uint64 amount, uint32 price32, uint[5] memory proxyData) private pure returns (uint stockAmount, uint moneyAmount, RatPrice memory price) {
        price = _expandPrice(price32, proxyData);
        uint64 stockUnit = ProxyData.stockUnit(proxyData);
        stockAmount = uint(amount)/*42bits*/ * uint(stockUnit);
        moneyAmount = stockAmount * price.numerator/*54+64bits*/ /price.denominator;
    }

    function _externCall(uint[3] calldata stock_money_to, bytes calldata data, uint[5] memory proxyData) internal {
        uint stockOut = stock_money_to[2];
        uint moneyOut = stock_money_to[1];
        address to = address(stock_money_to[0]);
        address stockToken = ProxyData.stock(proxyData);
        address moneyToken = ProxyData.money(proxyData);
        require(to != stockToken && to != moneyToken, 'DexCash: INVALID_TO');
        if (stockOut > 0) _safeTransfer(stockToken, to, stockOut, ProxyData.dxch(proxyData)); // optimistically transfer tokens
        if (moneyOut > 0) _safeTransfer(moneyToken, to, moneyOut, ProxyData.dxch(proxyData)); // optimistically transfer tokens
        if (data.length > 0) IDexCashCallee(to).externCall(msg.sender, stockOut, moneyOut, data);
    }

    function addLimitOrder(uint[3] calldata stock_money_to, bytes calldata data,
			   address sender, uint otherInfo) external payable override lock {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+6));
        _externCall(stock_money_to, data, proxyData);
        bool isBuy = (otherInfo&1)!=0;
	uint64 amount = uint64(otherInfo>>8);
	uint32 price32 = uint32(otherInfo>>(8+64));
        uint32 id = uint32(otherInfo>>(8+64+32));
	uint72 prevKey = uint72(otherInfo>>(8+64+32+32));
        _addLimitOrder(isBuy, sender, amount, price32, id, prevKey, proxyData);
    }
    
    function _addLimitOrder(bool isBuy, address sender, uint64 amount, uint32 price32,
                           uint32 id, uint72 prevKey, uint[5] memory proxyData) internal {
        Context memory ctx;
        ctx.stockUnit = ProxyData.stockUnit(proxyData);
        ctx.dxch = ProxyData.dxch(proxyData);
        ctx.factory = ProxyData.factory(proxyData);
        ctx.stockToken = ProxyData.stock(proxyData);
        ctx.moneyToken = ProxyData.money(proxyData);
        ctx.priceMul = ProxyData.priceMul(proxyData);
        ctx.priceDiv = ProxyData.priceDiv(proxyData);
        ctx.hasDealtInOrderBook = false;
        ctx.isLimitOrder = true;
        ctx.order.sender = sender;
        ctx.order.amount = amount;
        ctx.order.price = price32;

        ctx.newOrderID = _getUnusedOrderID(isBuy, id);
        RatPrice memory price;
    
        {// to prevent "CompilerError: Stack too deep, try removing local variables."
            require((amount >> 42) == 0, "DexCash: INVALID_AMOUNT");
            uint32 m = price32 & DecFloat32.MANTISSA_MASK;
            require(DecFloat32.MIN_MANTISSA <= m && m <= DecFloat32.MAX_MANTISSA, "DexCash: INVALID_PRICE");

            uint stockAmount;
            uint moneyAmount;
            (stockAmount, moneyAmount, price) = _calcStockAndMoney(amount, price32, proxyData);
            if(isBuy) {
                ctx.remainAmount = moneyAmount;
            } else {
                ctx.remainAmount = stockAmount;
            }
        }

        require(ctx.remainAmount < uint(1<<112), "DexCash: OVERFLOW");
        (ctx.reserveStock, ctx.reserveMoney, ctx.firstSellID) = getReserves();
        (ctx.bookedStock, ctx.bookedMoney, ctx.firstBuyID) = getBooked();
        _checkRemainAmount(ctx, isBuy);
        if(prevKey != 0 && ctx.expectedAmountToTaker == 0) { // try to insert it
            bool inserted = _insertOrderFromGivenPos(isBuy, ctx.order, ctx.newOrderID, prevKey);
            if(inserted) { //  if inserted successfully, record the booked tokens
                _emitNewLimitOrder(uint64(ctx.order.sender), amount, amount, price32, ctx.newOrderID, isBuy);
                if(isBuy) {
                    ctx.bookedMoney += ctx.remainAmount;
                } else {
                    ctx.bookedStock += ctx.remainAmount;
                }
                _setBooked(ctx.bookedStock, ctx.bookedMoney, ctx.firstBuyID);
                if(ctx.reserveChanged) {
                    _setReserves(ctx.reserveStock, ctx.reserveMoney, ctx.firstSellID);
                }
                return;
            }
            // if insertion failed, we try to match this order and make it deal
        }
        _addOrder(ctx, isBuy, price);
    }

    function addMarketOrder(uint[3] calldata stock_money_to, bytes calldata data,
                            address inputToken, address sender, uint112 inAmount) external payable override lock returns (uint) {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+3));
        _externCall(stock_money_to, data, proxyData);
        Context memory ctx;
        ctx.moneyToken = ProxyData.money(proxyData);
        ctx.stockToken = ProxyData.stock(proxyData);
        require(inputToken == ctx.moneyToken || inputToken == ctx.stockToken, "DexCash: INVALID_TOKEN");
        bool isBuy = inputToken == ctx.moneyToken;
        ctx.stockUnit = ProxyData.stockUnit(proxyData);
        ctx.priceMul = ProxyData.priceMul(proxyData);
        ctx.priceDiv = ProxyData.priceDiv(proxyData);
        ctx.dxch = ProxyData.dxch(proxyData);
        ctx.factory = ProxyData.factory(proxyData);
        ctx.hasDealtInOrderBook = false;
        ctx.isLimitOrder = false;
        ctx.remainAmount = inAmount;
        (ctx.reserveStock, ctx.reserveMoney, ctx.firstSellID) = getReserves();
        (ctx.bookedStock, ctx.bookedMoney, ctx.firstBuyID) = getBooked();
        _checkRemainAmount(ctx, isBuy);
        ctx.order.sender = sender;
        if(isBuy) {
            ctx.order.price = DecFloat32.MAX_PRICE;
        } else {
            ctx.order.price = DecFloat32.MIN_PRICE;
        }

        RatPrice memory price; // leave it to zero, actually it will not be used;
        _emitNewMarketOrder(uint136(ctx.order.sender), inAmount, isBuy);
        return _addOrder(ctx, isBuy, price);
    }

    // Check router contract did send me enough tokens.
    // If Router sent to much tokens, take them as reserve money&stock
    function _checkRemainAmount(Context memory ctx, bool isBuy) private view {
        ctx.reserveChanged = false;
        uint diff;
        if(isBuy) {
            uint balance = _myBalance(ctx.moneyToken);
            require(balance >= ctx.bookedMoney + ctx.reserveMoney, "DexCash: MONEY_MISMATCH");
            diff = balance - ctx.bookedMoney - ctx.reserveMoney;
            if(ctx.remainAmount < diff) {
                ctx.reserveMoney += (diff - ctx.remainAmount);
                ctx.reserveChanged = true;
            }
        } else {
            uint balance = _myBalance(ctx.stockToken);
            require(balance >= ctx.bookedStock + ctx.reserveStock, "DexCash: STOCK_MISMATCH");
            diff = balance - ctx.bookedStock - ctx.reserveStock;
            if(ctx.remainAmount < diff) {
                ctx.reserveStock += (diff - ctx.remainAmount);
                ctx.reserveChanged = true;
            }
        }
        require(ctx.remainAmount <= diff, "DexCash: DEPOSIT_NOT_ENOUGH");
        ctx.expectedAmountToTaker = 0;
        if(isBuy) {
            uint balance = _myBalance(ctx.stockToken);
            if (balance < ctx.bookedStock + ctx.reserveStock) {
                ctx.expectedAmountToTaker = balance - ctx.bookedStock - ctx.reserveStock;
	    }
        } else {
            uint balance = _myBalance(ctx.moneyToken);
            if (balance < ctx.bookedMoney + ctx.reserveMoney) {
                ctx.expectedAmountToTaker = balance - ctx.bookedMoney - ctx.reserveMoney;
	    }
        }
    }

    function _checkFinalAmount(Context memory ctx) private {
        uint balance = _myBalance(ctx.moneyToken);
        require(balance >= ctx.bookedMoney + ctx.reserveMoney, "DexCash: MONEY_MISMATCH");
        if (balance > ctx.bookedMoney + ctx.reserveMoney) {
            uint diff = balance - ctx.bookedMoney - ctx.reserveMoney;
            _safeTransfer(ctx.moneyToken, ctx.order.sender, diff, ctx.dxch);
	}

        balance = _myBalance(ctx.stockToken);
        require(balance >= ctx.bookedStock + ctx.reserveStock, "DexCash: STOCK_MISMATCH");
        if (balance > ctx.bookedStock + ctx.reserveStock) {
            uint diff = balance - ctx.bookedStock - ctx.reserveStock;
            _safeTransfer(ctx.stockToken, ctx.order.sender, diff, ctx.dxch);
	}
    }

    // internal helper function to add new limit order & market order
    // returns the amount of tokens which were sent to the taker (from AMM pool and booked tokens)
    function _addOrder(Context memory ctx, bool isBuy, RatPrice memory price) private returns (uint) {
        (ctx.dealMoneyInBook, ctx.dealStockInBook) = (0, 0);
        ctx.firstID = _getFirstOrderID(ctx, !isBuy);
        uint32 currID = ctx.firstID;
        while(currID != 0) { // while not reaching the end of single-linked 
            (Order memory orderInBook, ) = _getOrder(!isBuy, currID);
            bool canDealInOrderBook = (isBuy && (orderInBook.price <= ctx.order.price)) ||
                (!isBuy && (orderInBook.price >= ctx.order.price));
            if(!canDealInOrderBook) {break;} // no proper price in orderbook, stop here

            RatPrice memory priceInBook = _expandPrice(ctx, orderInBook.price);
            // Deal in orderbook
            _dealInOrderBook(ctx, isBuy, currID, orderInBook, priceInBook);

            // if the order in book did NOT fully deal, then this new order DID fully deal, so stop here
            if(orderInBook.amount != 0) {
                _setOrder(!isBuy, currID, orderInBook);
                break;
            }
            // if the order in book DID fully deal, then delete this order from storage and move to the next
            _deleteOrder(!isBuy, currID);
            currID = orderInBook.nextID;
        }
        // Deal in liquid pool
        if(ctx.isLimitOrder) {
            // If a limit order did NOT fully deal, we add it into orderbook
            // Please note a market order always fully deals
            _insertOrderToBook(ctx, isBuy, price);
        } else {
            // the AMM pool can deal with orders with any amount
            ctx.remainAmount = 0;
        }
        uint amountToTaker = _collectFee(ctx, isBuy);
        if(isBuy) {
            ctx.bookedStock -= ctx.dealStockInBook; //If this subtraction overflows, _setBooked will fail
        } else {
            ctx.bookedMoney -= ctx.dealMoneyInBook; //If this subtraction overflows, _setBooked will fail
        }
        if(ctx.firstID != currID) { //some orders DID fully deal, so the head of single-linked list change
            _setFirstOrderID(ctx, !isBuy, currID);
        }
        // write the cached values to storage
        _setBooked(ctx.bookedStock, ctx.bookedMoney, ctx.firstBuyID);
        _setReserves(ctx.reserveStock, ctx.reserveMoney, ctx.firstSellID);
        _checkFinalAmount(ctx);
        return amountToTaker;
    }

    // Current order tries to deal against the orders in book
    function _dealInOrderBook(Context memory ctx, bool isBuy, uint32 currID,
                             Order memory orderInBook, RatPrice memory priceInBook) internal {
        ctx.hasDealtInOrderBook = true;
        uint stockAmount;
        if(isBuy) {
            uint a = ctx.remainAmount/*112bits*/ * priceInBook.denominator/*76+64bits*/;
            uint b = priceInBook.numerator/*54+64bits*/ * ctx.stockUnit/*64bits*/;
            stockAmount = a/b;
        } else {
            stockAmount = ctx.remainAmount/ctx.stockUnit;
        }
        if(uint(orderInBook.amount) < stockAmount) {
            stockAmount = uint(orderInBook.amount);
        }
        require(stockAmount < (1<<42), "DexCash: STOCK_TOO_LARGE");
        uint stockTrans = stockAmount/*42bits*/ * ctx.stockUnit/*64bits*/;
        uint moneyTrans = stockTrans * priceInBook.numerator/*54+64bits*/ / priceInBook.denominator/*76+64bits*/;

        _emitOrderChanged(orderInBook.amount, uint64(stockAmount), currID, isBuy);
        orderInBook.amount -= uint64(stockAmount);
        if(isBuy) { //subtraction cannot overflow: moneyTrans and stockTrans are calculated from remainAmount
            ctx.remainAmount -= moneyTrans;
        } else {
            ctx.remainAmount -= stockTrans;
        }
        // following accumulations can not overflow, because stockTrans(moneyTrans) at most 106bits(160bits)
        // we know for sure that dealStockInBook and dealMoneyInBook are less than 192 bits
        ctx.dealStockInBook += stockTrans;
        ctx.dealMoneyInBook += moneyTrans;
	// reward the maker
	if(ctx.moneyToken == address(0)) {
	    addScore(orderInBook.sender, moneyTrans);
	}
	if(ctx.stockToken == address(0)) {
	    addScore(orderInBook.sender, stockTrans);
	}
        if(isBuy) {
            _safeTransfer(ctx.moneyToken, orderInBook.sender, moneyTrans, ctx.dxch);
        } else {
            _safeTransfer(ctx.stockToken, orderInBook.sender, stockTrans, ctx.dxch);
        }
    }

    function _collectFee(Context memory ctx, bool isBuy) internal view returns (uint) {
        uint amountToTaker = ctx.dealMoneyInBook;
        if(isBuy) {
            amountToTaker = ctx.dealStockInBook;
        }

        require(amountToTaker < uint(1<<112), "DexCash: AMOUNT_TOO_LARGE");
        uint32 feeBPS = IDexCashFactory(ctx.factory).feeBPS();
        uint fee = (amountToTaker * feeBPS + 9999) / 10000;
        amountToTaker -= fee;

        if(isBuy) {
            ctx.reserveStock = ctx.reserveStock + fee;
        } else {
            ctx.reserveMoney = ctx.reserveMoney + fee;
        }

	require(amountToTaker > ctx.expectedAmountToTaker, "DexCash: TOO_MUCH_TO_TAKER");
        return amountToTaker;
    }

    // Insert a not-fully-deal limit order into orderbook
    function _insertOrderToBook(Context memory ctx, bool isBuy, RatPrice memory price) internal {
        (uint smallAmount, uint moneyAmount, uint stockAmount) = (0, 0, 0);
        if(isBuy) {
            uint tempAmount1 = ctx.remainAmount /*112bits*/ * price.denominator /*76+64bits*/;
            uint temp = ctx.stockUnit * price.numerator/*54+64bits*/;
            stockAmount = tempAmount1 / temp;
            uint tempAmount2 = stockAmount * temp; // Now tempAmount1 >= tempAmount2
            moneyAmount = (tempAmount2+price.denominator-1)/price.denominator; // round up
            if(ctx.remainAmount > moneyAmount) {
                // smallAmount is the gap where remainAmount can not buy an integer of stocks
                smallAmount = ctx.remainAmount - moneyAmount;
            } else {
                moneyAmount = ctx.remainAmount;
            } //Now ctx.remainAmount >= moneyAmount
        } else {
            // for sell orders, remainAmount were always decreased by integral multiple of StockUnit
            // and we know for sure that ctx.remainAmount % StockUnit == 0
            stockAmount = ctx.remainAmount / ctx.stockUnit;
            smallAmount = ctx.remainAmount - stockAmount * ctx.stockUnit;
        }
        ctx.reserveMoney += smallAmount; // If this addition overflows, _setReserves will fail
        _emitNewLimitOrder(uint64(ctx.order.sender), ctx.order.amount, uint64(stockAmount),
                           ctx.order.price, ctx.newOrderID, isBuy);
        if(stockAmount != 0) {
            ctx.order.amount = uint64(stockAmount);
            if(ctx.hasDealtInOrderBook) {
                // if current order has ever dealt, it has the best price and can be inserted at head
                _insertOrderAtHead(ctx, isBuy, ctx.order, ctx.newOrderID);
            } else {
                // if current order has NEVER dealt, we must find a proper position for it.
                // we may scan a lot of entries in the single-linked list and run out of gas
                _insertOrderFromHead(ctx, isBuy, ctx.order, ctx.newOrderID);
            }
        }
        // Any overflow/underflow in following calculation will be caught by _setBooked
        if(isBuy) {
            ctx.bookedMoney += moneyAmount;
        } else {
            ctx.bookedStock += (ctx.remainAmount - smallAmount);
        }
    }

    uint private constant startMiningTime = 10000;
    uint private constant miningWeekCount = 150;
    uint private constant endMiningTime = startMiningTime * miningWeekCount * 1 weeks;
    uint[miningWeekCount] public totalScoreInWeek;
    mapping(address => uint[miningWeekCount]) public userScoreInWeek;
    uint[miningWeekCount] public totalCoinsInWeek;

    function addScore(address user, uint score) internal {
	if(now >= endMiningTime) return;
	uint weekNum = (now - startMiningTime) / 1 weeks;
	if (weekNum >= miningWeekCount) return;
	totalScoreInWeek[weekNum] += score;
	userScoreInWeek[user][weekNum] += score;
    }

    function withdrawRewardOfWeek(uint weekNum) external {
        uint[5] memory proxyData;
        ProxyData.fill(proxyData, 4+32*(ProxyData.COUNT+1));
        address dxch = ProxyData.dxch(proxyData);
	if (weekNum >= miningWeekCount) return;
	require(now >= startMiningTime + (weekNum+1) * 1 weeks, "DexCash: WEEK_NOT_END");
	uint totalCoins = totalCoinsInWeek[weekNum];
	if (totalCoins == 0) { //variable not initialized
	    uint myBalance = IERC20(dxch).balanceOf(address(this));
	    totalCoins = myBalance / (miningWeekCount - weekNum);
	}
	uint totalScore = totalScoreInWeek[weekNum];
	uint userScore = userScoreInWeek[msg.sender][weekNum];
	uint coinsToUser = userScore * totalCoins / totalScore;
	if (coinsToUser >= totalCoins) {
	    coinsToUser = totalCoins - 1; // 10**(-18) coins will be left 
	}
	uint data = (weekNum<<160)|uint(msg.sender);
	emit WithdrawReward(address(this), data);
	IERC20(dxch).transfer(msg.sender, coinsToUser);
	totalCoinsInWeek[weekNum] = totalCoins - coinsToUser;
	totalScoreInWeek[weekNum] = totalScore - userScore;
	userScoreInWeek[msg.sender][weekNum] = 0;
    }

}

// solhint-disable-next-line max-states-count
contract DexCashPairProxy {
    uint internal _unusedVar0;
    uint internal _unusedVar1;
    uint internal _unusedVar2;
    uint internal _unusedVar3;
    uint internal _unusedVar4;
    uint internal _unusedVar5;
    uint internal _unusedVar6;
    uint internal _unusedVar7;
    uint internal _unusedVar8;
    uint internal _unusedVar9;
    uint internal _unlocked;

    uint internal immutable _immuFactory;
    uint internal immutable _immuMoneyToken;
    uint internal immutable _immuStockToken;
    uint internal immutable _immuDXCH;
    uint internal immutable _immuOther;

    constructor(address stockToken, address moneyToken, uint64 stockUnit, uint64 priceMul, uint64 priceDiv, address dxch) public {
        _immuFactory = uint(msg.sender);
        _immuMoneyToken = uint(moneyToken);
        _immuStockToken = uint(stockToken);
        _immuDXCH = uint(dxch);
        uint temp = 0;
        temp = (temp<<64) | stockUnit;
        temp = (temp<<64) | priceMul;
        temp = (temp<<64) | priceDiv;
        _immuOther = temp;
        _unlocked = 1;
    }

    receive() external payable { }
    // solhint-disable-next-line no-complex-fallback
    fallback() payable external {
        uint factory     = _immuFactory;
        uint moneyToken  = _immuMoneyToken;
        uint stockToken  = _immuStockToken;
        uint dxch        = _immuDXCH;
        uint other       = _immuOther;
        address impl = IDexCashFactory(address(_immuFactory)).pairLogic();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let ptr := mload(0x40)
            let size := calldatasize()
            calldatacopy(ptr, 0, size)
            let end := add(ptr, size)
            // append immutable variables to the end of calldata
            mstore(end, factory)
            end := add(end, 32)
            mstore(end, moneyToken)
            end := add(end, 32)
            mstore(end, stockToken)
            end := add(end, 32)
            mstore(end, dxch)
            end := add(end, 32)
            mstore(end, other)
            size := add(size, 160)
            let result := delegatecall(gas(), impl, ptr, size, 0, 0)
            size := returndatasize()
            returndatacopy(ptr, 0, size)

            switch result
            case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }
}

