// SPDX-License-Identifier: UNLICENSED

/**
 * @title RFRM Vesting
 * @author Reform DAO
 * @notice This contract allows user's to claim the tokens that are vested
 */

pragma solidity 0.8.23;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RFRMVesting is AccessControl, ERC20 {
    using SafeERC20 for IERC20;

    struct VestedTokens {
        uint256 time;
        uint256 amount;
        bool claimed;
    }

    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");
    IERC20 public immutable rfrm; // Vested token
    uint256 public constant LOCK_PERIOD = 365 days; // 1 year lock period
    mapping(address => VestedTokens[]) public vesting;
    address public immutable bondingContract;
    uint256 public unlockDisabledUntil = 1706400000; //January 28 2024 00:00:00 GMT

    event VestingAdded(address indexed wallet, uint256 amount);
    event VestingClaimed(address indexed wallet, uint256 amount, uint256 penalty);
    event EscrowMinted(address wallet, uint256 amount);
    event EscrowBurned(address wallet, uint256 amount);
    event AdminChanged(address newAdmin);
    event StakingContractAdded(address staking);
    event StakingContractRemoved(address staking);
    event UnlockDisableTimeChanged(uint256 newTime);

    error NotAuthorized();
    error ZeroAddress();
    error VestingDoesNotExist();
    error ForcedUnlockDisabled();
    error AlreadyClaimed();

    /**
     * @dev Modifier to restrict a function to only the admin.
     */
    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    /**
     * @dev Modifier to restrict a function to only authorized staking contracts.
     */
    modifier onlyAuthorized() {
        if (!hasRole(STAKING_CONTRACT_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    /**
     * @dev Constructor to initialize the contract with required parameters.
     * @param _rfrm The address of the RFRM token.
     * @param _bonding The address of the bonding contract.
     * @param _stakingContract The address of the initial staking contract.
     */
    constructor(address _rfrm, address _bonding, address _stakingContract) ERC20("RFRM Escrow Token", "ERFRM") {
        if (_rfrm == address(0) || _bonding == address(0) || _stakingContract == address(0)) revert ZeroAddress();
        rfrm = IERC20(_rfrm);
        bondingContract = _bonding;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(STAKING_CONTRACT_ROLE, _stakingContract);
    }

    /**
     * @dev Add vested tokens to a user's wallet.
     * @param _wallet The address of the user's wallet.
     * @param _amount The amount of vested tokens to add.
     */
    function addVesting(address _wallet, uint256 _amount) external onlyAuthorized {
        VestedTokens[] storage userVesting = vesting[_wallet];
        userVesting.push(VestedTokens(block.timestamp, _amount, false));

        _mint(_wallet, _amount);

        emit VestingAdded(_wallet, _amount);
    }

    /**
     * @dev Mint escrow tokens to a user's wallet.
     * @param _wallet The address of the user's wallet.
     * @param _amount The amount of escrow tokens to mint.
     */
    function mint(address _wallet, uint256 _amount) external onlyAuthorized {
        _mint(_wallet, _amount);
        emit EscrowMinted(_wallet, _amount);
    }

    /**
     * @dev Burn escrow tokens from a user's wallet.
     * @param _wallet The address of the user's wallet.
     * @param _amount The amount of escrow tokens to burn.
     */
    function burn(address _wallet, uint256 _amount) external onlyAuthorized {
        _burn(_wallet, _amount);
        emit EscrowBurned(_wallet, _amount);
    }

    /**
     * @dev Claim vested tokens from a user's wallet.
     * @param _id The index of the vested tokens in the user's wallet.
     */
    function claimUserVesting(uint256 _id) external {
        VestedTokens[] storage userVesting = vesting[msg.sender];

        if (_id >= userVesting.length) revert VestingDoesNotExist();
        if (block.timestamp < unlockDisabledUntil) revert ForcedUnlockDisabled();

        VestedTokens storage vest = userVesting[_id];

        if (vest.claimed) revert AlreadyClaimed();

        uint256 amount = getClaimableAmount(msg.sender, _id);

        vest.claimed = true;
        // Burn escrow tokens in exchange for RFRM
        _burn(msg.sender, vest.amount);
        rfrm.safeTransfer(msg.sender, amount);
        rfrm.safeTransfer(bondingContract, vest.amount - amount);

        emit VestingClaimed(msg.sender, amount, vest.amount - amount);
    }

    /**
     * @dev Transfer the contract admin role to a new address.
     * @param _newAdmin The address of the new admin.
     */
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert ZeroAddress();

        _setupRole(DEFAULT_ADMIN_ROLE, _newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        emit AdminChanged(_newAdmin);
    }

    /**
     * @dev Add a staking contract to the list of authorized contracts.
     * @param _address The address of the staking contract to add.
     */
    function addStakingContract(address _address) external onlyAdmin {
        _setupRole(STAKING_CONTRACT_ROLE, _address);
        emit StakingContractAdded(_address);
    }

    /**
     * @dev Remove a staking contract from the list of authorized contracts.
     * @param _address The address of the staking contract to remove.
     */
    function removeStakingContract(address _address) external onlyAdmin {
        _revokeRole(STAKING_CONTRACT_ROLE, _address);
        emit StakingContractRemoved(_address);
    }

    /**
     * @dev Set the unlock disable time.
     * @param _newTime The new unlock disable time.
     */
    function setUnlockDisableTime(uint256 _newTime) external onlyAdmin {
        unlockDisabledUntil = _newTime;
        emit UnlockDisableTimeChanged(_newTime);
    }

    /**
     * @dev Get the vested tokens for a user's wallet.
     * @param _wallet The address of the user's wallet.
     * @return An array of VestedTokens containing time, amount, and claimed status.
     */
    function getUserVesting(address _wallet) external view returns (VestedTokens[] memory) {
        VestedTokens[] storage _userVesting = vesting[_wallet];
        return _userVesting;
    }

    /**
     * @dev Check if an address is an authorized staking contract.
     * @param _address The address to check.
     * @return True if the address is an authorized staking contract, false otherwise.
     */
    function isStakingContract(address _address) external view returns (bool) {
        return hasRole(STAKING_CONTRACT_ROLE, _address);
    }

    /**
     * @dev Get the claimable amount of vested tokens for a user.
     * @param _wallet The address of the user's wallet.
     * @param _id The index of the vested tokens.
     * @return amount The claimable amount of vested tokens.
     */
    function getClaimableAmount(address _wallet, uint256 _id) public view returns (uint256 amount) {
        VestedTokens[] memory userVesting = vesting[_wallet];
        VestedTokens memory vest = userVesting[_id];

        uint256 elapsedTime = block.timestamp - vest.time;

        amount = (elapsedTime * vest.amount) / LOCK_PERIOD;
    }
}
