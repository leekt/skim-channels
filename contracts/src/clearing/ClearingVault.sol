// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {IERC20Lite} from "./ClearingStorage.sol";
import {ClearingRules as R} from "./ClearingRules.sol";

interface IClearingSession {
    function config()
        external
        view
        returns (
            address operator,
            address usd,
            address anchors,
            address codec,
            address priceAdapter,
            uint256 bandBps,
            uint256 challengeWindow,
            uint256 forceDelay,
            uint256 maxAnchorAge,
            uint256 minBond,
            uint256 takeoverDelay,
            uint256 appChainId,
            address vault,
            uint64 sessionId
        );
    function depositFor(address user, uint8 token, uint128 amount) external payable;
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
/// - Sessions are registered by the app's owner with consecutive ids; the id is the salt of
///   the session's EIP-712 domain, so orders signed for one session never verify in another.
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

    event SessionRegistered(uint64 indexed id, address session);
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

    /// @notice Register the next session: it must name this vault, the same USD token, and
    ///         the next id.
    function register(address session) external {
        if (msg.sender != owner || sessionIdOf[session] != 0) revert WrongState();
        (, address u,,,,,,,,,,, address v, uint64 id) = IClearingSession(session).config();
        if (v != address(this) || u != address(usd) || id != sessions.length + 1) revert WrongState();
        sessions.push(session);
        sessionIdOf[session] = id;
        emit SessionRegistered(id, session);
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
