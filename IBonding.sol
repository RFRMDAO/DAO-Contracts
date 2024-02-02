// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IBonding {
    function buyRFRM(uint256 _amount, address _token, uint8 _lockId) external;

    function discountPerLock(uint8) external view returns (uint256);

    function earlyBuyLimit() external view returns (uint256);

    function rfrm() external view returns (address);

    function initialPrice() external view returns (uint256);

    function isDynamicPriceUsed() external view returns (bool);

    function limitActiveTill() external view returns (uint32);

    function oracle() external view returns (address);

    function owner() external view returns (address);

    function paymentReceiver() external view returns (address);

    function renounceOwnership() external;

    function setContracts(address _newStaking, address _newOracle) external;

    function setDiscounts(uint8[] memory _lockIds, uint256[] memory _discounts) external;

    function setLimits(uint32 _startTime, uint32 _limitActive, uint256 _earlyLimit) external;

    function setPriceInfo(uint256 _newPrice, bool _isDynamicUsed) external;

    function setReceiver(address _newReceiver) external;

    function staking() external view returns (address);

    function startTime() external view returns (uint32);

    function totalBought(address) external view returns (uint256);

    function transferOwnership(address newOwner) external;
}
