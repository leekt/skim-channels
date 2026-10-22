// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IAppCheckpointVerifier} from "./IAppCheckpointVerifier.sol";
import {AppLeaves} from "./AppLeaves.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";

/// @notice L1 vault and checkpoint registry for app channels (docs/guide/app-channels.md).
///
/// - Assets (ETH = token 0, allow-listed ERC-20) stay here. Deposits and forced exit requests
///   are queued with L1 timestamps; checkpoints commit to how much of each queue they consumed.
/// - A checkpoint is accepted only if it extends the accepted predecessor with the next nonce
///   and its proof verifies against public inputs this contract computes from its own records:
///   config, predecessor, queue accumulators, claimed roots, anchor, and keccak256(data). The
///   `data` (the complete net state diff) is in this transaction's calldata: L1 DA.
/// - Fence: once a forced request is overdue (FORCE_DELAY after it was recorded) and the
///   accepted checkpoint hasn't consumed it, no live checkpoint is accepted, and anyone may
///   freeze. A frozen channel's snapshot never moves.
/// - Claims: cumulative withdrawal credits (any time, against the accepted credit root; pays
///   the increase over what was paid), exit allocations (after a terminal checkpoint, or after
///   the payout delay of a freeze), and refunds of deposits outside the consumed prefix
///   (after freeze or close). Per-token payouts never exceed per-token deposits.
contract AppChannelVault {
    enum Status {
        None,
        Live,
        Frozen,
        Closed
    }

    struct Config {
        address operator;
        IAppCheckpointVerifier verifier;
        bytes32 appConfigHash; // app program, contracts, rules (opaque here; bound by proofs)
        uint64 closeDeadline;
        uint32 payoutDelay; // frozen-root payout delay; clamped to [MIN_DELAY, MAX_DELAY]
        address[] tokens; // allow-listed; address(0) = ETH
    }

    struct Channel {
        Status status;
        IAppCheckpointVerifier verifier;
        uint64 closeDeadline;
        uint32 payoutDelay;
        uint64 frozenAt;
        uint64 nonce;
        uint64 depositCursor;
        uint64 forcedCursor;
        bytes32 configHash;
        bytes32 checkpointHash;
        bytes32 stateRoot;
        bytes32 exitRoot;
        bytes32 creditRoot;
    }

    struct Claim {
        bytes32 stateRoot;
        bytes32 exitRoot;
        bytes32 creditRoot;
        uint64 depositCursor;
        uint64 forcedCursor;
        bytes32 anchorId; // 0 = no L1 snapshot used by this batch
        bool terminal;
    }

    struct Deposit {
        address owner;
        address token;
        uint256 amount;
    }

    struct Forced {
        address account;
        address token;
        uint64 at;
    }

    uint256 public constant FORCE_DELAY = 1 days;
    uint32 public constant MIN_DELAY = 1 hours;
    uint32 public constant MAX_DELAY = 30 days;
    uint256 public constant MAX_DATA = 120_000;
    uint256 public constant MAX_TOKENS = 16;
    bytes32 internal constant GENESIS_TAG = keccak256("skim-app-channels/genesis/v0");
    bytes32 internal constant INPUTS_TAG = keccak256("skim-app-channels/checkpoint-inputs/v0");

    AnchorRegistry public immutable anchors;

    mapping(bytes32 => Channel) internal channels;
    mapping(bytes32 => mapping(address => bool)) public allowed;
    mapping(bytes32 => Deposit[]) internal depositQueue;
    mapping(bytes32 => bytes32[]) internal depositAcc; // depositAcc[i] covers deposits [0, i)
    mapping(bytes32 => Forced[]) internal forcedQueue;
    mapping(bytes32 => bytes32[]) internal forcedAcc;
    mapping(bytes32 => mapping(address => mapping(address => uint256))) public paidCredit;
    mapping(bytes32 => mapping(bytes32 => bool)) public exitClaimed;
    mapping(bytes32 => mapping(uint256 => bool)) public refunded;
    mapping(bytes32 => mapping(address => uint256)) public totalIn;
    mapping(bytes32 => mapping(address => uint256)) public totalOut;

    event Opened(bytes32 indexed channelId, bytes32 configHash);
    event Deposited(bytes32 indexed channelId, uint256 indexed index, address owner, address token, uint256 amount);
    event ForcedExit(bytes32 indexed channelId, uint256 indexed index, address account, address token);
    event CheckpointAccepted(bytes32 indexed channelId, uint64 indexed nonce, bytes32 checkpointHash, bytes32 dataHash);
    event Frozen(bytes32 indexed channelId, uint64 nonce);
    event Paid(bytes32 indexed channelId, address indexed to, address token, uint256 amount);

    error Invalid(string what);
    error WrongStatus(Status status);
    error Overdue();
    error NotYet();
    error InsufficientBacking();
    error TransferFailed();

    constructor(AnchorRegistry anchors_) {
        anchors = anchors_;
    }

    // ---- views -------------------------------------------------------------------------

    function channel(bytes32 id) external view returns (Channel memory) {
        return channels[id];
    }

    function deposits(bytes32 id, uint256 i) external view returns (Deposit memory) {
        return depositQueue[id][i];
    }

    function depositCount(bytes32 id) external view returns (uint256) {
        return depositQueue[id].length;
    }

    function forcedRequest(bytes32 id, uint256 i) external view returns (Forced memory) {
        return forcedQueue[id][i];
    }

    function forcedCount(bytes32 id) external view returns (uint256) {
        return forcedQueue[id].length;
    }

    function overdue(bytes32 id) public view returns (bool) {
        Channel storage c = channels[id];
        Forced[] storage q = forcedQueue[id];
        return c.forcedCursor < q.length && block.timestamp >= uint256(q[c.forcedCursor].at) + FORCE_DELAY;
    }

    /// @notice The public-inputs hash a checkpoint `claim` with `dataHash` must be proven for.
    function inputsHash(bytes32 id, Claim calldata claim, bytes32 dataHash) public view returns (bytes32) {
        Channel storage c = channels[id];
        return keccak256(
            abi.encode(
                INPUTS_TAG,
                block.chainid,
                address(this),
                id,
                c.configHash,
                c.checkpointHash,
                c.nonce + 1,
                claim,
                depositAcc[id][claim.depositCursor],
                forcedAcc[id][claim.forcedCursor],
                dataHash
            )
        );
    }

    // ---- lifecycle -----------------------------------------------------------------------

    function openChannel(Config calldata cfg, bytes32 salt) external returns (bytes32 id) {
        id = keccak256(abi.encode(block.chainid, address(this), msg.sender, salt));
        Channel storage c = channels[id];
        if (c.status != Status.None) revert WrongStatus(c.status);
        if (address(cfg.verifier) == address(0) || cfg.closeDeadline <= block.timestamp) revert Invalid("config");
        if (cfg.tokens.length == 0 || cfg.tokens.length > MAX_TOKENS) revert Invalid("tokens");
        for (uint256 i; i < cfg.tokens.length; ++i) {
            if (allowed[id][cfg.tokens[i]]) revert Invalid("duplicate token");
            allowed[id][cfg.tokens[i]] = true;
        }
        uint32 delay =
            cfg.payoutDelay < MIN_DELAY ? MIN_DELAY : (cfg.payoutDelay > MAX_DELAY ? MAX_DELAY : cfg.payoutDelay);
        bytes32 configHash = keccak256(abi.encode(cfg, delay));
        c.status = Status.Live;
        c.verifier = cfg.verifier;
        c.closeDeadline = cfg.closeDeadline;
        c.payoutDelay = delay;
        c.configHash = configHash;
        c.checkpointHash = keccak256(abi.encode(GENESIS_TAG, block.chainid, address(this), id, configHash));
        depositAcc[id].push(0);
        forcedAcc[id].push(0);
        emit Opened(id, configHash);
    }

    /// @notice Locks ETH (token 0, amount = msg.value) or an allow-listed ERC-20 (exact amount
    ///         received; fee-on-transfer and similar are rejected).
    function deposit(bytes32 id, address token, uint256 amount) external payable {
        Channel storage c = channels[id];
        if (c.status != Status.Live) revert WrongStatus(c.status);
        if (block.timestamp >= c.closeDeadline) revert Invalid("deadline");
        if (!allowed[id][token] || amount == 0) revert Invalid("token");
        if (token == address(0)) {
            if (msg.value != amount) revert Invalid("value");
        } else {
            if (msg.value != 0) revert Invalid("value");
            uint256 before = _balanceOf(token);
            _call(
                token,
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
            );
            if (_balanceOf(token) - before != amount) revert Invalid("received amount");
        }
        uint256 index = depositQueue[id].length;
        depositQueue[id].push(Deposit(msg.sender, token, amount));
        depositAcc[id].push(keccak256(abi.encode(depositAcc[id][index], index, msg.sender, token, amount)));
        totalIn[id][token] += amount;
        emit Deposited(id, index, msg.sender, token, amount);
    }

    /// @notice Forced "withdraw all of `token`" for the caller. Must be applied by a checkpoint
    ///         within FORCE_DELAY, or the channel can be frozen.
    function forceExit(bytes32 id, address token) external {
        Channel storage c = channels[id];
        if (c.status != Status.Live) revert WrongStatus(c.status);
        if (!allowed[id][token]) revert Invalid("token");
        uint256 index = forcedQueue[id].length;
        forcedQueue[id].push(Forced(msg.sender, token, uint64(block.timestamp)));
        forcedAcc[id].push(keccak256(abi.encode(forcedAcc[id][index], index, msg.sender, token, block.timestamp)));
        emit ForcedExit(id, index, msg.sender, token);
    }

    /// @notice Accepts the next checkpoint. Permissionless: the proof is the authority.
    function submitCheckpoint(bytes32 id, Claim calldata claim, bytes calldata data, bytes calldata proof) external {
        Channel storage c = channels[id];
        if (c.status != Status.Live) revert WrongStatus(c.status);
        if (overdue(id)) revert Overdue();
        if (!claim.terminal && block.timestamp >= c.closeDeadline) revert Invalid("deadline");
        if (claim.depositCursor < c.depositCursor || claim.depositCursor > depositQueue[id].length) {
            revert Invalid("deposit cursor");
        }
        if (claim.forcedCursor < c.forcedCursor || claim.forcedCursor > forcedQueue[id].length) {
            revert Invalid("forced cursor");
        }
        if (claim.anchorId != 0 && !anchors.recorded(claim.anchorId)) revert Invalid("anchor");
        if (data.length > MAX_DATA) revert Invalid("data size");
        bytes32 h = inputsHash(id, claim, keccak256(data));
        if (!c.verifier.verify(h, proof)) revert Invalid("proof");
        c.checkpointHash = h;
        c.nonce += 1;
        c.stateRoot = claim.stateRoot;
        c.exitRoot = claim.exitRoot;
        c.creditRoot = claim.creditRoot;
        c.depositCursor = claim.depositCursor;
        c.forcedCursor = claim.forcedCursor;
        if (claim.terminal) c.status = Status.Closed;
        emit CheckpointAccepted(id, c.nonce, h, keccak256(data));
    }

    /// @notice Anyone, once a forced request is overdue or the channel expired unclosed.
    function freeze(bytes32 id) external {
        Channel storage c = channels[id];
        if (c.status != Status.Live) revert WrongStatus(c.status);
        if (!overdue(id) && block.timestamp < c.closeDeadline) revert NotYet();
        c.status = Status.Frozen;
        c.frozenAt = uint64(block.timestamp);
        emit Frozen(id, c.nonce);
    }

    // ---- claims (anyone may submit them; funds go to the leaf's recipient) ----------------

    /// @notice Pays the increase of `recipient`'s cumulative withdrawal credit for `token`.
    function claimCredit(
        bytes32 id,
        address recipient,
        address token,
        uint256 cumulative,
        uint256 index,
        bytes32[] calldata siblings
    ) external {
        Channel storage c = channels[id];
        if (c.status == Status.None) revert WrongStatus(c.status);
        if (!AppLeaves.contains(c.creditRoot, AppLeaves.creditLeaf(recipient, token, cumulative), index, siblings)) {
            revert Invalid("credit proof");
        }
        uint256 paid = paidCredit[id][recipient][token];
        if (cumulative <= paid) revert Invalid("nothing owed");
        paidCredit[id][recipient][token] = cumulative;
        _pay(id, token, recipient, cumulative - paid);
    }

    /// @notice Pays an exit allocation at the final root: after a terminal checkpoint, or once
    ///         the payout delay of a freeze has passed. Once per (recipient, token).
    function claimExit(
        bytes32 id,
        address recipient,
        address token,
        uint256 amount,
        uint256 index,
        bytes32[] calldata siblings
    ) external {
        Channel storage c = channels[id];
        if (c.status == Status.Frozen) {
            if (block.timestamp < uint256(c.frozenAt) + c.payoutDelay) revert NotYet();
        } else if (c.status != Status.Closed) {
            revert WrongStatus(c.status);
        }
        bytes32 key = keccak256(abi.encode(recipient, token));
        if (exitClaimed[id][key]) revert Invalid("claimed");
        if (!AppLeaves.contains(c.exitRoot, AppLeaves.exitLeaf(recipient, token, amount), index, siblings)) {
            revert Invalid("exit proof");
        }
        exitClaimed[id][key] = true;
        _pay(id, token, recipient, amount);
    }

    /// @notice Returns a deposit the final checkpoint never consumed, to its depositor.
    function refundDeposit(bytes32 id, uint256 index) external {
        Channel storage c = channels[id];
        if (c.status != Status.Frozen && c.status != Status.Closed) revert WrongStatus(c.status);
        if (index < c.depositCursor || index >= depositQueue[id].length) revert Invalid("consumed");
        if (refunded[id][index]) revert Invalid("refunded");
        refunded[id][index] = true;
        Deposit memory d = depositQueue[id][index];
        _pay(id, d.token, d.owner, d.amount);
    }

    // ---- internals -------------------------------------------------------------------------

    function _pay(bytes32 id, address token, address to, uint256 amount) internal {
        if (totalOut[id][token] + amount > totalIn[id][token]) revert InsufficientBacking();
        totalOut[id][token] += amount;
        emit Paid(id, to, token, amount);
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            _call(token, abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        }
    }

    function _call(address token, bytes memory data) internal {
        if (token.code.length == 0) revert TransferFailed();
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && (ret.length != 32 || !abi.decode(ret, (bool))))) revert TransferFailed();
    }

    function _balanceOf(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || ret.length != 32) revert TransferFailed();
        return abi.decode(ret, (uint256));
    }
}
