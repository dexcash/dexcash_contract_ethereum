// SPDX-License-Identifier: GPL
pragma solidity 0.6.12;

import "./interfaces/IDexCashToken.sol";
import "./interfaces/IDexCashPair.sol";
import "./interfaces/IDexCashFactory.sol";
import "./interfaces/IDexCashRouter.sol";
import "./interfaces/IDexCashBuyback.sol";

contract DexCashBuyback is IDexCashBuyback {

    uint256 private constant _MAX_UINT256 = uint256(-1); 
    address private constant _ETH = address(0);
    bytes4  private constant _APPROVE_SELECTOR = bytes4(keccak256(bytes("approve(address,uint256)")));

    address public immutable override dxch;
    address public immutable override router;
    address public immutable override factory;

    mapping (address => bool) private _mainTokens;
    address[] private _mainTokenArr;

    constructor(address _dxch, address _router, address _factory) public {
        dxch = _dxch;
        router = _router;
        factory = _factory;

        // add ETH & DXCH to main token list
        _mainTokens[_ETH] = true;
        _mainTokenArr.push(_ETH);
        _mainTokens[_dxch] = true;
        _mainTokenArr.push(_dxch);
    }

    receive() external payable { }

    // add token into main token list
    function addMainToken(address token) external override {
        require(msg.sender == IDexCashToken(dxch).owner(), "DexCashBuyback: NOT_DXCH_OWNER");
        if (!_mainTokens[token]) {
            _mainTokens[token] = true;
            _mainTokenArr.push(token);
        }
    }
    // remove token from main token list
    function removeMainToken(address token) external override {
        require(msg.sender == IDexCashToken(dxch).owner(), "DexCashBuyback: NOT_DXCH_OWNER");
        require(token != _ETH, "DexCashBuyback: REMOVE_ETH_FROM_MAIN");
        require(token != dxch, "DexCashBuyback: REMOVE_DXCH_FROM_MAIN");
        if (_mainTokens[token]) {
            _mainTokens[token] = false;
            uint256 lastIdx = _mainTokenArr.length - 1;
            for (uint256 i = 2; i < lastIdx; i++) { // skip ETH & DXCH
                if (_mainTokenArr[i] == token) {
                    _mainTokenArr[i] = _mainTokenArr[lastIdx];
                    break;
                }
            }
            _mainTokenArr.pop();
        }
    }
    // check if token is in main token list
    function isMainToken(address token) external view override returns (bool) {
        return _mainTokens[token];
    }
    // query main token list
    function mainTokens() external view override returns (address[] memory list) {
        list = _mainTokenArr;
    }

    function withdrawReserves(address[] calldata pairs) external override {
        for (uint256 i = 0; i < pairs.length; i++) {
            IDexCashPair(pairs[i]).withdrawReserves();
        }
    }

    // swap minor tokens for main tokens
    function swapForMainToken(address[] calldata pairs) external override {
        for (uint256 i = 0; i < pairs.length; i++) {
            _swapForMainToken(pairs[i]);
        }
    }
    function _swapForMainToken(address pair) private {
        (address a, address b) = IDexCashFactory(factory).getTokensFromPair(pair);
        require(a != address(0) || b != address(0), "DexCashBuyback: INVALID_PAIR");

        address mainToken;
        address minorToken;
        if (_mainTokens[a]) {
            require(!_mainTokens[b], "DexCashBuyback: SWAP_TWO_MAIN_TOKENS");
            (mainToken, minorToken) = (a, b);
        } else {
            require(_mainTokens[b], "DexCashBuyback: SWAP_TWO_MINOR_TOKENS");
            (mainToken, minorToken) = (b, a);
        }

        uint256 minorTokenAmt = IERC20(minorToken).balanceOf(address(this));
        // require(minorTokenAmt > 0, "DexCashBuyback: NO_MINOR_TOKENS");
        if (minorTokenAmt == 0) { return; }

        address[] memory path = new address[](1);
        path[0] = pair;

        // minor -> main
        _safeApprove(minorToken, router, 0);
        IERC20(minorToken).approve(router, minorTokenAmt);
        IDexCashRouter(router).marketOrder(minorToken, minorTokenAmt, 0, address(this), _MAX_UINT256);
    }

    // swap main tokens for dxch, then burn all dxch
    function swapForDXCHAndBurn(address[] calldata pairs) external override {
        for (uint256 i = 0; i < pairs.length; i++) {
            _swapForDXCH(pairs[i]);
        }

        // burn all dxch
        uint256 allDXCH = IERC20(dxch).balanceOf(address(this));
        if (allDXCH == 0) { return; }
        IDexCashToken(dxch).burn(allDXCH);
        emit BurnDXCH(allDXCH);
    }
    function _swapForDXCH(address pair) private {
        (address a, address b) = IDexCashFactory(factory).getTokensFromPair(pair);
        require(a != address(0) || b != address(0), "DexCashBuyback: INVALID_PAIR");
        require(a == dxch || b == dxch, "DexCashBuyback: DXCH_NOT_IN_PAIR");

        address token = (a == dxch) ? b : a;
        require(_mainTokens[token], "DexCashBuyback: MAIN_TOKEN_NOT_IN_PAIR");

        if (token == _ETH) { // eth -> dxch
            uint256 ethAmt = address(this).balance;
            // require(ethAmt > 0, "DexCashBuyback: NO_ETH");
            if (ethAmt == 0) { return; }

            IDexCashRouter(router).marketOrder{value: ethAmt}(_ETH, ethAmt, 0, pair, _MAX_UINT256);
        } else { // main token -> dxch
            uint256 tokenAmt = IERC20(token).balanceOf(address(this));
            // require(tokenAmt > 0, "DexCashBuyback: NO_MAIN_TOKENS");
            if (tokenAmt == 0) { return; }

            _safeApprove(token, router, 0);
            IERC20(token).approve(router, tokenAmt);
            IDexCashRouter(router).marketOrder(token, tokenAmt, 0, pair, _MAX_UINT256);
        }
    }

    function _safeApprove(address token, address spender, uint value) internal {
        // solhint-disable-next-line avoid-low-level-calls
        token.call(abi.encodeWithSelector(_APPROVE_SELECTOR, spender, value)); // result does not matter
    }

}
