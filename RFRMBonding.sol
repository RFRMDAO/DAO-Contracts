// SPDX-License-Identifier: MIT

/**
 * @title RFRM Bonding
 * @notice A contract for purchasing RFRM tokens with various locking mechanisms.
 * @dev This contract allows users to buy RFRM tokens, with options for different locking periods and discounts.
 * @author Reform DAO
 */

pragma solidity 0.8.23;

// Import necessary OpenZeppelin contracts
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";

// Import external interfaces
import { IStaking } from "./interface/IStaking.sol";
import { IOracle } from "./interface/IOracle.sol";

// Define the ERC20 interface for use in the contract
interface IERC20 {
    function decimals() external view returns (uint8);

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface USDTIERC20 {
    function decimals() external view returns (uint8);

    function transfer(address to, uint value) external;

    function transferFrom(address from, address to, uint value) external;

    function approve(address spender, uint value) external;
}

// The main RFRM Bonding contract
contract RFRMBonding is Ownable, ReentrancyGuard, Pausable {
    using Address for address;

    // RFRM Token
    IERC20 public immutable rfrm;

    // Initial price of RFRM token in cents (0.03$)
    uint256 public initialPrice = 0.03 * 10 ** 6;

    // Flag indicating whether dynamic pricing is used
    bool public isDynamicPriceUsed;

    // Start time for the sale
    uint32 public startTime;

    // Time until which the maximum cap is active
    uint32 public limitActiveTill;

    // Maximum amount that can be bought at initial stages
    uint256 public earlyBuyLimit;

    // Actual bought tokens from the bonding contract
    uint256 public totalActualBought;

    // Staking contract interface
    IStaking public immutable staking;

    // Oracle contract interface
    IOracle public immutable oracle;

    // USDC token contract interface
    IERC20 internal immutable usdc;

    // USDT token contract interface
    USDTIERC20 internal immutable usdt;

    // Address where payments are received
    address public paymentReceiver;

    // Mapping of discounts per lock period (in percentage, 2 decimals)
    mapping(uint8 => uint256) public discountPerLock;

    // Mapping of whether a lock period is disabled or not
    mapping(uint8 => bool) public isNotDisabled;

    // Mapping of total bought tokens by a user
    mapping(address => uint256) public totalBought;

    // Mapping of whether a contract is whitelisted or not
    mapping(address => bool) public isWhitelisted;

    // Custom error messages
    error ContractNotAllowed();
    error ZeroAddress();
    error InvalidLimit();
    error InvalidInput();
    error BondNotActive();
    error BondDisabled();
    error MaxLimitExceeded();
    error InsufficientFunds();
    error InvalidPaymentToken();
    error InvalidBuyAmount();

    // Modifier to ensure transactions are not initiated by other contracts
    modifier notContract() {
        // solhint-disable-next-line avoid-tx-origin
        if ((msg.sender.isContract() || msg.sender != tx.origin) && !isWhitelisted[msg.sender]) {
            revert ContractNotAllowed();
        }
        _;
    }

    // Event emitted when tokens are purchased
    event TokensPurchased(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed price,
        address purchaseToken,
        uint8 lockId
    );

    // Event emitted when sale limits are changed
    event LimitsChanged(uint32 startTime, uint32 limitActive, uint256 earlyLimit);

    // Event emitted when discounts are changed
    event DiscountsChanged(uint8[] lockIds, uint256[] discounts);

    // Event emitted when price information is changed
    event PriceInfoChanged(uint256 newPrice, bool isDynamicUsed);

    // Event emitted when contract state is changed (paused/unpaused)
    event ContractStateChanged(bool isPaused);

    // Event emitted when payment receiver address is changed
    event PaymentReceiverChanged(address newReceiver);

    /**
     * @dev Constructor to initialize the RFRM Bonding contract.
     * @param _rfrm Address of the RFRM token.
     * @param _staking Address of the staking contract.
     * @param _oracle Address of the oracle contract.
     * @param _usdc Address of the USDC token contract.
     * @param _usdt Address of the USDT token contract.
     * @param _receiver Address to receive payments.
     * @param _startTime Start time of the sale.
     * @param _limitActive Time until which the maximum cap is active.
     * @param _earlyLimit Maximum amount that can be bought at initial stages.
     */
    constructor(
        address _rfrm,
        address _staking,
        address _oracle,
        address _usdc,
        address _usdt,
        address _receiver,
        uint32 _startTime,
        uint32 _limitActive,
        uint256 _earlyLimit
    ) {
        if (_rfrm == address(0) || _staking == address(0) || _oracle == address(0)) {
            revert ZeroAddress();
        }
        rfrm = IERC20(_rfrm);
        staking = IStaking(_staking);
        oracle = IOracle(_oracle);
        usdc = IERC20(_usdc);
        usdt = USDTIERC20(_usdt);
        paymentReceiver = _receiver;
        startTime = _startTime;
        limitActiveTill = _limitActive;
        earlyBuyLimit = _earlyLimit;

        rfrm.approve(address(staking), type(uint256).max);
    }

    /**
     * @dev Set new sale limits.
     * @param _startTime New start time for the sale.
     * @param _limitActive New time until which the maximum cap is active.
     * @param _earlyLimit New maximum amount that can be bought at initial stages.
     */
    function setLimits(uint32 _startTime, uint32 _limitActive, uint256 _earlyLimit) external onlyOwner {
        if (_limitActive < _startTime) {
            revert InvalidLimit();
        }
        limitActiveTill = _limitActive;
        earlyBuyLimit = _earlyLimit;
        startTime = _startTime;
        emit LimitsChanged(_startTime, _limitActive, _earlyLimit);
    }

    /**
     * @dev Set discounts for specific lock periods.
     * @param _lockIds Array of lock period IDs.
     * @param _discounts Array of corresponding discounts (in percentage, 2 decimals).
     */
    function setDiscounts(uint8[] calldata _lockIds, uint256[] calldata _discounts) external onlyOwner {
        if (_lockIds.length != _discounts.length) {
            revert InvalidInput();
        }
        for (uint256 i = 0; i < _lockIds.length; i++) {
            discountPerLock[_lockIds[i]] = _discounts[i];
        }
        emit DiscountsChanged(_lockIds, _discounts);
    }

    /**
     * @dev Set whitelisting status for contracts.
     * @param _contracts Array of contract addresses.
     * @param _isWhitelisted Boolean indicating whether contracts should be whitelisted.
     */
    function setWhitelist(address[] calldata _contracts, bool _isWhitelisted) external onlyOwner {
        for (uint256 i = 0; i < _contracts.length; i++) {
            isWhitelisted[_contracts[i]] = _isWhitelisted;
        }
    }

    /**
     * @dev Set the status of lock periods.
     * @param _lockIds Array of lock period IDs.
     * @param _isNotDisabled Array of corresponding statuses (whether lock periods are disabled).
     */
    function setBondStatus(uint8[] calldata _lockIds, bool[] calldata _isNotDisabled) external onlyOwner {
        if (_lockIds.length != _isNotDisabled.length) {
            revert InvalidInput();
        }
        for (uint256 i = 0; i < _lockIds.length; i++) {
            isNotDisabled[_lockIds[i]] = _isNotDisabled[i];
        }
    }

    /**
     * @dev Set new price information for token purchases.
     * @param _newPrice New initial price of the RFRM token in cents (0.03$).
     * @param _isDynamicUsed Boolean indicating whether dynamic pricing is used.
     */
    function setPriceInfo(uint256 _newPrice, bool _isDynamicUsed) external onlyOwner {
        initialPrice = _newPrice;
        isDynamicPriceUsed = _isDynamicUsed;
        emit PriceInfoChanged(_newPrice, _isDynamicUsed);
    }

    /**
     * @dev Set the contract state (paused or unpaused).
     * @param _isPaused Boolean indicating whether the contract should be paused.
     */
    function setContractState(bool _isPaused) external onlyOwner {
        if (_isPaused) {
            _pause();
        } else {
            _unpause();
        }
        emit ContractStateChanged(_isPaused);
    }

    /**
     * @dev Set a new payment receiver address.
     * @param _newReceiver Address where payments should be received.
     */
    function setReceiver(address _newReceiver) external onlyOwner {
        if (_newReceiver == address(0)) {
            revert ZeroAddress();
        }
        paymentReceiver = _newReceiver;
        emit PaymentReceiverChanged(_newReceiver);
    }

    /**
     * @dev Transfer tokens from the contract to an address.
     * @param _token Address of the token to be transferred.
     * @param _to Address to which tokens should be transferred.
     * @param _amount Amount of tokens to transfer.
     */
    function transferToken(address _token, address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) {
            revert ZeroAddress();
        }
        if (_token == address(0)) {
            Address.sendValue(payable(_to), _amount);
        } else {
            IERC20(_token).transfer(_to, _amount);
        }
    }

