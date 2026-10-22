// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {WitnessVerifier} from "../verifiers/WitnessVerifier.sol";
import {WitnessLib} from "../libraries/WitnessLib.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";
import {ClearingChecker} from "./ClearingChecker.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice L1: escrow and net settlement for the clearing app. Holds the real money,
///         finalized balances and payout records; nothing else. The app's own state (book,
///         nonces, unsettled obligations) lives on its executor and is never trusted here.
///
/// A batch is the app's fills under one L1 anchor. `proposeBatch` publishes every fill (both
/// signed orders) and the witness of the L1 price in calldata, and L1 re-checks each fill's
/// economics itself with the same ClearingRules the app ran: price band against the
/// witnessed L1 price at a recorded, recent anchor; limit prices; expiry; per-trader nonces
/// strictly increasing past the finalized floor; and, after netting, every trader's balance
/// minus reserved withdrawals stays ≥ 0 per token. Only signatures are optimistic:
/// `challengeSignature` (one order, one ecrecover) discards the batch and pays the bond to
/// the challenger. After `challengeWindow`, anyone `finalize`s the net per-trader changes.
///
/// Withdrawals: `requestWithdraw` reserves part of a balance at once (later batches can't
/// spend it); `claimWithdraw` pays after every batch proposed before the request is
/// resolved. No operator is needed for any of it: a pending batch finalizes or is discarded
/// without one, and finalized balances are always withdrawable.
contract ClearingSettlement {
    uint256 public constant MIN_CHALLENGE_WINDOW = 1 hours;
    /// Upper bounds keep `at + window` far from overflow and anchors within EIP-2935's reach.
    uint256 public constant MAX_CHALLENGE_WINDOW = 30 days;
    uint256 public constant MAX_ANCHOR_AGE = 8191;

    struct Account {
        uint128 ethBal;
        uint128 usdBal;
        uint128 ethReserved;
        uint128 usdReserved;
        uint64 nonceFloor; // highest order nonce settled
    }

    struct Withdrawal {
        address user;
        uint8 token;
        uint128 amount;
        uint64 afterProposal; // claimable once this many proposals are resolved
        bool done;
    }

    struct Pending {
        bytes32 fillsHash;
        bytes32 effectsHash;
        uint64 at;
        uint64 batchNo;
        bool live;
    }

    struct Config {
        address operator;
        IERC20Min usd;
        AnchorRegistry anchors;
        WitnessVerifier witnessVerifier;
        address priceFeed; // L1 contract whose slot holds USD (6 dec) per ETH
        bytes32 priceSlot;
        uint256 bandBps;
        uint256 challengeWindow;
        uint256 maxAnchorAge; // blocks between the batch anchor and the proposal
        uint256 minBond;
        ClearingChecker checker;
    }

    // Storage layout is read by the app through L1 witnesses: keep these two first.
    uint256 public finalizedBatches; // slot 0
    mapping(address => Account) public accounts; // slot 1

    Withdrawal[] public withdrawals;
    uint256 public proposals;
    uint256 public resolved;
    Pending public pending;
    uint256 public bond;

    address public immutable operator;
    IERC20Min public immutable usd;
    AnchorRegistry public immutable anchors;
    WitnessVerifier public immutable witnessVerifier;
    address public immutable priceFeed;
    bytes32 public immutable priceSlot;
    uint256 public immutable bandBps;
    uint256 public immutable challengeWindow;
    uint256 public immutable maxAnchorAge;
    uint256 public immutable minBond;
    bytes32 public immutable domain;
    ClearingChecker public immutable checker;

    event Deposited(address indexed user, uint8 token, uint256 amount);
    event WithdrawRequested(uint256 indexed id, address indexed user, uint8 token, uint256 amount);
    event Withdrawn(uint256 indexed id, address indexed user, uint8 token, uint256 paid);
    event BatchProposed(
        uint64 indexed batchNo,
        bytes32 fillsHash,
        bytes32 anchorId,
        uint256 price,
        address[] users,
        int256[] dEth,
        int256[] dUsd,
        uint64[] nonces
    );
    event BatchFinalized(uint64 indexed batchNo);
    event BatchDiscarded(uint64 indexed batchNo, address challenger);

    error WrongState();
    error BadPolicy();
    error BadAnchor();
    error NotWrong();
    error BalanceOutOfRange();
    error TransferFailed();

    constructor(Config memory c) {
        if (
            c.challengeWindow < MIN_CHALLENGE_WINDOW || c.challengeWindow > MAX_CHALLENGE_WINDOW || c.bandBps > 10_000
                || c.maxAnchorAge > MAX_ANCHOR_AGE
        ) revert BadPolicy();
        operator = c.operator;
        usd = c.usd;
        anchors = c.anchors;
        witnessVerifier = c.witnessVerifier;
        priceFeed = c.priceFeed;
        priceSlot = c.priceSlot;
        bandBps = c.bandBps;
        challengeWindow = c.challengeWindow;
        maxAnchorAge = c.maxAnchorAge;
        minBond = c.minBond;
        checker = c.checker;
        domain = R.domainSeparator(block.chainid, address(this));
    }

    // ---- money in and out --------------------------------------------------------------------

    function postBond() external payable {
        bond += msg.value;
    }

    function deposit(uint8 token, uint128 amount) external payable {
        Account storage a = accounts[msg.sender];
        if (token == R.ETH) {
            if (msg.value != amount || amount == 0) revert WrongState();
            a.ethBal += amount;
        } else if (token == R.USD) {
            if (msg.value != 0 || amount == 0) revert WrongState();
            if (!usd.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
            a.usdBal += amount;
        } else {
            revert WrongState();
        }
        emit Deposited(msg.sender, token, amount);
    }

    /// @notice Reserve `amount` now; it's paid once every batch proposed before this request
    ///         is resolved. Later batches see it as unavailable, so trading continues on the
    ///         rest and no counterparty's fill depends on it.
    function requestWithdraw(uint8 token, uint128 amount) external returns (uint256 id) {
        Account storage a = accounts[msg.sender];
        if (token == R.ETH) {
            if (amount == 0 || amount > _free(a.ethBal, a.ethReserved)) revert WrongState();
            a.ethReserved += amount;
        } else if (token == R.USD) {
            if (amount == 0 || amount > _free(a.usdBal, a.usdReserved)) revert WrongState();
            a.usdReserved += amount;
        } else {
            revert WrongState();
        }
        id = withdrawals.length;
        withdrawals.push(Withdrawal(msg.sender, token, amount, uint64(proposals), false));
        emit WithdrawRequested(id, msg.sender, token, amount);
    }

    /// @notice Pays the reserved amount, capped by the balance after the batches that were
    ///         already in flight when it was requested.
    function claimWithdraw(uint256 id) external {
        Withdrawal storage w = withdrawals[id];
        if (w.done || resolved < w.afterProposal) revert WrongState();
        w.done = true;
        Account storage a = accounts[w.user];
        uint128 paid;
        if (w.token == R.ETH) {
            paid = w.amount < a.ethBal ? w.amount : a.ethBal;
            a.ethBal -= paid;
            a.ethReserved -= w.amount;
            (bool ok,) = w.user.call{value: paid}("");
            if (!ok) revert TransferFailed();
        } else {
            paid = w.amount < a.usdBal ? w.amount : a.usdBal;
            a.usdBal -= paid;
            a.usdReserved -= w.amount;
            if (!usd.transfer(w.user, paid)) revert TransferFailed();
        }
        emit Withdrawn(id, w.user, w.token, paid);
    }

    // ---- batches ------------------------------------------------------------------------------

    /// @param witness the L1 price slot at the batch anchor (recorded in AnchorRegistry, at
    ///        most maxAnchorAge blocks old)
    /// @param fills abi.encode(ClearingRules.Fill[]), in the order the app executed them
    /// @param users every trader in the batch, strictly ascending
    /// @param at for each fill, the indices in `users` of its two traders (a, then b)
    function proposeBatch(
        uint64 batchNo,
        bytes calldata witness,
        bytes calldata fills,
        address[] calldata users,
        uint16[] calldata at
    ) external {
        if (msg.sender != operator || pending.live || bond < minBond || batchNo != finalizedBatches + 1) {
            revert WrongState();
        }
        (uint256 price, uint64 anchorBlock, bytes32 anchorId) = _price(witness);
        uint256 n = users.length;
        uint64[] memory floors = new uint64[](n);
        uint256[2][] memory free = new uint256[2][](n);
        for (uint256 i; i < n; ++i) {
            Account storage acc = accounts[users[i]];
            floors[i] = acc.nonceFloor;
            free[i] = [_free(acc.ethBal, acc.ethReserved), _free(acc.usdBal, acc.usdReserved)];
        }
        (int256[] memory dEth, int256[] memory dUsd, uint64[] memory nonces) =
            checker.net(fills, users, at, floors, free, ClearingChecker.Market(price, bandBps, anchorBlock));
        pending = Pending(
            keccak256(fills),
            keccak256(abi.encode(batchNo, users, dEth, dUsd, nonces)),
            uint64(block.timestamp),
            batchNo,
            true
        );
        proposals += 1;
        emit BatchProposed(batchNo, keccak256(fills), anchorId, price, users, dEth, dUsd, nonces);
    }

    /// @notice One order in the pending batch isn't signed by its trader.
    function challengeSignature(bytes calldata fills, uint256 f, bool sideB) external {
        if (!pending.live || block.timestamp >= pending.at + challengeWindow) revert WrongState();
        if (keccak256(fills) != pending.fillsHash) revert WrongState();
        if (!checker.badSignature(domain, fills, f, sideB)) revert NotWrong();
        uint64 b = pending.batchNo;
        delete pending;
        resolved += 1;
        emit BatchDiscarded(b, msg.sender);
        uint256 x = bond;
        bond = 0;
        (bool ok,) = msg.sender.call{value: x}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Anyone, after the window: apply the batch's net changes (from BatchProposed).
    function finalize(
        address[] calldata users,
        int256[] calldata dEth,
        int256[] calldata dUsd,
        uint64[] calldata nonces
    ) external {
        Pending memory p = pending;
        if (!p.live || block.timestamp < p.at + challengeWindow) revert WrongState();
        if (keccak256(abi.encode(p.batchNo, users, dEth, dUsd, nonces)) != p.effectsHash) revert WrongState();
        for (uint256 i; i < users.length; ++i) {
            Account storage a = accounts[users[i]];
            a.ethBal = _toBalance(int256(uint256(a.ethBal)) + dEth[i]);
            a.usdBal = _toBalance(int256(uint256(a.usdBal)) + dUsd[i]);
            a.nonceFloor = nonces[i];
        }
        delete pending;
        finalizedBatches += 1;
        resolved += 1;
        emit BatchFinalized(p.batchNo);
    }

    function withdrawalCount() external view returns (uint256) {
        return withdrawals.length;
    }

    /// The L1 price at a recorded anchor no older than maxAnchorAge.
    function _price(bytes calldata witness) internal view returns (uint256 price, uint64 blockNumber, bytes32 id) {
        (ChannelTypes.L1Anchor memory an, WitnessLib.Read[] memory reads) = witnessVerifier.verify(witness);
        id = ChannelTypes.anchorId(an);
        if (
            an.chainId != block.chainid || an.stateRoot == 0 || anchors.stateRootOf(id) != an.stateRoot
                || block.number > an.blockNumber + maxAnchorAge
        ) revert BadAnchor();
        price = WitnessLib.find(reads, priceFeed, priceSlot);
        blockNumber = an.blockNumber;
    }

    /// An explicit range check: a narrowing cast alone would silently truncate.
    function _toBalance(int256 v) internal pure returns (uint128) {
        if (v < 0 || v > int256(uint256(type(uint128).max))) revert BalanceOutOfRange();
        return uint128(uint256(v));
    }

    /// Balance not reserved for withdrawals. A request made while a batch was pending can
    /// leave the balance below the reservation after it settles; then nothing is free.
    function _free(uint128 bal, uint128 reserved) internal pure returns (uint256) {
        return bal > reserved ? bal - reserved : 0;
    }
}
