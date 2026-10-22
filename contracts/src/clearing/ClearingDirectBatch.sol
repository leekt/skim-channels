// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";
import {ClearingChecker} from "./ClearingChecker.sol";
import {AnchorRegistry} from "../AnchorRegistry.sol";
import {WitnessVerifier} from "../verifiers/WitnessVerifier.sol";
import {WitnessLib} from "../libraries/WitnessLib.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

/// @notice Cost control for ClearingChannel: the same fills settled as one L1 batch that L1
///         verifies completely and at once — every signature, price band, limit, nonce and
///         collateral check (ClearingChecker) — then applies immediately. Netting and one
///         transaction per batch, but no challenge window, no bond, no watcher. Only what the
///         comparison needs: deposits and batches.
contract ClearingDirectBatch {
    struct Account {
        uint128 ethBal;
        uint128 usdBal;
        uint64 nonceFloor;
    }

    address public immutable operator;
    AnchorRegistry public immutable anchors;
    WitnessVerifier public immutable witnessVerifier;
    ClearingChecker public immutable checker;
    address public immutable priceFeed;
    bytes32 public immutable priceSlot;
    uint256 public immutable bandBps;
    uint256 public immutable maxAnchorAge;
    address public immutable usd;
    bytes32 public immutable domain;
    mapping(address => Account) public accounts;

    error WrongState();
    error BadAnchor();
    error BadSignature();

    constructor(
        address operator_,
        AnchorRegistry anchors_,
        WitnessVerifier wv,
        ClearingChecker checker_,
        address feed,
        bytes32 slot,
        uint256 band,
        uint256 maxAge,
        address usd_
    ) {
        operator = operator_;
        anchors = anchors_;
        witnessVerifier = wv;
        checker = checker_;
        priceFeed = feed;
        priceSlot = slot;
        bandBps = band;
        maxAnchorAge = maxAge;
        usd = usd_;
        domain = R.domainSeparator(block.chainid, address(this));
    }

    function deposit(uint8 token, uint128 amount) external payable {
        if (token == R.ETH) {
            if (msg.value != amount) revert WrongState();
            accounts[msg.sender].ethBal += amount;
        } else {
            (bool ok,) = usd.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
            );
            if (!ok) revert WrongState();
            accounts[msg.sender].usdBal += amount;
        }
    }

    /// The batch: price witness, ABI-encoded fills, sorted traders, each fill's trader indices.
    function settle(bytes calldata witness, bytes calldata fills, address[] calldata users, uint16[] calldata at)
        external
    {
        if (msg.sender != operator) revert WrongState();
        (ChannelTypes.L1Anchor memory an, WitnessLib.Read[] memory reads) = witnessVerifier.verify(witness);
        if (
            an.chainId != block.chainid || anchors.stateRootOf(ChannelTypes.anchorId(an)) != an.stateRoot
                || block.number > an.blockNumber + maxAnchorAge
        ) revert BadAnchor();
        uint256 price = WitnessLib.find(reads, priceFeed, priceSlot);
        if (!checker.allSigned(domain, fills)) revert BadSignature();
        uint256 n = users.length;
        uint64[] memory floors = new uint64[](n);
        uint256[2][] memory free = new uint256[2][](n);
        for (uint256 i; i < n; ++i) {
            Account storage a = accounts[users[i]];
            floors[i] = a.nonceFloor;
            free[i] = [uint256(a.ethBal), uint256(a.usdBal)];
        }
        (int256[] memory dEth, int256[] memory dUsd, uint64[] memory nonces) =
            checker.net(fills, users, at, floors, free, ClearingChecker.Market(price, bandBps, an.blockNumber));
        for (uint256 i; i < n; ++i) {
            Account storage a = accounts[users[i]];
            a.ethBal = uint128(uint256(int256(uint256(a.ethBal)) + dEth[i])); // ≥ 0: net() checked
            a.usdBal = uint128(uint256(int256(uint256(a.usdBal)) + dUsd[i]));
            a.nonceFloor = nonces[i];
        }
    }
}