    /**
     * @dev Buy RFRM tokens with specified parameters.
     * @param _amount Amount of tokens to buy.
     * @param _token Payment token (address(0) for ETH, or USDC/USDT token addresses).
     * @param _lockId Lock period ID.
     */
    function buyRFRM(
        uint256 _amount,
        address _token,
        uint8 _lockId
    ) external payable notContract nonReentrant whenNotPaused {
        if (block.timestamp < startTime) {
            revert BondNotActive();
        }
        if (!isNotDisabled[_lockId]) {
            revert BondDisabled();
        }
        if (block.timestamp <= limitActiveTill) {
            if (totalBought[msg.sender] + _amount > earlyBuyLimit) {
                revert MaxLimitExceeded();
            }
        }

        uint256 price;
        uint256 discountedPrice;
        if (_token == address(0)) {
            discountedPrice = getDiscountedPriceInETH(_lockId, _amount);
            if (msg.value < discountedPrice) {
                revert InsufficientFunds();
            }

            Address.sendValue(payable(paymentReceiver), discountedPrice);
            // Refund if necessary
            if (msg.value > discountedPrice) {
                Address.sendValue(payable(msg.sender), msg.value - discountedPrice);
            }
        } else {
            if (_token == address(usdc)) {
                discountedPrice = getDiscountedPriceInUSDC(_lockId, _amount);
                usdc.transferFrom(msg.sender, paymentReceiver, discountedPrice);
            } else if (_token == address(usdt)) {
                discountedPrice = getDiscountedPriceInUSDT(_lockId, _amount);
                usdt.transferFrom(msg.sender, paymentReceiver, discountedPrice);
            } else {
                revert InvalidPaymentToken();
            }
        }

        if (discountedPrice <= 0) {
            revert InvalidBuyAmount();
        }

        totalBought[msg.sender] += _amount;
        uint256[] memory amt = new uint256[](1);
        amt[0] = _amount;
        staking.deposit(0, _lockId, msg.sender, amt);
        totalActualBought += _amount;

        emit TokensPurchased(msg.sender, _amount, price, _token, _lockId);
    }

