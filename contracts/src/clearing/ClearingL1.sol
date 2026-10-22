// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ClearingRules as R} from "./ClearingRules.sol";
import {ChannelTypes} from "../libraries/ChannelTypes.sol";

interface IPriceFeed {
    function shareBps() external view returns (uint256); // the fixture's slot 0
}

/// @notice The same clearing run directly on L1, as a cost baseline: users deposit, and each
///         fill is one transaction in which the taker submits the maker's signed order with
///         their own (the cheapest common L1 design: no on-chain book). Same ClearingRules,
///         the price read straight from the feed contract, balances in storage.
contract ClearingL1 {
    struct Bal {
        uint128 eth;
        uint128 usd;
    }

    IPriceFeed public immutable feed;
    uint256 public immutable bandBps;
    address public immutable usd;
    bytes32 public immutable domain;
    mapping(address => Bal) public bal;
    /// Nonce bitmap (256 nonces per word), the cheapest common replay protection.
    mapping(address => mapping(uint256 => uint256)) public nonceWords;

    error Rejected(R.Reject reason);
    error BadSignature();
    error Used();
    error Insufficient();

    constructor(IPriceFeed feed_, uint256 bandBps_, address usd_) {
        feed = feed_;
        bandBps = bandBps_;
        usd = usd_;
        domain = R.domainSeparator(block.chainid, address(this));
    }

    function deposit(uint8 token, uint128 amount) external payable {
        if (token == R.ETH) {
            require(msg.value == amount);
            bal[msg.sender].eth += amount;
        } else {
            (bool ok,) = usd.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
            );
            require(ok);
            bal[msg.sender].usd += amount;
        }
    }

    function withdraw(uint8 token, uint128 amount) external {
        if (token == R.ETH) {
            bal[msg.sender].eth -= amount;
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok);
        } else {
            bal[msg.sender].usd -= amount;
            (bool ok,) = usd.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount));
            require(ok);
        }
    }

    /// The taker (msg.sender) fills `maker` with `taker`'s terms.
    function fill(R.Order calldata maker, bytes calldata sig, R.Order calldata taker) external {
        if (taker.trader != msg.sender) revert BadSignature();
        if (ChannelTypes.recoverSigner(R.orderDigest(domain, maker), sig) != maker.trader) revert BadSignature();
        R.Reject why = R.check(maker, taker, feed.shareBps(), bandBps, block.number);
        if (why != R.Reject.None) revert Rejected(why);
        _use(maker.trader, maker.nonce);
        _use(taker.trader, taker.nonce);
        _move(maker.trader, maker.sellToken, maker.sellAmount, taker.sellAmount);
        _move(taker.trader, taker.sellToken, taker.sellAmount, maker.sellAmount);
    }

    function _use(address who, uint64 nonce) internal {
        uint256 bit = 1 << (nonce & 255);
        uint256 w = nonceWords[who][nonce >> 8];
        if (w & bit != 0) revert Used();
        nonceWords[who][nonce >> 8] = w | bit;
    }

    function _move(address who, uint8 sellToken, uint128 out, uint128 inn) internal {
        Bal storage b = bal[who];
        if (sellToken == R.ETH) {
            if (b.eth < out) revert Insufficient();
            (b.eth, b.usd) = (b.eth - out, b.usd + inn);
        } else {
            if (b.usd < out) revert Insufficient();
            (b.usd, b.eth) = (b.usd - out, b.eth + inn);
        }
    }
}
