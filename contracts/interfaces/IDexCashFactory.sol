// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IDexCashFactory {
    event PairCreated(address indexed pair, address stock, address money);

    function createPair(address stock, address money) external returns (address pair);
    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
    function setFeeBPS(uint32 bps) external;
    function setPairLogic(address implLogic) external;

    function allPairsLength() external view returns (uint);
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function feeBPS() external view returns (uint32);
    function pairLogic() external returns (address);
    function getTokensFromPair(address pair) external view returns (address stock, address money);
    function tokensToPair(address stock, address money) external view returns (address pair);
}
