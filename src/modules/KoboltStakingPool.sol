// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title KoboltStakingPool
/// @notice Holders stake a token and earn the same token as rewards. Created through KoboltModules.
///
///         - Stake and unstake at any time; no lock and no waiting period.
///         - The owner funds rewards; each funding spreads everything not yet paid
///           out evenly over the next `duration`. Funding 0 re-spreads what is left.
///         - Payouts are capped at `maxAprBps` per year of the total staked
///           (1000 = 10 %, 0 = no cap). Rewards held back by the cap stay in the pool.
///         - "Qualified" stake counts only tokens staked for at least `maturity`,
///           for perks such as fee discounts.
///
///         The owner can fund rewards and hand over ownership, nothing else: staked
///         tokens and funded rewards can never be taken out by the owner.
///         Times are unix seconds.
contract KoboltStakingPool is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Account {
        uint256 mature;
        uint256 pending;
        uint64 pendingSince;
        uint256 rewardPerTokenPaid;
        uint256 rewards;
    }

    uint256 private constant PRECISION = 1e18;
    uint256 private constant YEAR = 365 days;

    IERC20 public immutable token;
    uint256 public immutable maxAprBps;
    uint256 public immutable duration;
    uint256 public immutable maturity;

    uint256 public totalStaked;
    uint256 public periodFinish;
    uint256 private _rate; // reward per second, scaled by PRECISION
    uint256 private _last;
    uint256 private _rpt;
    uint256 private _pool;
    mapping(address => Account) private _accounts;

    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event Funded(uint256 amount, uint256 pool, uint256 periodFinish);

    error InvalidParameter();
    error InvalidAmount();
    error MoreThanStaked();
    error NothingToClaim();
    error UnsupportedToken();

    constructor(IERC20 token_, address owner_, uint256 maxAprBps_, uint256 duration_, uint256 maturity_)
        Ownable(owner_)
    {
        if (address(token_) == address(0) || maxAprBps_ > 100_000) revert InvalidParameter();
        if (duration_ < 1 days || duration_ > 10 * YEAR || maturity_ > YEAR) revert InvalidParameter();
        token = token_;
        maxAprBps = maxAprBps_;
        duration = duration_;
        maturity = maturity_;
        _last = block.timestamp;
    }

    // ------------------------------------------------------------ owner

    /// @notice Adds rewards (approve this pool first) and spreads the whole remaining pool over `duration`.
    function fund(uint256 amount) external onlyOwner nonReentrant {
        _updatePool();
        if (amount > 0) _pull(amount);
        _pool += amount;
        if (_pool == 0) revert InvalidAmount();
        _rate = (_pool * PRECISION) / duration;
        periodFinish = block.timestamp + duration;
        _last = block.timestamp;
        emit Funded(amount, _pool, periodFinish);
    }

    // ------------------------------------------------------------ stakers

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        Account storage a = _updateAccount(msg.sender);
        _matureIfDue(a);
        _pull(amount);
        a.pending += amount;
        a.pendingSince = uint64(block.timestamp);
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraws staked tokens. Allowed at any time; newest tokens leave first.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        Account storage a = _updateAccount(msg.sender);
        _matureIfDue(a);
        if (a.mature + a.pending < amount) revert MoreThanStaked();
        uint256 fromPending = amount <= a.pending ? amount : a.pending;
        a.pending -= fromPending;
        a.mature -= amount - fromPending;
        totalStaked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant returns (uint256 reward) {
        Account storage a = _updateAccount(msg.sender);
        reward = a.rewards;
        if (reward == 0) revert NothingToClaim();
        a.rewards = 0;
        token.safeTransfer(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    // ------------------------------------------------------------ views

    function stakeOf(address account) external view returns (uint256) {
        Account storage a = _accounts[account];
        return a.mature + a.pending;
    }

    function qualifiedStakeOf(address account) external view returns (uint256) {
        Account storage a = _accounts[account];
        return a.mature + (block.timestamp - a.pendingSince >= maturity ? a.pending : 0);
    }

    function earned(address account) external view returns (uint256) {
        Account storage a = _accounts[account];
        return a.rewards + ((a.mature + a.pending) * (_rewardPerToken() - a.rewardPerTokenPaid)) / PRECISION;
    }

    /// @notice Funded rewards not yet handed out to stakers.
    function undistributed() external view returns (uint256) {
        return _pool - _pendingEmission();
    }

    /// @notice Reward tokens per year at the current rate, before the APR cap.
    function rewardsPerYear() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (_rate * YEAR) / PRECISION;
    }

    // ------------------------------------------------------------ accounting

    function _pull(uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert UnsupportedToken();
    }

    function _pendingEmission() private view returns (uint256 emitted) {
        uint256 end = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (totalStaked == 0 || end <= _last) return 0;
        uint256 dt = end - _last;
        emitted = (_rate * dt) / PRECISION;
        if (maxAprBps > 0) {
            uint256 cap = (totalStaked * maxAprBps * dt) / (10_000 * YEAR);
            if (emitted > cap) emitted = cap;
        }
        if (emitted > _pool) emitted = _pool;
    }

    function _rewardPerToken() private view returns (uint256) {
        if (totalStaked == 0) return _rpt;
        return _rpt + (_pendingEmission() * PRECISION) / totalStaked;
    }

    function _updatePool() private {
        uint256 emitted = _pendingEmission();
        if (totalStaked > 0) _rpt += (emitted * PRECISION) / totalStaked;
        _pool -= emitted;
        uint256 end = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (end > _last) _last = end;
    }

    function _updateAccount(address account) private returns (Account storage a) {
        _updatePool();
        a = _accounts[account];
        a.rewards += ((a.mature + a.pending) * (_rpt - a.rewardPerTokenPaid)) / PRECISION;
        a.rewardPerTokenPaid = _rpt;
    }

    function _matureIfDue(Account storage a) private {
        if (a.pending > 0 && block.timestamp - a.pendingSince >= maturity) {
            a.mature += a.pending;
            a.pending = 0;
        }
    }
}
