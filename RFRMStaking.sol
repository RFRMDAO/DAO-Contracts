// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title RFRM Staking Contract
 * @dev A staking contract that allows users to stake tokens and earn rewards.
 * @author Reform DAO
 * @notice This contract allows users to stake tokens, participate in liquidity pools, and earn rewards.
 * @dev The contract supports NFT pools, lock periods, and vesting of rewards.
 */
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IVesting } from "./interface/IVesting.sol";

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

contract RFRMStaking is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // Info of each user.
    struct UserInfo {
        uint256 totalDeposit;
        uint256 rewardDebt;
        uint256 totalClaimed;
        uint256 depositTime;
        EnumerableSet.UintSet deposits;
    }

    // Info of each pool.
    struct PoolInfo {
        bool isInputNFT; //Is NFT pool or not
        bool isVested; //Is reward vested or not
        uint32 totalInvestors;
        address input; // Address of input token.
        uint256 allocPoint; // How many allocation points assigned to this pool. RFRMs to distribute per block.
        uint256 lastRewardBlock; // Last block number that RFRMs distribution occurs.
        uint256 accTknPerShare; // Accumulated RFRMs per share, times 1e12. See below.
        uint256 startIdx; //Start index of NFT (if applicable)
        uint256 endIdx; //End index of NFT (if applicable)
        uint256 totalDeposit;
        EnumerableSet.UintSet deposits;
    }

    struct PoolLockInfo {
        uint32 multi; //4 decimal precision
        uint32 claimFee; //2 decimal precision
        uint32 lockPeriodInSeconds; //Lock period for staked tokens
        bool forcedUnlockEnabled; //Whether forced unlock is enabled for this pool
    }

    struct UserLockInfo {
        bool isWithdrawed;
        uint32 depositTime;
        uint256 actualDeposit;
    }

    // The REWARD TOKEN!
    IERC20 public immutable reward;
    //Percentage distributed per day. 2 decimals / 100000
    uint32 public percPerDay = 1;
    //Address where reward token is stored
    address public rewardWallet;
    //Address where fees are sent
    address public feeWallet;
    //Vesting contract address
    IVesting public vestingCont;

    //Number of blocks per day
    uint16 internal constant BLOCKS_PER_DAY = 7150;
    //Divisor
    uint16 internal constant DIVISOR = 10000;

    // Info of each pool.
    PoolInfo[] internal pools;
    //Info of each lock term
    mapping(uint256 => PoolLockInfo) public poolLockInfo;
    // Info of each user that stakes tokens.
    mapping(uint256 => mapping(address => UserInfo)) internal users;
    // Info of users who staked tokens from bonding contract
    mapping(uint8 => mapping(address => UserLockInfo[])) public userLockInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    //Actual deposit in lock pool
    uint256 public totalActualDeposit;
    // The block number when REWARDing starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint8 indexed lid, uint256[] amounts);
    event Withdraw(address indexed user, uint256 indexed pid, uint8 indexed lid, uint256[] amounts);
    event RewardClaimed(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(
        bool _isInputNFT,
        bool _isVested,
        uint256 _allocPoint,
        address _input,
        uint256 _startIdx,
        uint256 _endIdx
    );
    event PoolChanged(uint256 pid, uint256 allocPoint, bool isVested, uint256 startIdx, uint256 endIdx);
    event PoolLockChanged(uint256 lid, uint32 multi, uint32 claimFee, uint32 lockPeriod);
    event PoolUpdated(uint256 pid);
    event WalletsChanged(address reward, address feeWallet);
    event RewardChanged(uint32 perc);
    event VestingContractChanged(address vesting);

    error ZeroAddress();
    error InvalidNFTId();
    error InvalidAmount();
    error InvalidLockId();
    error AlreadyWithdrawed();
    error ForcedUnlockDisabled();
    error InvalidInput();
    error DepositNotFound();

    /**
     * @dev Initializes the RFRMStaking contract with the specified parameters.
     * @param _reward The address of the REWARD token.
     * @param _rewardWallet The address where REWARD tokens are stored.
     * @param _feeWallet The address where fees are sent.
     * @param _startBlock The block number when REWARDing starts.
     * @notice All parameters must be non-zero addresses.
     */
    constructor(address _reward, address _rewardWallet, address _feeWallet, uint256 _startBlock) {
        if (_reward == address(0) || _rewardWallet == address(0) || _feeWallet == address(0)) revert ZeroAddress();
        reward = IERC20(_reward);
        rewardWallet = _rewardWallet;
        feeWallet = _feeWallet;
        startBlock = _startBlock;
    }

    /**
     * @dev Returns the number of pools available for staking.
     * @return The number of pools.
     */
    function poolLength() external view returns (uint256) {
        return pools.length;
    }

    /**
     * @dev Adds a new pool to the contract. Can only be called by the owner.
     * @param _isInputNFT True if the input is an NFT, false otherwise.
     * @param _isVested True if the rewards are vested, false otherwise.
     * @param _allocPoint The allocation points for the new pool.
     * @param _input The address of the input token or NFT.
     * @param _startIdx The starting index for NFTs (if _isInputNFT is true).
     * @param _endIdx The ending index for NFTs (if _isInputNFT is true).
     */
    function add(
        bool _isInputNFT,
        bool _isVested,
        uint256 _allocPoint,
        address _input,
        uint256 _startIdx,
        uint256 _endIdx
    ) external onlyOwner {
        if (_input == address(0)) revert ZeroAddress();
        massUpdatePools();

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        PoolInfo storage newPool = pools.push();

        newPool.allocPoint = _allocPoint;
        newPool.input = _input;
        newPool.isInputNFT = _isInputNFT;
        newPool.isVested = _isVested;
        newPool.lastRewardBlock = lastRewardBlock;

        if (_isInputNFT) {
            newPool.startIdx = _startIdx;
            newPool.endIdx = _endIdx;
        }

        emit PoolAdded(_isInputNFT, _isVested, _allocPoint, _input, _startIdx, _endIdx);
    }

    /**
     * @dev Updates an existing pool. Can only be called by the owner.
     * @param _pid The ID of the pool to be updated.
     * @param _allocPoint The new allocation points for the pool.
     * @param _isVested True if the rewards are vested, false otherwise.
     * @param _startIdx The new starting index for NFTs (if pool is for NFTs).
     * @param _endIdx The new ending index for NFTs (if pool is for NFTs).
     */
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _isVested,
        uint256 _startIdx,
        uint256 _endIdx
    ) external onlyOwner {
        massUpdatePools();
        PoolInfo storage pool = pools[_pid];

        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        pool.allocPoint = _allocPoint;
        pool.isVested = _isVested;

        if (pool.isInputNFT) {
            pool.startIdx = _startIdx;
            pool.endIdx = _endIdx;
        }

        emit PoolChanged(_pid, _allocPoint, _isVested, _startIdx, _endIdx);
    }

    /**
     * @dev Sets lock parameters for a specific pool.
     * @param _lid The ID of the lock pool.
     * @param _multi The multiplier for the lock pool.
     * @param _claimFee The claim fee for the lock pool.
     * @param _lockPeriod The lock period in seconds for the lock pool.
     */
    function setPoolLock(uint256 _lid, uint32 _multi, uint32 _claimFee, uint32 _lockPeriod) external onlyOwner {
        PoolLockInfo storage pool = poolLockInfo[_lid];

        pool.claimFee = _claimFee;
        pool.lockPeriodInSeconds = _lockPeriod;
        pool.multi = _multi;

        emit PoolLockChanged(_lid, _multi, _claimFee, _lockPeriod);
    }

    /**
     * @dev View function to see pending rewards for a user in a specific pool.
     * @param _pid The ID of the pool.
     * @param _user The user's address.
     * @return The pending rewards for the user.
     */
    function pendingTkn(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = pools[_pid];
        UserInfo storage user = users[_pid][_user];
        uint256 accTknPerShare = pool.accTknPerShare;
        uint256 total = pool.totalDeposit;
        if (block.number > pool.lastRewardBlock && total != 0) {
            uint256 multi = block.number - pool.lastRewardBlock;
            uint256 rewardPerBlock = getRewardPerBlock();
            uint256 tknReward = (multi * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            accTknPerShare = accTknPerShare + ((tknReward * 1e12) / total);
        }
        return (user.totalDeposit * accTknPerShare) / 1e12 - user.rewardDebt;
    }

    /**
     * @dev Deposits tokens into staking for reward allocation.
     * @param _pid The ID of the pool.
     * @param _lid The ID of the lock pool (if applicable).
     * @param _benificiary The address of the beneficiary.
     * @param _amounts The amounts to deposit (for NFTs or tokens).
     */
    function deposit(
        uint256 _pid,
        uint8 _lid,
        address _benificiary,
        uint256[] calldata _amounts
    ) external nonReentrant {
        PoolInfo storage pool = pools[_pid];
        UserInfo storage user = users[_pid][_benificiary];
        updatePool(_pid);
        if (user.totalDeposit > 0) {
            _claimReward(_pid, _benificiary);
        } else {
            pool.totalInvestors++;
        }

        if (pool.isInputNFT) {
            IERC721 nft = IERC721(pool.input);
            uint256 len = _amounts.length;
            uint256 id;

            for (uint256 i = 0; i < len; ) {
                id = _amounts[i];
                if (id < pool.startIdx || id > pool.endIdx) revert InvalidNFTId();
                nft.safeTransferFrom(msg.sender, address(this), id);
                pool.deposits.add(id);
                user.deposits.add(id);
                unchecked {
                    i++;
                }
            }
            user.totalDeposit = user.totalDeposit + len;
            pool.totalDeposit = pool.totalDeposit + len;
        } else {
            if (_amounts.length != 1) revert InvalidAmount();
            uint256 amount = _amounts[0];
            IERC20(pool.input).safeTransferFrom(msg.sender, address(this), amount);

            if (_pid == 0) {
                PoolLockInfo storage poolLock = poolLockInfo[_lid];
                UserLockInfo storage userLock = userLockInfo[_lid][_benificiary].push();

                if (poolLock.multi <= 0) revert InvalidLockId();

                userLock.depositTime = uint32(block.timestamp);
                userLock.actualDeposit = amount;
                totalActualDeposit += amount;

                uint256 weightedAmount = (amount * poolLock.multi) / DIVISOR;
                user.totalDeposit += weightedAmount;
                pool.totalDeposit += weightedAmount;
                vestingCont.mint(_benificiary, amount);
            } else {
                user.totalDeposit = user.totalDeposit + amount;
                pool.totalDeposit = pool.totalDeposit + amount;
            }
        }

        user.rewardDebt = (user.totalDeposit * pool.accTknPerShare) / 1e12;
        user.depositTime = block.timestamp;
        emit Deposit(_benificiary, _pid, _lid, _amounts);
    }

    /**
     * @dev Withdraws tokens from staking.
     * @param _pid The ID of the pool.
     * @param _lid The ID of the lock pool (if applicable).
     * @param _did The ID of the user's deposit (if applicable).
     * @param _amounts The amounts to withdraw (for NFTs or tokens).
     */
    function withdraw(uint256 _pid, uint8 _lid, uint256 _did, uint256[] calldata _amounts) external nonReentrant {
        PoolInfo storage pool = pools[_pid];
        UserInfo storage user = users[_pid][msg.sender];

        updatePool(_pid);
        _claimReward(_pid, msg.sender);

        if (pool.isInputNFT) {
            IERC721 nft = IERC721(pool.input);
            uint256 len = _amounts.length;

            for (uint256 i = 0; i < len; ) {
                uint256 id = _amounts[i];
                if (!user.deposits.contains(id)) revert InvalidNFTId();
                nft.safeTransferFrom(address(this), msg.sender, id);

                user.deposits.remove(id);
                pool.deposits.remove(id);

                unchecked {
                    i++;
                }
            }
            user.totalDeposit = user.totalDeposit - _amounts.length;
            pool.totalDeposit = pool.totalDeposit - _amounts.length;
        } else {
            IERC20 token = IERC20(pool.input);
            uint256 amount = _amounts[0];

            if (_pid == 0) {
                PoolLockInfo storage poolLock = poolLockInfo[_lid];
                UserLockInfo storage userLock = userLockInfo[_lid][msg.sender][_did];
                amount = userLock.actualDeposit;

                if (userLock.isWithdrawed) revert AlreadyWithdrawed();
                uint256 weightedAmount = (amount * poolLock.multi) / DIVISOR;
                user.totalDeposit -= weightedAmount;
                pool.totalDeposit -= weightedAmount;

                userLock.isWithdrawed = true;
                totalActualDeposit -= amount;

                vestingCont.burn(msg.sender, amount);

                if (canWithdraw(_lid, _did, msg.sender)) {
                    token.safeTransfer(msg.sender, amount);
                } else {
                    if (!poolLock.forcedUnlockEnabled) revert ForcedUnlockDisabled();
                    uint256 feeAmount = (amount * poolLock.claimFee) / DIVISOR;
                    token.safeTransfer(feeWallet, feeAmount);
                    amount = amount - feeAmount;
                    token.safeTransfer(msg.sender, amount);
                }
            } else {
                if (user.totalDeposit < amount) revert InvalidAmount();

                user.totalDeposit = user.totalDeposit - amount;
                pool.totalDeposit = pool.totalDeposit - amount;

                token.safeTransfer(msg.sender, amount);
            }
        }

        user.rewardDebt = (user.totalDeposit * pool.accTknPerShare) / 1e12;
        emit Withdraw(msg.sender, _pid, _lid, _amounts);
    }

    /**
     * @dev Claims rewards for a specific pool.
     * @param _pid The ID of the pool.
     */
    function claimReward(uint256 _pid) external {
        _claimReward(_pid, msg.sender);
    }

    /**
     * @dev Sets the reward and fee wallets.
     * @param _reward The address of the reward wallet.
     * @param _feeWallet The address of the fee wallet.
     */
    function setWallets(address _reward, address _feeWallet) external onlyOwner {
        if (_reward == address(0) || _feeWallet == address(0)) revert ZeroAddress();
        rewardWallet = _reward;
        feeWallet = _feeWallet;
        emit WalletsChanged(_reward, _feeWallet);
    }

    /**
     * @dev Sets the percentage per day for rewards.
     * @param _perc The percentage per day.
     */
    function setPercentagePerDay(uint32 _perc) external onlyOwner {
        percPerDay = _perc;
        emit RewardChanged(_perc);
    }

    /**
     * @dev Sets the Vesting contract address.
     * @param _vesting The address of the Vesting contract.
     */
    function setVesting(address _vesting) external onlyOwner {
        if (_vesting == address(0)) revert ZeroAddress();
        vestingCont = IVesting(_vesting);
        emit VestingContractChanged(_vesting);
    }

    /**
     * @dev Sets the forced unlock state for multiple lock pools.
     * @param _lid The array of lock pool IDs.
     * @param _state The array of forced unlock states.
     */
    function setForcedUnlockState(uint256[] calldata _lid, bool[] calldata _state) external onlyOwner {
        if (_lid.length != _state.length) revert InvalidInput();
        uint256 length = _lid.length;
        for (uint256 i = 0; i < length; i++) {
            poolLockInfo[_lid[i]].forcedUnlockEnabled = _state[i];
        }
    }

    /**
     * @dev Sets the allocation points for multiple pools.
     * @param _pids The array of pool IDs.
     * @param _allocPoints The array of allocation points.
     */
    function setBulkAllocPoints(uint256[] calldata _pids, uint256[] calldata _allocPoints) external onlyOwner {
        if (_pids.length != _allocPoints.length || _pids.length != pools.length) revert InvalidInput();
        uint256 length = _pids.length;
        uint256 total = 0;
        massUpdatePools();
        for (uint256 i = 0; i < length; i++) {
            total += _allocPoints[i];
            pools[_pids[i]].allocPoint = _allocPoints[i];
        }
        totalAllocPoint = total;
    }

    /**
     * @dev Gets the deposited NFT IDs of a user in a specific pool.
     * @param _pid The ID of the pool.
     * @param _user The user's address.
     * @return An array of deposited NFT IDs.
     */
    function getDepositedIdsOfUser(uint256 _pid, address _user) external view returns (uint256[] memory) {
        return users[_pid][_user].deposits.values();
    }

    /**
     * @dev Gets the lock terms of a user in a specific lock pool.
     * @param _user The user's address.
     * @param _lid The ID of the lock pool.
     * @return count The number of lock terms and an array of UserLockInfo.
     */
    function getLockTermsOfUser(
        address _user,
        uint8 _lid
    ) external view returns (uint256 count, UserLockInfo[] memory) {
        return (userLockInfo[_lid][_user].length, userLockInfo[_lid][_user]);
    }

    /**
     * @dev Retrieves information about a pool.
     * @param _pid The ID of the pool.
     * @return isInputNFT Is pool for NFTs or not.
     * @return isVested Is reward vested or not.
     * @return totalInvestors Total investors in the pool.
     * @return input Address of input token.
     * @return allocPoint Allocation points for the pool.
     * @return lastRewardBlock Last block number that RFRMs distribution occurs.
     * @return accTknPerShare Accumulated RFRMs per share, times 1e12.
     * @return startIdx Start index of NFT (if applicable).
     * @return endIdx End index of NFT (if applicable).
     * @return totalDeposit Total deposits in the pool.
     */
    function poolInfo(
        uint256 _pid
    )
        external
        view
        returns (
            bool isInputNFT,
            bool isVested,
            uint32 totalInvestors,
            address input,
            uint256 allocPoint,
            uint256 lastRewardBlock,
            uint256 accTknPerShare,
            uint256 startIdx,
            uint256 endIdx,
            uint256 totalDeposit
        )
    {
        PoolInfo storage pool = pools[_pid];
        isInputNFT = pool.isInputNFT;
        isVested = pool.isVested;
        allocPoint = pool.allocPoint;
        lastRewardBlock = pool.lastRewardBlock;
        accTknPerShare = pool.accTknPerShare;
        totalDeposit = pool.totalDeposit;
        startIdx = pool.startIdx;
        endIdx = pool.endIdx;
        input = pool.input;
        totalInvestors = pool.totalInvestors;
    }

    /**
     * @dev Retrieves user information for a specific pool and user.
     * @param _pid The ID of the pool.
     * @param _user The user's address.
     * @return totalDeposit Total deposits of the user.
     * @return rewardDebt Reward debt of the user.
     * @return totalClaimed Total claimed rewards of the user.
     * @return depositTime Deposit time of the user.
     */
    function userInfo(
        uint256 _pid,
        address _user
    ) external view returns (uint256 totalDeposit, uint256 rewardDebt, uint256 totalClaimed, uint256 depositTime) {
        UserInfo storage user = users[_pid][_user];
        totalDeposit = user.totalDeposit;
        rewardDebt = user.rewardDebt;
        totalClaimed = user.totalClaimed;
        depositTime = user.depositTime;
    }

    /**
     * @dev Updates reward variables for all pools. Be careful of gas spending!
     */
    function massUpdatePools() public {
        uint256 length = pools.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /**
     * @dev Updates reward variables of a specific pool to be up-to-date.
     * @param _pid The ID of the pool to be updated.
     */
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = pools[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 total = pool.totalDeposit;
        if (total == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multi = block.number - pool.lastRewardBlock;
        uint256 rewardPerBlock = getRewardPerBlock();
        uint256 tknReward = (multi * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
        reward.safeTransferFrom(rewardWallet, address(this), tknReward);
        pool.accTknPerShare = pool.accTknPerShare + ((tknReward * 1e12) / total);
        pool.lastRewardBlock = block.number;
        emit PoolUpdated(_pid);
    }

    /**
     * @dev ERC721 receiver function to accept NFT deposits.
     * param operator The address that sent the NFT.
     * param from The address that transferred the NFT.
     * param tokenId The ID of the received NFT.
     * param data Additional data (not used in this contract).
     * @return The ERC721_RECEIVED selector.
     */
    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev Gets the reward per block.
     * @return rpb The reward per block.
     */
    function getRewardPerBlock() public view returns (uint256 rpb) {
        uint256 total = reward.balanceOf(rewardWallet);
        uint256 rewardPerDay = (total * percPerDay) / DIVISOR;
        rewardPerDay = rewardPerDay / 10; //Additional precision
        rpb = rewardPerDay / BLOCKS_PER_DAY;
    }

    /**
     * @dev Checks if a user can withdraw from a specific lock pool.
     * @param _lid The ID of the lock pool.
     * @param _did The ID of the user's deposit in the lock pool.
     * @param _user The user's address.
     * @return True if the user can withdraw, false otherwise.
     */
    function canWithdraw(uint8 _lid, uint256 _did, address _user) public view returns (bool) {
        return (block.timestamp >=
            userLockInfo[_lid][_user][_did].depositTime + poolLockInfo[_lid].lockPeriodInSeconds);
    }

    /**
     * @dev Internal function to claim rewards for a specific pool and user.
     * @param _pid The ID of the pool.
     * @param _user The user's address.
     */
    function _claimReward(uint256 _pid, address _user) internal {
        updatePool(_pid);
        UserInfo storage user = users[_pid][_user];

        if (user.totalDeposit == 0) {
            return;
        }
        uint256 pending = (user.totalDeposit * pools[_pid].accTknPerShare) / 1e12 - user.rewardDebt;

        if (pending > 0) {
            user.totalClaimed = user.totalClaimed + pending;
            user.rewardDebt = (user.totalDeposit * pools[_pid].accTknPerShare) / 1e12;
            if (pools[_pid].isVested) {
                vestingCont.addVesting(_user, pending);
                reward.safeTransfer(address(vestingCont), pending);
            } else {
                reward.safeTransfer(_user, pending);
            }
        }

        emit RewardClaimed(_user, _pid, pending);
    }
}
