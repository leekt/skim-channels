// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {ChannelTypes} from "../libraries/ChannelTypes.sol";
import {WitnessLib} from "../libraries/WitnessLib.sol";

/// @notice Stateless, shared verifier for abi.encode(WitnessPackage) (WitnessLib). A separate
///         contract so callers stay deployable where code is expensive (Amsterdam repricing:
///         ~1,600 gas per deployed byte measured on ethrex, under a 16.7M per-tx gas cap).
contract WitnessVerifier {
    /// @return anchor the package's anchor (callers must authenticate it)
    /// @return reads every storage read, proven against anchor.stateRoot
    function verify(bytes calldata witness)
        external
        pure
        returns (ChannelTypes.L1Anchor memory anchor, WitnessLib.Read[] memory reads)
    {
        WitnessLib.WitnessPackage memory p = WitnessLib.decode(witness);
        return (p.anchor, WitnessLib.verify(p));
    }
}
