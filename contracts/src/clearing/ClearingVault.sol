// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IERC20Lite, ClearingStorage} from "./ClearingStorage.sol";
import {ClearingRules as R} from "./ClearingRules.sol";
import {Clone1167} from "./Clone1167.sol";

interface IClearingSession {
    function depositFor(address user, uint8 token, uint128 amount) external payable;
    function initialize(ClearingStorage.Config calldata c) external;
}

/// @notice The stable side of a clearing app: its identity and users' free balances, which
///         outlive any one execution session (ClearingChannel). Sessions come and go:
///
///             vault ── session 1: run → close ── session 2: run → close ── …
///
/// - **Each session holds its own liabilities.** The vault never takes funds out of a
///   session. A closed session's entitlements stay there until each user redeems them, to
///   their wallet or into this vault; both go through the session's one payout record, so
///   an entitlement can't be paid twice or used to fund another session while still owed.
/// - **Credits are backed.** `credit` (from a registered session) takes the ETH with the call
///   and requires the USD to be here already.
/// - **Funding a session is the user's choice.** Only the user moves their free balance into
///   a session (`fund`), and only into one registered here.
/// - **Opening a session is registering its configuration.** The owner calls `openSession` with
///   a session implementation (a ClearingChannel deployed once) and the session's policy; the
///   vault creates a 45-byte minimal proxy of it, initializes it with this vault, its token and
///   the next id, all in one transaction. A new implementation is how a new session opts into
///   new code. The id is the salt of the session's EIP-712 domain, so orders signed for one
///   session never verify in another.
contract ClearingVault {
    struct Totals {
        uint128 eth;
        uint128 usd;
    }

    address public immutable owner;
    IERC20Lite public immutable usd;
    address[] public sessions;
    mapping(address => uint64) public sessionIdOf;
    mapping(address => Totals) internal _free;
    Totals public totalFree;

    event SessionOpened(uint64 indexed id, address session, address implementation);
    event Credited(address indexed user, address indexed session, uint128 eth, uint128 usd);
    event Funded(address indexed user, address indexed session, uint8 token, uint128 amount);
    event Withdrawn(address indexed user, uint8 token, uint128 amount);

    error WrongState();
    error TransferFailed();

    constructor(address owner_, IERC20Lite usd_) {
        owner = owner_;
        usd = usd_;
    }

    function sessionCount() external view returns (uint256) {
        return sessions.length;
    }

    function free(address user) external view returns (Totals memory) {
        return _free[user];
    }

    /// @notice Open the next session: a minimal proxy of `implementation`, initialized with `c`
    ///         (this vault, its USD token and the next id are set here).
    function openSession(address implementation, ClearingStorage.Config memory c) external returns (address session) {
        if (msg.sender != owner) revert WrongState();
        uint64 id = uint64(sessions.length + 1);
        (c.vault, c.usd, c.sessionId) = (address(this), usd, id);
        session = Clone1167.clone(implementation);
        IClearingSession(session).initialize(c);
        sessions.push(session);
        sessionIdOf[session] = id;
        emit SessionOpened(id, session, implementation);
    }

    /// @notice A registered session pays a user's redemption in: `msg.value` ETH, and
    ///         `usdAmount` USD it has already transferred here.
    function credit(address user, uint128 usdAmount) external payable {
        if (sessionIdOf[msg.sender] == 0) revert WrongState();
        Totals storage t = totalFree;
        if (usd.balanceOf(address(this)) < uint256(t.usd) + usdAmount) revert WrongState();
        uint128 e = uint128(msg.value);
        t.eth += e;
        t.usd += usdAmount;
        _free[user].eth += e;
        _free[user].usd += usdAmount;
        emit Credited(user, msg.sender, e, usdAmount);
    }

    /// @notice Move some of the caller's free balance into a registered session as a deposit.
    function fund(address session, uint8 token, uint128 amount) external {
        if (sessionIdOf[session] == 0 || amount == 0) revert WrongState();
        _debit(msg.sender, token, amount);
        if (token == R.ETH) {
            IClearingSession(session).depositFor{value: amount}(msg.sender, token, amount);
        } else {
            if (!usd.approve(session, amount)) revert TransferFailed();
            IClearingSession(session).depositFor(msg.sender, token, amount);
        }
        emit Funded(msg.sender, session, token, amount);
    }

    /// @notice Take free balance out to the caller's wallet.
    function withdraw(uint8 token, uint128 amount) external {
        if (amount == 0) revert WrongState();
        _debit(msg.sender, token, amount);
        emit Withdrawn(msg.sender, token, amount);
        if (token == R.ETH) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else if (!usd.transfer(msg.sender, amount)) {
            revert TransferFailed();
        }
    }

    function _debit(address user, uint8 token, uint128 amount) internal {
        Totals storage f = _free[user];
        Totals storage t = totalFree;
        if (token == R.ETH) {
            if (f.eth < amount) revert WrongState();
            f.eth -= amount;
            t.eth -= amount;
        } else if (token == R.USD) {
            if (f.usd < amount) revert WrongState();
            f.usd -= amount;
            t.usd -= amount;
        } else {
            revert WrongState();
        }
    }
}
