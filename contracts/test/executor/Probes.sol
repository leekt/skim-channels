// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Stands in for any L1 contract an app imports: one value (slot 0) and a mapping.
contract L1Feed {
    uint256 public value;
    mapping(uint256 => uint256) public notes;

    constructor(uint256 v) {
        value = v;
    }

    function set(uint256 v) external {
        value = v;
    }

    function note(uint256 k, uint256 v) external {
        notes[k] = v;
    }

    function latest() external view returns (uint256) {
        return value;
    }

    receive() external payable {}
}

/// @notice EIP-1967-style proxy: the implementation runs in this contract's storage.
contract L1Proxy {
    bytes32 internal constant IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address impl) {
        assembly {
            sstore(IMPL, impl)
        }
    }

    fallback() external payable {
        assembly {
            let impl := sload(IMPL)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

interface IFeed {
    function latest() external view returns (uint256);
    function set(uint256 v) external;
    function note(uint256 k, uint256 v) external;
    function notes(uint256 k) external view returns (uint256);
}

/// @notice An app contract on the app network: its own state, plus calls into imported L1
///         contracts at their L1 addresses.
contract AppProbe {
    uint256 public count;
    uint256 public lastSeen;

    function read(address f) external view returns (uint256) {
        return IFeed(f).latest();
    }

    function noteOf(address f, uint256 k) external view returns (uint256) {
        return IFeed(f).notes(k);
    }

    function record(address f) external {
        lastSeen = IFeed(f).latest();
        count++;
    }

    function trySet(address f, uint256 v) external {
        IFeed(f).set(v);
    }

    function tryNote(address f, uint256 k, uint256 v) external {
        IFeed(f).note(k, v);
    }

    function staticNote(address f, uint256 k, uint256 v) external view returns (bool ok) {
        (ok,) = f.staticcall(abi.encodeCall(IFeed.note, (k, v)));
    }

    function pay(address f) external payable {
        (bool ok, bytes memory err) = f.call{value: msg.value}("");
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }
}

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice An app contract reading a Chainlink feed the usual way: through its proxy.
contract FeedReader {
    uint256 public reads;

    function price(address feed) external view returns (int256 answer, uint256 updatedAt) {
        (, answer,, updatedAt,) = IAggregatorV3(feed).latestRoundData();
    }

    function bump() external {
        reads++;
    }
}
