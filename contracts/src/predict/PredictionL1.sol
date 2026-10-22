// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {PredictionTypes as T} from "./PredictionTypes.sol";
import {PredictionRules} from "./PredictionRules.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {WitnessVerifier} from "../verifiers/WitnessVerifier.sol";

/// @notice The same prediction game run directly on L1, as the cost baseline for
///         PredictionChannel: every stake is an L1 transaction, the round resolves from the
///         same witness, and each user collects their own result. Same payout rule.
contract PredictionL1 {
    struct Round {
        bool resolved;
        uint8 outcome;
        uint8 shift;
        uint16 bits;
        uint64 stakeDeadline;
        uint64 resolutionBlock;
        address oracle;
        bytes32 slot;
        uint256 strike;
        uint256 totalUp;
        uint256 totalDown;
    }

    address public immutable operator;
    AnchorRegistry public immutable anchors;
    WitnessVerifier public immutable witnessVerifier;
    PredictionRules public immutable rules;

    mapping(address => uint256) public balance;
    uint256 public roundCount;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => uint256)) public upOf;
    mapping(uint256 => mapping(address => uint256)) public downOf;

    error WrongState();
    error TransferFailed();

    constructor(address operator_, AnchorRegistry anchors_, WitnessVerifier wv_, PredictionRules rules_) {
        operator = operator_;
        anchors = anchors_;
        witnessVerifier = wv_;
        rules = rules_;
    }

    function deposit() external payable {
        balance[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balance[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function openRound(
        uint256 strike,
        address oracle,
        bytes32 slot,
        uint8 shift,
        uint16 bits,
        uint64 stakeDeadline,
        uint64 resolutionBlock
    ) external returns (uint256 r) {
        if (msg.sender != operator || stakeDeadline >= resolutionBlock) revert WrongState();
        r = ++roundCount;
        rounds[r] = Round(false, 0, shift, bits, stakeDeadline, resolutionBlock, oracle, slot, strike, 0, 0);
    }

    function stake(uint256 r, uint8 side, uint256 amount) external {
        Round storage rd = rounds[r];
        if (block.number > rd.stakeDeadline || amount == 0) revert WrongState();
        balance[msg.sender] -= amount;
        if (side == T.UP) {
            upOf[r][msg.sender] += amount;
            rd.totalUp += amount;
        } else if (side == T.DOWN) {
            downOf[r][msg.sender] += amount;
            rd.totalDown += amount;
        } else {
            revert WrongState();
        }
    }

    function resolve(uint256 r, bytes calldata witness) external {
        Round storage rd = rounds[r];
        if (rd.resolved || rd.stakeDeadline == 0) revert WrongState();
        uint256 v = rules.oracleValue(
            witness, anchors, witnessVerifier, rd.resolutionBlock, rd.oracle, rd.slot, rd.shift, rd.bits
        );
        uint8 side = v >= rd.strike ? T.UP : T.DOWN;
        if ((side == T.UP ? rd.totalUp : rd.totalDown) == 0) side = 0;
        rd.outcome = side;
        rd.resolved = true;
    }

    /// @notice Credit the caller's result for round `r` to their balance.
    function collect(uint256 r) external {
        Round storage rd = rounds[r];
        if (!rd.resolved) revert WrongState();
        uint256 up = upOf[r][msg.sender];
        uint256 down = downOf[r][msg.sender];
        if (up + down == 0) revert WrongState();
        delete upOf[r][msg.sender];
        delete downOf[r][msg.sender];
        uint256 pot = rd.totalUp + rd.totalDown;
        uint256 won =
            rd.outcome == 0 ? up + down : rd.outcome == T.UP ? up * pot / rd.totalUp : down * pot / rd.totalDown;
        balance[msg.sender] += won;
    }
}
