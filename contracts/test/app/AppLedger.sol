// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {AppChannelVault} from "../../src/app/AppChannelVault.sol";
import {AppLeaves} from "../../src/app/AppLeaves.sol";
import {MockAppCheckpointVerifier} from "../../src/app/MockAppCheckpointVerifier.sol";

/// Test-side reference "app" (a plain ledger: balances, transfers, withdrawals) and honest
/// mock prover: computes exit/credit trees exactly as the spec says and produces checkpoints.
/// Exit allocation = balance (this app can always terminate); credits are cumulative.
contract AppLedger {
    struct Entry {
        address recipient;
        address token;
        uint256 value;
    }

    AppChannelVault public vault;
    bytes32 public id;
    bytes32 constant MOCK_TAG = keccak256("skim-app-channels/mock-proof/v0");

    address[] internal keyR;
    address[] internal keyT;
    mapping(bytes32 => bool) internal known;
    mapping(bytes32 => uint256) public balance;
    mapping(bytes32 => uint256) public credit;
    // Values as of the last published checkpoint (net diffs are taken against these).
    mapping(bytes32 => uint256) internal pubBalance;
    mapping(bytes32 => uint256) internal pubCredit;
    uint64 public depositCursor;
    uint64 public forcedCursor;

    constructor(AppChannelVault v, bytes32 channelId) {
        vault = v;
        id = channelId;
    }

    function k(address r, address t) internal pure returns (bytes32) {
        return keccak256(abi.encode(r, t));
    }

    function _touch(address r, address t) internal {
        if (!known[k(r, t)]) {
            known[k(r, t)] = true;
            keyR.push(r);
            keyT.push(t);
        }
    }

    // ---- app semantics ----
    function consumeDeposits(uint64 upTo) public {
        for (uint64 i = depositCursor; i < upTo; ++i) {
            AppChannelVault.Deposit memory d = vault.deposits(id, i);
            _touch(d.owner, d.token);
            balance[k(d.owner, d.token)] += d.amount;
        }
        depositCursor = upTo;
    }

    function consumeForced(uint64 upTo) public {
        for (uint64 i = forcedCursor; i < upTo; ++i) {
            AppChannelVault.Forced memory f = vault.forcedRequest(id, i);
            withdraw(f.account, f.token, balance[k(f.account, f.token)]);
        }
        forcedCursor = upTo;
    }

    function transfer(address from, address to, address token, uint256 amount) public returns (bool) {
        if (balance[k(from, token)] < amount) return false;
        _touch(to, token);
        balance[k(from, token)] -= amount;
        balance[k(to, token)] += amount;
        return true;
    }

    function withdraw(address who, address token, uint256 amount) public returns (bool) {
        if (balance[k(who, token)] < amount) return false;
        _touch(who, token);
        balance[k(who, token)] -= amount;
        credit[k(who, token)] += amount;
        return true;
    }

    /// Applies one checkpoint's published net diff (zero = deleted) and its accepted cursors.
    /// Replaying every accepted checkpoint's diff from genesis rebuilds the state from L1 data.
    function applyDiff(bytes calldata published, uint64 depCursor, uint64 fCursor) external {
        (Entry[] memory ex, Entry[] memory cr) = abi.decode(published, (Entry[], Entry[]));
        for (uint256 i; i < ex.length; ++i) {
            _touch(ex[i].recipient, ex[i].token);
            balance[k(ex[i].recipient, ex[i].token)] = ex[i].value;
        }
        for (uint256 i; i < cr.length; ++i) {
            _touch(cr[i].recipient, cr[i].token);
            credit[k(cr[i].recipient, cr[i].token)] = cr[i].value;
        }
        depositCursor = depCursor;
        forcedCursor = fCursor;
    }

    /// TEST ONLY: sets a balance out of thin air (to model a malicious, unproven transition).
    function forgeBalance(address r, address t, uint256 v) external {
        _touch(r, t);
        balance[k(r, t)] = v;
    }

    // ---- trees ----
    function entries(bool exits) public view returns (Entry[] memory out) {
        uint256 n;
        for (uint256 i; i < keyR.length; ++i) {
            if ((exits ? balance[k(keyR[i], keyT[i])] : credit[k(keyR[i], keyT[i])]) != 0) n++;
        }
        out = new Entry[](n);
        uint256 j;
        for (uint256 i; i < keyR.length; ++i) {
            uint256 v = exits ? balance[k(keyR[i], keyT[i])] : credit[k(keyR[i], keyT[i])];
            if (v != 0) out[j++] = Entry(keyR[i], keyT[i], v);
        }
        // sort by key
        for (uint256 a = 1; a < out.length; ++a) {
            Entry memory x = out[a];
            uint256 b = a;
            while (b > 0 && k(out[b - 1].recipient, out[b - 1].token) > k(x.recipient, x.token)) {
                out[b] = out[b - 1];
                b--;
            }
            out[b] = x;
        }
    }

    function _leaves(Entry[] memory es, bool exits) internal pure returns (bytes32[] memory l) {
        uint256 size = 2;
        while (size < es.length) size <<= 1;
        l = new bytes32[](size);
        for (uint256 i; i < es.length; ++i) {
            l[i] = exits
                ? AppLeaves.exitLeaf(es[i].recipient, es[i].token, es[i].value)
                : AppLeaves.creditLeaf(es[i].recipient, es[i].token, es[i].value);
        }
    }

    function root(bool exits) public view returns (bytes32) {
        Entry[] memory es = entries(exits);
        if (es.length == 0) return 0;
        bytes32[] memory l = _leaves(es, exits);
        for (uint256 n = l.length; n > 1; n /= 2) {
            for (uint256 i; i < n / 2; ++i) {
                l[i] = keccak256(abi.encodePacked(l[2 * i], l[2 * i + 1]));
            }
        }
        return l[0];
    }

    function proof(bool exits, address r, address t)
        public
        view
        returns (uint256 index, bytes32[] memory siblings, uint256 value)
    {
        Entry[] memory es = entries(exits);
        bytes32[] memory l = _leaves(es, exits);
        index = type(uint256).max;
        for (uint256 i; i < es.length; ++i) {
            if (es[i].recipient == r && es[i].token == t) (index, value) = (i, es[i].value);
        }
        require(index != type(uint256).max, "no leaf");
        uint256 depth;
        for (uint256 n = l.length; n > 1; n /= 2) {
            depth++;
        }
        siblings = new bytes32[](depth);
        uint256 idx = index;
        for (uint256 d; d < depth; ++d) {
            siblings[d] = l[idx ^ 1];
            uint256 n = l.length >> d;
            for (uint256 i; i < n / 2; ++i) {
                l[i] = keccak256(abi.encodePacked(l[2 * i], l[2 * i + 1]));
            }
            idx >>= 1;
        }
    }

    // ---- honest mock prover ----
    function claim(bool terminal) public view returns (AppChannelVault.Claim memory c) {
        c.exitRoot = root(true);
        c.creditRoot = root(false);
        c.stateRoot = keccak256(abi.encode("ledger-state", c.exitRoot, c.creditRoot, depositCursor, forcedCursor));
        c.depositCursor = depositCursor;
        c.forcedCursor = forcedCursor;
        c.terminal = terminal;
    }

    /// The net diff since the last published checkpoint: every key whose value changed,
    /// zeros included (deletions), in key order.
    function data() public view returns (bytes memory) {
        return abi.encode(_diff(true), _diff(false));
    }

    function _diff(bool exits) internal view returns (Entry[] memory out) {
        uint256 n;
        for (uint256 i; i < keyR.length; ++i) {
            bytes32 kk = k(keyR[i], keyT[i]);
            if (exits ? balance[kk] != pubBalance[kk] : credit[kk] != pubCredit[kk]) n++;
        }
        out = new Entry[](n);
        uint256 j;
        for (uint256 i; i < keyR.length; ++i) {
            bytes32 kk = k(keyR[i], keyT[i]);
            if (exits ? balance[kk] != pubBalance[kk] : credit[kk] != pubCredit[kk]) {
                out[j++] = Entry(keyR[i], keyT[i], exits ? balance[kk] : credit[kk]);
            }
        }
        for (uint256 a = 1; a < out.length; ++a) {
            Entry memory x = out[a];
            uint256 b = a;
            while (b > 0 && k(out[b - 1].recipient, out[b - 1].token) > k(x.recipient, x.token)) {
                out[b] = out[b - 1];
                b--;
            }
            out[b] = x;
        }
    }

    /// Marks the current values as published (call after the checkpoint is accepted).
    function markPublished() public {
        for (uint256 i; i < keyR.length; ++i) {
            bytes32 kk = k(keyR[i], keyT[i]);
            pubBalance[kk] = balance[kk];
            pubCredit[kk] = credit[kk];
        }
    }

    function mockProof(AppChannelVault.Claim memory c, bytes memory d) public view returns (bytes memory) {
        return abi.encode(keccak256(abi.encode(MOCK_TAG, vault.inputsHash(id, c, keccak256(d)))));
    }

    function submit(bool terminal) external {
        AppChannelVault.Claim memory c = claim(terminal);
        bytes memory d = data();
        vault.submitCheckpoint(id, c, d, mockProof(c, d));
        markPublished();
    }

    function keys() external view returns (address[] memory, address[] memory) {
        return (keyR, keyT);
    }
}
