// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

import {CanonicalBlockRegistry} from "./CanonicalBlockRegistry.sol";
import {IStateTransitionVerifier} from "./interfaces/IStateTransitionVerifier.sol";

/// @notice The only upgrade path in the system (docs/guide/stage-2.md):
///         - `owner` may schedule a verifier replacement that takes effect no earlier than
///           EXIT_WINDOW (30 days) later, so users who disagree can leave first (settle, or the
///           operator-free emergency exit);
///         - `securityCouncil` may replace the verifier immediately only after a fault was
///           proven on chain (the registry is frozen by `proveConflict`);
///         - there are no other powers: settlement, anchors and escrow have no admin at all.
contract RollupGovernance {
    uint256 public constant EXIT_WINDOW = 30 days;

    address public immutable owner;
    address public immutable securityCouncil;
    CanonicalBlockRegistry public registry;

    struct Pending {
        IStateTransitionVerifier verifier;
        uint64 eta;
    }

    Pending public pending;

    event Scheduled(address verifier, uint64 eta);
    event Cancelled(address verifier);

    error Unauthorized();
    error TooEarly(uint64 eta);
    error NothingScheduled();
    error AlreadyBound();

    constructor(address owner_, address securityCouncil_) {
        owner = owner_;
        securityCouncil = securityCouncil_;
    }

    /// @notice One-time binding (the registry needs this contract's address at construction).
    function bind(CanonicalBlockRegistry r) external {
        if (address(registry) != address(0)) revert AlreadyBound();
        if (msg.sender != owner || r.governance() != address(this)) revert Unauthorized();
        registry = r;
    }

    function schedule(IStateTransitionVerifier v) external {
        if (msg.sender != owner) revert Unauthorized();
        pending = Pending(v, uint64(block.timestamp + EXIT_WINDOW));
        emit Scheduled(address(v), pending.eta);
    }

    function cancel() external {
        if (msg.sender != owner) revert Unauthorized();
        emit Cancelled(address(pending.verifier));
        delete pending;
    }

    /// @notice Anyone may execute a matured upgrade.
    function execute() external {
        Pending memory p = pending;
        if (address(p.verifier) == address(0)) revert NothingScheduled();
        if (block.timestamp < p.eta) revert TooEarly(p.eta);
        delete pending;
        registry.replaceVerifier(p.verifier, false);
    }

    function emergencyReplace(IStateTransitionVerifier v) external {
        if (msg.sender != securityCouncil) revert Unauthorized();
        registry.replaceVerifier(v, true); // reverts unless a fault was proven
    }
}
