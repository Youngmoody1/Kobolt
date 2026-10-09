// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title KoboltVesting
/// @notice A vesting vault for one token, created through KoboltModules.
///
///         The owner (the project that created the vault) locks tokens for
///         beneficiaries. Each schedule releases linearly from `start` to
///         `start + duration`, with nothing claimable before `start + cliff`.
///         Schedules can never be revoked or changed, and nobody, the owner
///         included, can take locked tokens out, so a team allocation in a vault
///         is provably locked. Only the beneficiary can claim. Times are unix seconds.
contract KoboltVesting is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Schedule {
        address beneficiary;
        uint64 start;
        uint64 cliff;
        uint64 duration;
        uint256 total;
        uint256 claimed;
    }

    uint64 public constant MAX_DURATION = 20 * 365 days;
    uint256 public constant MAX_BATCH = 200;

    IERC20 public immutable token;
    Schedule[] private _schedules;
    mapping(address => uint256[]) private _byBeneficiary;
    /// @notice Tokens still held for all schedules (total minus claimed).
    uint256 public totalLocked;

    event ScheduleCreated(
        uint256 indexed id, address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration
    );
    event Claimed(uint256 indexed id, address indexed beneficiary, uint256 amount);

    error InvalidToken();
    error InvalidBeneficiary();
    error InvalidAmount();
    error InvalidDuration();
    error CliffAfterEnd();
    error UnknownSchedule();
    error NotBeneficiary();
    error NothingToClaim();
    error LengthMismatch();
    error BatchTooLarge();
    error UnsupportedToken();
    error InvalidStart();

    constructor(IERC20 token_, address owner_) Ownable(owner_) {
        if (address(token_) == address(0)) revert InvalidToken();
        token = token_;
    }

    /// @notice Pulls `amount` from the owner (approve this vault first) and locks it for `beneficiary`.
    function createSchedule(address beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration)
        external
        onlyOwner
        nonReentrant
        returns (uint256 id)
    {
        id = _add(beneficiary, amount, start, cliff, duration);
        _pull(amount);
    }

    /// @notice Several schedules with the same timing in one transaction.
    function createSchedules(
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        uint64 start,
        uint64 cliff,
        uint64 duration
    ) external onlyOwner nonReentrant returns (uint256 firstId) {
        uint256 n = beneficiaries.length;
        if (n != amounts.length) revert LengthMismatch();
        if (n == 0) revert InvalidAmount();
        if (n > MAX_BATCH) revert BatchTooLarge();
        firstId = _schedules.length;
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            _add(beneficiaries[i], amounts[i], start, cliff, duration);
            total += amounts[i];
        }
        _pull(total);
    }

    /// @notice Sends everything vested and not yet claimed to the beneficiary.
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        Schedule storage s = _get(id);
        if (msg.sender != s.beneficiary) revert NotBeneficiary();
        amount = _vested(s, block.timestamp) - s.claimed;
        if (amount == 0) revert NothingToClaim();
        s.claimed += amount;
        totalLocked -= amount;
        token.safeTransfer(s.beneficiary, amount);
        emit Claimed(id, s.beneficiary, amount);
    }

    // ------------------------------------------------------------ views

    function scheduleCount() external view returns (uint256) {
        return _schedules.length;
    }

    function getSchedule(uint256 id) external view returns (Schedule memory) {
        return _get(id);
    }

    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _byBeneficiary[beneficiary];
    }

    function vested(uint256 id) external view returns (uint256) {
        return _vested(_get(id), block.timestamp);
    }

    function claimable(uint256 id) external view returns (uint256) {
        Schedule storage s = _get(id);
        return _vested(s, block.timestamp) - s.claimed;
    }

    // ------------------------------------------------------------ internal

    function _add(address beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration)
        private
        returns (uint256 id)
    {
        // The vault and the token can never call claim(), so tokens for them would be stuck forever.
        if (beneficiary == address(0) || beneficiary == address(this) || beneficiary == address(token)) {
            revert InvalidBeneficiary();
        }
        if (amount == 0) revert InvalidAmount();
        if (duration == 0 || duration > MAX_DURATION) revert InvalidDuration();
        // Guards against a start in milliseconds or far in the future, which would lock tokens for ages.
        if (start > block.timestamp + MAX_DURATION) revert InvalidStart();
        if (cliff > duration) revert CliffAfterEnd();
        id = _schedules.length;
        _schedules.push(Schedule(beneficiary, start, cliff, duration, amount, 0));
        _byBeneficiary[beneficiary].push(id);
        totalLocked += amount;
        emit ScheduleCreated(id, beneficiary, amount, start, cliff, duration);
    }

    /// @dev Tokens that take a fee on transfer would leave the vault short, so they are refused.
    function _pull(uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert UnsupportedToken();
    }

    function _get(uint256 id) private view returns (Schedule storage) {
        if (id >= _schedules.length) revert UnknownSchedule();
        return _schedules[id];
    }

    function _vested(Schedule storage s, uint256 now_) private view returns (uint256) {
        if (now_ < uint256(s.start) + s.cliff) return 0;
        uint256 elapsed = now_ - s.start;
        if (elapsed >= s.duration) return s.total;
        return (s.total * elapsed) / s.duration;
    }
}
