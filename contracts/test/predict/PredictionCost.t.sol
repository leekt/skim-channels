// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {PredictionBase, Tree} from "./PredictionBase.sol";
import {PredictionL1} from "../../src/predict/PredictionL1.sol";
import {PredictionTypes as T} from "../../src/predict/PredictionTypes.sol";

/// One prediction round, priced per L1 transaction, run two ways: through PredictionChannel
/// (normal path and worst-case disputes) and directly on L1 (PredictionL1). Prints
/// `cost,<path>,<step>,<users>,<stakesPerUser>,<gas>` lines (docs/experiments/prediction-round-cost.md).
///
/// Transaction gas = 21,000 + calldata (EIP-2028 4/16 per byte, or the EIP-7623 floor of
/// 10/40 when higher) + execution (vm.lastCallGas, with the contracts and the sender cooled
/// first, so storage access is priced as in a fresh transaction) − refund (capped at 1/5).
contract PredictionCostTest is PredictionBase {
    PredictionL1 l1;
    uint256 nUsers;
    uint256 nStakes;

    function _txGas(address from, address to, bytes memory data) internal returns (uint256) {
        vm.cool(address(ch));
        vm.cool(address(l1));
        vm.cool(address(rules));
        vm.cool(address(wv));
        vm.cool(address(anchors));
        vm.cool(from); // the payee in every measured payout
        vm.prank(from, from);
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        Vm.Gas memory g = vm.lastCallGas();
        uint256 zeros;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == 0) zeros++;
        }
        uint256 tokens = zeros + 4 * (data.length - zeros);
        // gasTotalUsed already includes the 21,000 base (checked against a no-op call).
        uint256 standard = 4 * tokens + g.gasTotalUsed;
        uint256 floor = 21_000 + 10 * tokens;
        uint256 used = standard > floor ? standard : floor;
        uint256 refund = g.gasRefunded > 0 ? uint256(int256(g.gasRefunded)) : 0;
        if (refund > used / 5) refund = used / 5;
        return used - refund;
    }

    function _log(string memory path, string memory step, uint256 gas) internal view {
        console.log(
            string.concat(
                "cost,", path, ",", step, ",", vm.toString(nUsers), ",", vm.toString(nStakes), ",", vm.toString(gas)
            )
        );
    }

    /// Users alternate sides; each places `k` stakes of 0.1 ETH. On the channel that is k
    /// signed tickets off-chain and only the last one on L1.
    function _entries(uint256 r, uint256 n, uint256 k) internal view returns (Tk[] memory e) {
        e = new Tk[](n);
        for (uint256 i; i < n; ++i) {
            uint256 amt = k * 0.1 ether;
            e[i] = Tk(uint32(i), _ticket(keys[i], r, i % 2 == 0 ? amt : 0, i % 2 == 0 ? 0 : amt, uint64(k)));
        }
    }

    /// The channel's leaves after the round (UP wins; pot split pro rata among even users).
    function _settled(Tk[] memory e) internal view returns (T.Leaf[] memory n) {
        uint256 up;
        uint256 down;
        for (uint256 i; i < e.length; ++i) {
            T.PartLeaf memory p = _part(e[i].t);
            (up, down) = (up + p.up, down + p.down);
        }
        n = new T.Leaf[](who.length);
        for (uint256 i; i < e.length; ++i) {
            T.PartLeaf memory p = _part(e[i].t);
            uint256 won = p.up * (up + down) / up;
            n[i] = T.Leaf(10 ether - p.up - p.down + won, 0, 10 ether, 0);
        }
    }

    function _run(uint256 n, uint256 k) internal {
        nUsers = n;
        nStakes = k;
        _addUsers(n, 10 ether);
        l1 = new PredictionL1(op, anchors, wv, rules);

        // ---- the channel ----
        uint256 r = _open(6500);
        Tk[] memory e = _entries(r, n, k);
        uint32 last = uint32(n - 1);

        // Worst-case commit challenge: the last user's k stakes, all signatures checked, then
        // the overdraft against their balance leaf.
        uint256 snap = vm.snapshotState();
        {
            Tk[] memory over = _entries(r, n, k);
            over[last].t = _ticket(keys[last], r, 0, 10 ether + 1, uint64(k));
            _commit(r, over);
            _log(
                "channel",
                "challengeCommit",
                _txGas(
                    watcher,
                    address(ch),
                    abi.encodeCall(
                        ch.challengeCommit,
                        (
                            r,
                            last,
                            abi.encode(over[last].t),
                            Tree.siblings(_partLeaves(over), last),
                            fin[last],
                            _finSiblings(last)
                        )
                    )
                )
            );
        }
        vm.revertToState(snap);

        _log("channel", "commit", _txGas(op, address(ch), abi.encodeCall(ch.commit, (r, _pack(e)))));
        vm.roll(200);
        vm.setBlockhash(RESOLUTION, keccak256(raw1));
        _log("both", "recordAnchor", _txGas(watcher, address(anchors), abi.encodeCall(anchors.record, (raw1))));
        _log("channel", "resolve", _txGas(watcher, address(ch), abi.encodeCall(ch.resolve, (r, package1))));

        // Worst-case exit: frozen with the round resolved but unsettled.
        snap = vm.snapshotState();
        vm.prank(who[last]);
        ch.requestWithdraw();
        vm.warp(block.timestamp + 1 days);
        _log(
            "channel",
            "freeze",
            _txGas(watcher, address(ch), abi.encodeCall(ch.freeze, (last, fin[last], _finSiblings(last))))
        );
        _log(
            "channel",
            "exit",
            _txGas(
                who[last],
                address(ch),
                abi.encodeCall(
                    ch.exit,
                    (last, fin[last], _finSiblings(last), _partOf(e, last), Tree.siblings(_partLeaves(e), last))
                )
            )
        );
        vm.revertToState(snap);

        // Worst-case settlement challenge: the last user's leaf is off by one wei.
        T.Leaf[] memory next = _settled(e);
        snap = vm.snapshotState();
        {
            T.Leaf[] memory bad = new T.Leaf[](next.length);
            for (uint256 i; i < next.length; ++i) {
                bad[i] = next[i];
            }
            bad[last] = _wrong(next[last]);
            _propose(r, bad);
            _log(
                "channel",
                "challengeUpdate",
                _txGas(
                    watcher,
                    address(ch),
                    abi.encodeCall(
                        ch.challengeUpdate,
                        (
                            last,
                            abi.encode(
                                fin[last],
                                _finSiblings(last),
                                bad[last],
                                Tree.siblings(_hashes(bad), last),
                                _partOf(e, last),
                                Tree.siblings(_partLeaves(e), last)
                            )
                        )
                    )
                )
            );
        }
        vm.revertToState(snap);

        (bytes memory u, bytes32[] memory proof) = _updates(next);
        _log("channel", "propose", _txGas(op, address(ch), abi.encodeCall(ch.propose, (r, u, proof))));
        vm.warp(block.timestamp + WINDOW);
        _log("channel", "finalize", _txGas(watcher, address(ch), abi.encodeCall(ch.finalize, ())));
        for (uint256 i; i < n; ++i) {
            fin[i] = next[i];
        }

        // Normal withdrawal: request, a one-leaf proposal, claim.
        _log("channel", "requestWithdraw", _txGas(who[0], address(ch), abi.encodeCall(ch.requestWithdraw, ())));
        T.Leaf[] memory w = _copyFin();
        w[0] = T.Leaf(0, fin[0].balance, fin[0].depositsApplied, 1);
        (u, proof) = _updates(w);
        _log("channel", "proposeOne", _txGas(op, address(ch), abi.encodeCall(ch.propose, (0, u, proof))));
        vm.warp(block.timestamp + WINDOW);
        ch.finalize();
        fin[0] = w[0];
        _log("channel", "claim", _txGas(who[0], address(ch), abi.encodeCall(ch.claim, (0, fin[0], _finSiblings(0)))));

        // ---- the same round directly on L1 ----
        for (uint256 i; i < n; ++i) {
            vm.deal(who[i], 10 ether);
            vm.prank(who[i]);
            l1.deposit{value: 10 ether}();
        }
        vm.roll(90);
        vm.prank(op);
        uint256 lr = l1.openRound(6500, oracle, oracleSlot, 0, 256, DEADLINE, RESOLUTION);
        uint256 stakeTotal;
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < k; ++j) {
                stakeTotal += _txGas(
                    who[i], address(l1), abi.encodeCall(l1.stake, (lr, i % 2 == 0 ? T.UP : T.DOWN, 0.1 ether))
                );
            }
        }
        _log("l1", "stakeAll", stakeTotal);
        vm.roll(200);
        _log("l1", "resolve", _txGas(watcher, address(l1), abi.encodeCall(l1.resolve, (lr, package1))));
        uint256 collectTotal;
        for (uint256 i; i < n; ++i) {
            collectTotal += _txGas(who[i], address(l1), abi.encodeCall(l1.collect, (lr)));
        }
        _log("l1", "collectAll", collectTotal);
        _log("l1", "withdraw", _txGas(who[0], address(l1), abi.encodeCall(l1.withdraw, (1 ether))));
    }

    function _wrong(T.Leaf memory l) internal pure returns (T.Leaf memory w) {
        w = T.Leaf(l.balance + 1, l.cumWithdrawn, l.depositsApplied, l.requestsApplied);
    }

    function test_cost_10_users_1_stake() public {
        _run(10, 1);
    }

    function test_cost_10_users_8_stakes() public {
        _run(10, 8);
    }

    function test_cost_100_users_1_stake() public {
        _run(100, 1);
    }

    function test_cost_100_users_8_stakes() public {
        _run(100, 8);
    }

    function test_cost_1000_users_1_stake() public {
        _run(1000, 1);
    }
}
