// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KoboltVesting} from "./KoboltVesting.sol";
import {KoboltStakingPool} from "./KoboltStakingPool.sol";

/// @title KoboltModules
/// @notice Kobolt's add-on modules for any ERC-20 token, each for a small fee in ETH:
///
///         - Vesting:        creates a KoboltVesting vault owned by the caller.
///         - Staking:        creates a KoboltStakingPool owned by the caller.
///         - Airdrop:        sends tokens from the caller to many wallets in one transaction.
///         - Liquidity lock: locks ERC-20 LP tokens (or an LP position NFT) until a set time.
///
///         `prices` holds the fee for each module; the caller pays it exactly and it goes
///         straight to `treasury`. The owner of this contract can change prices (each capped
///         at MAX_PRICE) and the treasury, nothing else: it has no power over vaults, pools
///         or locked assets, and locked assets can only ever leave to the lock's owner after
///         its unlock time.
contract KoboltModules is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PRICE = 0.02 ether;
    uint256 public constant MAX_AIRDROP_RECIPIENTS = 500;
    uint256 public constant MAX_LOCK_DURATION = 50 * 365 days;

    struct Prices {
        uint256 vesting;
        uint256 staking;
        uint256 airdrop;
        uint256 lock;
    }

    enum AssetKind {
        ERC20,
        ERC721
    }

    struct Lock {
        address owner;
        address asset;
        AssetKind kind;
        uint64 unlockAt;
        bool withdrawn;
        uint256 amount; // ERC-20 amount, or the NFT token id
    }

    Prices public prices;
    address payable public treasury;

    /// @notice True for every vault and pool created here, so anyone can verify them.
    mapping(address => bool) public isKoboltModule;
    mapping(address => address[]) private _vaultsByToken;
    mapping(address => address[]) private _poolsByToken;
    mapping(address => address[]) private _modulesByCreator;

    Lock[] private _locks;
    mapping(address => uint256[]) private _locksByOwner;
    mapping(address => uint256[]) private _locksByAsset;
    /// @dev NFTs currently held for a lock, so one NFT can never back two locks.
    mapping(address => mapping(uint256 => bool)) private _nftLocked;

    uint256 public totalVaults;
    uint256 public totalPools;
    uint256 public totalAirdrops;

    event VestingCreated(address indexed vault, address indexed token, address indexed creator, uint256 feePaid);
    event StakingPoolCreated(address indexed pool, address indexed token, address indexed creator, uint256 feePaid);
    event Airdropped(address indexed token, address indexed sender, uint256 recipients, uint256 total, uint256 feePaid);
    event Locked(
        uint256 indexed id, address indexed owner, address indexed asset, AssetKind kind, uint256 amount, uint64 unlockAt
    );
    event LockExtended(uint256 indexed id, uint64 unlockAt);
    event LockTransferred(uint256 indexed id, address indexed from, address indexed to);
    event Unlocked(uint256 indexed id, address indexed owner, uint256 amount);
    event PricesChanged(uint256 vesting, uint256 staking, uint256 airdrop, uint256 lock);
    event TreasuryChanged(address oldTreasury, address newTreasury);

    error WrongFee(uint256 expected, uint256 sent);
    error FeeTooHigh();
    error ZeroAddress();
    error FeeTransferFailed();
    error LengthMismatch();
    error NoRecipients();
    error TooManyRecipients();
    error InvalidAmount();
    error InvalidUnlockTime();
    error UnknownLock();
    error NotLockOwner();
    error StillLocked();
    error AlreadyWithdrawn();
    error UnsupportedToken();
    error NotNftOwner();
    error NftAlreadyLocked();
    error UseLockNft();

    constructor(address initialOwner, address payable treasury_, Prices memory prices_) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        _setPrices(prices_);
    }

    // ------------------------------------------------------------ vesting

    /// @notice Creates a vesting vault for `token`, owned by the caller.
    function createVesting(IERC20 token) external payable nonReentrant returns (address vault) {
        if (address(token) == address(0)) revert ZeroAddress();
        _takeFee(prices.vesting);
        vault = address(new KoboltVesting(token, msg.sender));
        isKoboltModule[vault] = true;
        _vaultsByToken[address(token)].push(vault);
        _modulesByCreator[msg.sender].push(vault);
        totalVaults++;
        emit VestingCreated(vault, address(token), msg.sender, msg.value);
    }

    // ------------------------------------------------------------ staking

    /// @notice Creates a staking pool for `token`, owned by the caller. See KoboltStakingPool.
    function createStakingPool(IERC20 token, uint256 maxAprBps, uint256 duration, uint256 maturity)
        external
        payable
        nonReentrant
        returns (address pool)
    {
        if (address(token) == address(0)) revert ZeroAddress();
        _takeFee(prices.staking);
        pool = address(new KoboltStakingPool(token, msg.sender, maxAprBps, duration, maturity));
        isKoboltModule[pool] = true;
        _poolsByToken[address(token)].push(pool);
        _modulesByCreator[msg.sender].push(pool);
        totalPools++;
        emit StakingPoolCreated(pool, address(token), msg.sender, msg.value);
    }

    // ------------------------------------------------------------ airdrop

    /// @notice Sends `amounts[i]` of `token` from the caller to `recipients[i]`.
    ///         Approve this contract for the total first. All transfers succeed or none do.
    function airdrop(IERC20 token, address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
        returns (uint256 total)
    {
        uint256 n = recipients.length;
        if (n != amounts.length) revert LengthMismatch();
        if (n == 0) revert NoRecipients();
        if (n > MAX_AIRDROP_RECIPIENTS) revert TooManyRecipients();
        _takeFee(prices.airdrop);
        for (uint256 i = 0; i < n; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (amounts[i] == 0) revert InvalidAmount();
            token.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
            total += amounts[i];
        }
        totalAirdrops++;
        emit Airdropped(address(token), msg.sender, n, total, msg.value);
    }

    // ------------------------------------------------------------ liquidity lock

    /// @notice Locks `amount` of an ERC-20 (usually LP tokens) until `unlockAt`. Approve this contract first.
    function lockTokens(IERC20 asset, uint256 amount, uint64 unlockAt)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (address(asset) == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        _checkUnlock(unlockAt, block.timestamp);
        // An NFT sent here would be stuck: withdraw() sends ERC-20s with transfer(), which NFTs don't have.
        if (_isErc721(address(asset))) revert UseLockNft();
        _takeFee(prices.lock);
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - before != amount) revert UnsupportedToken();
        id = _newLock(address(asset), AssetKind.ERC20, amount, unlockAt);
    }

    /// @notice Locks an LP position NFT (for example a Uniswap v3 position) until `unlockAt`.
    ///         Approve this contract for the NFT first.
    function lockNft(IERC721 asset, uint256 tokenId, uint64 unlockAt)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (address(asset) == address(0)) revert ZeroAddress();
        _checkUnlock(unlockAt, block.timestamp);
        if (_nftLocked[address(asset)][tokenId]) revert NftAlreadyLocked();
        if (asset.ownerOf(tokenId) != msg.sender) revert NotNftOwner();
        _takeFee(prices.lock);
        asset.transferFrom(msg.sender, address(this), tokenId);
        if (asset.ownerOf(tokenId) != address(this)) revert UnsupportedToken();
        _nftLocked[address(asset)][tokenId] = true;
        id = _newLock(address(asset), AssetKind.ERC721, tokenId, unlockAt);
    }

    /// @notice Moves the unlock time later. It can never be moved earlier.
    function extendLock(uint256 id, uint64 newUnlockAt) external {
        Lock storage l = _ownLock(id);
        if (newUnlockAt <= l.unlockAt) revert InvalidUnlockTime();
        _checkUnlock(newUnlockAt, block.timestamp);
        l.unlockAt = newUnlockAt;
        emit LockExtended(id, newUnlockAt);
    }

    /// @notice Hands the lock (and the right to withdraw it later) to another wallet.
    function transferLock(uint256 id, address to) external {
        if (to == address(0)) revert ZeroAddress();
        Lock storage l = _ownLock(id);
        emit LockTransferred(id, l.owner, to);
        l.owner = to;
        _locksByOwner[to].push(id);
    }

    /// @notice Returns the locked asset to the lock owner once `unlockAt` has passed.
    function withdraw(uint256 id) external nonReentrant {
        Lock storage l = _ownLock(id);
        if (block.timestamp < l.unlockAt) revert StillLocked();
        l.withdrawn = true;
        if (l.kind == AssetKind.ERC20) {
            IERC20(l.asset).safeTransfer(l.owner, l.amount);
        } else {
            _nftLocked[l.asset][l.amount] = false;
            IERC721(l.asset).transferFrom(address(this), l.owner, l.amount);
        }
        emit Unlocked(id, l.owner, l.amount);
    }

    // ------------------------------------------------------------ views

    function vaultsOf(address token) external view returns (address[] memory) {
        return _vaultsByToken[token];
    }

    function poolsOf(address token) external view returns (address[] memory) {
        return _poolsByToken[token];
    }

    function modulesByCreator(address creator) external view returns (address[] memory) {
        return _modulesByCreator[creator];
    }

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    function getLock(uint256 id) external view returns (Lock memory) {
        if (id >= _locks.length) revert UnknownLock();
        return _locks[id];
    }

    /// @notice Lock ids this wallet owns or has owned (check `getLock(id).owner` for the current owner).
    function locksOf(address owner_) external view returns (uint256[] memory) {
        return _locksByOwner[owner_];
    }

    function locksByAsset(address asset) external view returns (uint256[] memory) {
        return _locksByAsset[asset];
    }

    /// @notice Paged versions of locksOf / locksByAsset, for wallets or assets with very many locks.
    function locksOfPaged(address owner_, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _slice(_locksByOwner[owner_], offset, limit);
    }

    function locksByAssetPaged(address asset, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _slice(_locksByAsset[asset], offset, limit);
    }

    function locksOfCount(address owner_) external view returns (uint256) {
        return _locksByOwner[owner_].length;
    }

    function locksByAssetCount(address asset) external view returns (uint256) {
        return _locksByAsset[asset].length;
    }

    // ------------------------------------------------------------ owner

    function setPrices(Prices calldata newPrices) external onlyOwner {
        _setPrices(newPrices);
    }

    function setTreasury(address payable newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    // ------------------------------------------------------------ internal

    function _takeFee(uint256 fee) private {
        if (msg.value != fee) revert WrongFee(fee, msg.value);
        if (fee > 0) {
            (bool ok,) = treasury.call{value: fee}("");
            if (!ok) revert FeeTransferFailed();
        }
    }

    function _setPrices(Prices memory p) private {
        if (p.vesting > MAX_PRICE || p.staking > MAX_PRICE || p.airdrop > MAX_PRICE || p.lock > MAX_PRICE) {
            revert FeeTooHigh();
        }
        prices = p;
        emit PricesChanged(p.vesting, p.staking, p.airdrop, p.lock);
    }

    function _checkUnlock(uint64 unlockAt, uint256 now_) private pure {
        if (unlockAt <= now_ || unlockAt > now_ + MAX_LOCK_DURATION) revert InvalidUnlockTime();
    }

    function _newLock(address asset, AssetKind kind, uint256 amount, uint64 unlockAt) private returns (uint256 id) {
        id = _locks.length;
        _locks.push(Lock(msg.sender, asset, kind, unlockAt, false, amount));
        _locksByOwner[msg.sender].push(id);
        _locksByAsset[asset].push(id);
        emit Locked(id, msg.sender, asset, kind, amount, unlockAt);
    }

    function _slice(uint256[] storage list, uint256 offset, uint256 limit) private view returns (uint256[] memory out) {
        uint256 n = list.length;
        if (offset >= n) return new uint256[](0);
        uint256 end = offset + limit > n ? n : offset + limit;
        out = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = list[i];
        }
    }

    function _isErc721(address asset) private view returns (bool) {
        try IERC165(asset).supportsInterface(0x80ac58cd) returns (bool yes) {
            return yes;
        } catch {
            return false;
        }
    }

    function _ownLock(uint256 id) private view returns (Lock storage l) {
        if (id >= _locks.length) revert UnknownLock();
        l = _locks[id];
        if (msg.sender != l.owner) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
    }
}