    /**
     * @dev Get the discounted price for a purchase in ETH.
     * @param _lockId Lock period ID.
     * @param _amount Amount of tokens to buy.
     * @return discountedPrice Discounted price in ETH.
     */
    function getDiscountedPriceInETH(uint8 _lockId, uint256 _amount) public view returns (uint256 discountedPrice) {
        uint256 price = isDynamicPriceUsed
            ? oracle.getPriceInETH(_amount)
            : oracle.convertUSDToETH((initialPrice * _amount) / 10 ** rfrm.decimals());
        discountedPrice = price - ((price * discountPerLock[_lockId]) / 10000);
    }

    /**
     * @dev Get the discounted price for a purchase in USDT.
     * @param _lockId Lock period ID.
     * @param _amount Amount of tokens to buy.
     * @return discountedPrice Discounted price in USDT.
     */
    function getDiscountedPriceInUSDT(uint8 _lockId, uint256 _amount) public view returns (uint256 discountedPrice) {
        uint256 price = isDynamicPriceUsed
            ? oracle.getPriceInUSDT(_amount)
            : (initialPrice * _amount) / 10 ** rfrm.decimals();
        discountedPrice = price - ((price * discountPerLock[_lockId]) / 10000);
    }

    /**
     * @dev Get the discounted price for a purchase in USDC.
     * @param _lockId Lock period ID.
     * @param _amount Amount of tokens to buy.
     * @return discountedPrice Discounted price in USDC.
     */
    function getDiscountedPriceInUSDC(uint8 _lockId, uint256 _amount) public view returns (uint256 discountedPrice) {
        uint256 price = isDynamicPriceUsed
            ? oracle.getPriceInUSDC(_amount)
            : (initialPrice * _amount) / 10 ** rfrm.decimals();
        discountedPrice = price - ((price * discountPerLock[_lockId]) / 10000);
    }
}
