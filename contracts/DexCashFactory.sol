// SPDX-License-Identifier: GPL
pragma solidity 0.6.12;

import "./interfaces/IDexCashFactory.sol";
import "./DexCashPair.sol";

contract DexCashFactory is IDexCashFactory {
    struct TokensInPair {
        address stock;
        address money;
    }

    address public override feeTo;
    address public override feeToSetter;
    address public immutable gov;
    address public immutable dxch;
    uint32 public override feeBPS = 10;
    address public override pairLogic;
    mapping(address => TokensInPair) private _pairToTokens;
    mapping(bytes32 => address) private _saltToPair;
    address[] public allPairs;

    constructor(address _feeToSetter, address _gov, address _dxch, address _pairLogic) public {
        feeToSetter = _feeToSetter;
        gov = _gov;
        dxch = _dxch;
        pairLogic = _pairLogic;
    }

    function createPair(address stock, address money) external override returns (address pair) {
        require(stock != money, "DexCashFactory: IDENTICAL_ADDRESSES");
        uint moneyDec = _getDecimals(money);
        uint stockDec = _getDecimals(stock);
        require(23 >= stockDec && stockDec >= 0, "DexCashFactory: STOCK_DECIMALS_NOT_SUPPORTED");
        uint dec = 0;
        if (stockDec >= 4) {
            dec = stockDec - 4; // now 19 >= dec && dec >= 0
        }
        // 10**19 = 10000000000000000000
        //  1<<64 = 18446744073709551616
        uint64 priceMul = 1;
        uint64 priceDiv = 1;
        bool differenceTooLarge = false;
        if (moneyDec > stockDec) {
            if (moneyDec > stockDec + 19) {
                differenceTooLarge = true;
            } else {
                priceMul = uint64(uint(10)**(moneyDec - stockDec));
            }
        }
        if (stockDec > moneyDec) {
            if (stockDec > moneyDec + 19) {
                differenceTooLarge = true;
            } else {
                priceDiv = uint64(uint(10)**(stockDec - moneyDec));
            }
        }
        require(!differenceTooLarge, "DexCashFactory: DECIMALS_DIFF_TOO_LARGE");
        bytes32 salt = keccak256(abi.encodePacked(stock, money));
        require(_saltToPair[salt] == address(0), "DexCashFactory: PAIR_EXISTS");
        DexCashPairProxy proxy = new DexCashPairProxy{salt: salt}(stock, money, uint64(uint(10)**dec), priceMul, priceDiv, dxch);

        pair = address(proxy);
        allPairs.push(pair);
        _saltToPair[salt] = pair;
        _pairToTokens[pair] = TokensInPair(stock, money);
        emit PairCreated(pair, stock, money);
    }

    function _getDecimals(address token) private view returns (uint) {
        if (token == address(0)) { return 18; }
        return uint(IERC20(token).decimals());
    }

    function allPairsLength() external override view returns (uint) {
        return allPairs.length;
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, "DexCashFactory: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, "DexCashFactory: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }

    function setPairLogic(address implLogic) external override {
        require(msg.sender == gov, "DexCashFactory: SETTER_MISMATCH");
        pairLogic = implLogic;
    }

    function setFeeBPS(uint32 _bps) external override {
        require(msg.sender == gov, "DexCashFactory: SETTER_MISMATCH");
        require(0 <= _bps && _bps <= 50 , "DexCashFactory: BPS_OUT_OF_RANGE");
        feeBPS = _bps;
    }

    function getTokensFromPair(address pair) external view override returns (address stock, address money) {
        stock = _pairToTokens[pair].stock;
        money = _pairToTokens[pair].money;
    }

    function tokensToPair(address stock, address money) external view override returns (address pair) {
        bytes32 key = keccak256(abi.encodePacked(stock, money));
        return _saltToPair[key];
    }
}
