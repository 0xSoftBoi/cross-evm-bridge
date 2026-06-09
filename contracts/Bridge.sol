// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Bridge — a custodial lock/release token bridge (hardened)
/// @notice The original version released tokens on *every* `Deposit` event with no record
///         of which deposits had already been paid out. Because the relayer is event-driven,
///         any event re-delivery — a relayer restart, a websocket reconnect, or a
///         source-chain reorg — re-triggered `release` and **double-paid**, draining the
///         destination reserve. It also used raw `transfer`/`transferFrom` (unchecked) and
///         emitted nothing on release.
///
///         This version fixes that:
///         - Each destination payout is keyed by a **transferId** derived from the unique
///           source deposit; `processed[transferId]` makes release **idempotent** — a
///           re-delivered event can never pay twice.
///         - A release must carry a **validator signature** over that transferId, so the
///           authority to pay out is explicit and verifiable (and decoupled from the owner).
///         - `SafeERC20`, a `Released` event, and `Pausable`.
///
///         Trust model: still **custodial** — you trust the validator to only sign payouts
///         that correspond to real, finalized source locks. A trust-minimized bridge would
///         replace the signature with a light-client / Merkle proof of the source event;
///         that boundary is documented in the README, not built here.
contract Bridge is Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public validator;       // authorizes destination releases
    uint256 public depositNonce;    // unique per lock on THIS chain
    mapping(bytes32 => bool) public processed; // transferId => already released

    event Locked(uint256 indexed nonce, address indexed from, address indexed to, uint256 amount);
    event Released(bytes32 indexed transferId, address indexed to, uint256 amount);
    event ValidatorUpdated(address indexed validator);

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyReleased();
    error BadValidatorSignature();

    constructor(address _token, address _validator) Ownable(msg.sender) {
        if (_token == address(0) || _validator == address(0)) revert ZeroAddress();
        token = IERC20(_token);
        validator = _validator;
    }

    /// @notice Lock `amount` on this (source) chain to be released to `to` on the
    ///         destination chain. Emits a uniquely-nonced `Locked` the relayer mirrors.
    function deposit(uint256 amount, address to) external whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Locked(depositNonce++, msg.sender, to, amount);
    }

    /// @notice The transferId binding a destination payout to one specific source lock.
    ///         Includes the destination chain id + this contract, so a signature can't be
    ///         replayed onto another deployment or chain.
    function transferId(
        uint256 srcChainId,
        address srcBridge,
        uint256 srcNonce,
        address to,
        uint256 amount
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(srcChainId, srcBridge, srcNonce, to, amount, block.chainid, address(this))
        );
    }

    /// @notice Release tokens for a source lock, authorized by the validator. Idempotent:
    ///         the same source lock can only ever pay out once.
    function release(
        uint256 srcChainId,
        address srcBridge,
        uint256 srcNonce,
        address to,
        uint256 amount,
        bytes calldata signature
    ) external whenNotPaused {
        bytes32 id = transferId(srcChainId, srcBridge, srcNonce, to, amount);
        if (processed[id]) revert AlreadyReleased();

        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(id), signature);
        if (signer != validator) revert BadValidatorSignature();

        processed[id] = true;            // effects before interaction (CEI)
        token.safeTransfer(to, amount);
        emit Released(id, to, amount);
    }

    // --- admin ---
    function setValidator(address _validator) external onlyOwner {
        if (_validator == address(0)) revert ZeroAddress();
        validator = _validator;
        emit ValidatorUpdated(_validator);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Owner liquidity management (top-ups happen via plain transfers to this contract).
    function withdraw(address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
    }
}
