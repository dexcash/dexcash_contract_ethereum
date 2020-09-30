// SPDX-License-Identifier: GPL
pragma solidity 0.6.12;

import "./interfaces/IDexCashToken.sol";
import "./libraries/SafeMath256.sol";

contract DXCH is IDexCashToken {

    using SafeMath256 for uint256;

    mapping (address => uint256) private _balances;

    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    address private _owner;
    address private _newOwner;

    modifier onlyOwner() {
        require(msg.sender == _owner, "DexCashToken: MSG_SENDER_IS_NOT_OWNER");
        _;
    }

    modifier onlyNewOwner() {
        require(msg.sender == _newOwner, "DexCashToken: MSG_SENDER_IS_NOT_NEW_OWNER");
        _;
    }

    function owner() public view override returns (address) {
        return _owner;
    }

    function newOwner() public view override returns (address) {
        return _newOwner;
    }

    function changeOwner(address ownerToSet) public override onlyOwner {
        require(ownerToSet != address(0), "DexCashToken: INVALID_OWNER_ADDRESS");
        require(ownerToSet != _owner, "DexCashToken: NEW_OWNER_IS_THE_SAME_AS_CURRENT_OWNER");
        require(ownerToSet != _newOwner, "DexCashToken: NEW_OWNER_IS_THE_SAME_AS_CURRENT_NEW_OWNER");

        _newOwner = ownerToSet;
    }

    function updateOwner() public override onlyNewOwner {
        _owner = _newOwner;
        emit OwnerChanged(_newOwner);
    }

    constructor (string memory name, string memory symbol, uint256 supply, uint8 decimals) public {
        _owner = msg.sender;
        _name = name;
        _symbol = symbol;
        _decimals = decimals;
        _totalSupply = supply;
        _balances[msg.sender] = supply;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address tokenOwner, address spender) public view virtual override returns (uint256) {
        return _allowances[tokenOwner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender,
                _allowances[sender][msg.sender].sub(amount, "DexCashToken: TRANSFER_AMOUNT_EXCEEDS_ALLOWANCE"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual override returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "DexCashToken: DECREASED_ALLOWANCE_BELOW_ZERO"));
        return true;
    }

    function burn(uint256 amount) public virtual override {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) public virtual override {
        uint256 decreasedAllowance = allowance(account, msg.sender).sub(amount, "DexCashToken: BURN_AMOUNT_EXCEEDS_ALLOWANCE");

        _approve(account, msg.sender, decreasedAllowance);
        _burn(account, amount);
    }

    function multiTransfer(uint256[] calldata mixedAddrVal) public override returns (bool) {
        for (uint i = 0; i < mixedAddrVal.length; i++) {
            address to = address(mixedAddrVal[i]>>96);
            uint256 value = mixedAddrVal[i]&(2**96-1);
            _transfer(msg.sender, to, value);
        }
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "DexCashToken: TRANSFER_FROM_THE_ZERO_ADDRESS");
        require(recipient != address(0), "DexCashToken: TRANSFER_TO_THE_ZERO_ADDRESS");

        _balances[sender] = _balances[sender].sub(amount, "DexCashToken: TRANSFER_AMOUNT_EXCEEDS_BALANCE");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "DexCashToken: BURN_FROM_THE_ZERO_ADDRESS");
        //if called from burnFrom, either blackListed msg.sender or blackListed account causes failure
        _balances[account] = _balances[account].sub(amount, "DexCashToken: BURN_AMOUNT_EXCEEDS_BALANCE");
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(address tokenOwner, address spender, uint256 amount) internal virtual {
        require(tokenOwner != address(0), "DexCashToken: APPROVE_FROM_THE_ZERO_ADDRESS");
        require(spender != address(0), "DexCashToken: APPROVE_TO_THE_ZERO_ADDRESS");

        _allowances[tokenOwner][spender] = amount;
        emit Approval(tokenOwner, spender, amount);
    }
}
