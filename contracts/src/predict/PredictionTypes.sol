// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.28;

/// @notice Shared types and the one balance rule both the challenge game and the exit use.
library PredictionTypes {
    uint8 internal constant UP = 1;
    uint8 internal constant DOWN = 2;
    bytes32 internal constant LEAF_TAG = keccak256("skim-predict/balance-leaf/v0");
    bytes32 internal constant PART_TAG = keccak256("skim-predict/participation-leaf/v0");

    /// Packed calldata sizes: a committed ticket is idx (4) ‖ up (16) ‖ down (16) ‖ nonce (8)
    /// ‖ signature (65); a leaf is balance, cumWithdrawn, depositsApplied (16 each) ‖
    /// requestsApplied (4); an update is idx (4) ‖ old leaf ‖ new leaf.
    uint256 internal constant TICKET_BYTES = 109;
    uint256 internal constant LEAF_BYTES = 52;
    uint256 internal constant UPDATE_BYTES = 108;

    /// A user's balance leaf. The leaf position (user index) identifies the user; an all-zero
    /// leaf hashes to 0, the empty leaf.
    struct Leaf {
        uint256 balance;
        uint256 cumWithdrawn; // cumulative amount released for withdrawal
        uint256 depositsApplied; // cumulative L1 deposit amount applied
        uint256 requestsApplied; // withdraw-all requests applied
    }

    /// A user's committed ticket in one round: the cumulative stakes of their latest signed
    /// ticket, and keccak256(nonce ‖ signature) so challengers can name the exact ticket.
    struct PartLeaf {
        uint256 up;
        uint256 down;
        bytes32 ticketHash;
    }

    /// The user signs a new ticket with each stake; it carries their running totals for the
    /// round, so only the highest-nonce ticket needs to reach L1.
    struct Ticket {
        uint256 up;
        uint256 down;
        uint64 nonce;
        bytes sig; // 65 bytes: r ‖ s ‖ v
    }

    /// What the round did, as the balance rule needs it.
    struct Effect {
        bool active; // false: no round, or a void round
        uint8 outcome; // 0: no winning stake, everyone refunded
        uint256 totalUp;
        uint256 totalDown;
        uint256 depositsAtCommit; // the user's cumulative deposits when the round committed
    }

    function leafHash(Leaf memory l) internal pure returns (bytes32) {
        if (l.balance == 0 && l.cumWithdrawn == 0 && l.depositsApplied == 0 && l.requestsApplied == 0) return 0;
        return keccak256(abi.encode(LEAF_TAG, l.balance, l.cumWithdrawn, l.depositsApplied, l.requestsApplied));
    }

    function partHash(PartLeaf memory p) internal pure returns (bytes32) {
        if (p.up == 0 && p.down == 0 && p.ticketHash == 0) return 0;
        return keccak256(abi.encode(PART_TAG, p.up, p.down, p.ticketHash));
    }

    /// @notice The leaf a user must end with, from the finalized leaf, the user's round leaf
    ///         and the counters chosen (deposits applied up to `deposits`, requests up to
    ///         `requests`). `ok` is false when those counters can't be right.
    ///
    /// The stake is taken from what the user had when the round committed:
    /// old balance + deposits up to the commit. A stake above that is an overdraft that no
    /// one challenged in time; the user forfeits what they had and wins nothing.
    function next(Leaf memory old, PartLeaf memory p, Effect memory e, uint256 deposits, uint256 requests)
        internal
        pure
        returns (Leaf memory n, bool ok)
    {
        if (deposits < old.depositsApplied || requests < old.requestsApplied) return (n, false);
        uint256 bal = old.balance + deposits - old.depositsApplied;
        uint256 stake = p.up + p.down;
        if (e.active && stake != 0) {
            if (deposits < e.depositsAtCommit || e.depositsAtCommit < old.depositsApplied) return (n, false);
            uint256 had = old.balance + e.depositsAtCommit - old.depositsApplied;
            if (stake > had) {
                bal -= had;
            } else if (e.outcome != 0) {
                uint256 pot = e.totalUp + e.totalDown;
                uint256 won = e.outcome == UP ? p.up * pot / e.totalUp : p.down * pot / e.totalDown;
                bal = bal - stake + won;
            }
        }
        n = Leaf(bal, old.cumWithdrawn, deposits, requests);
        if (requests > old.requestsApplied) {
            n.cumWithdrawn += bal;
            n.balance = 0;
        }
        ok = true;
    }
}
