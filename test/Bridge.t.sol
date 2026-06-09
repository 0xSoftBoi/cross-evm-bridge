// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bridge} from "../contracts/Bridge.sol";
import {MyToken} from "../contracts/MyToken.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract BridgeTest is Test {
    Bridge bridge;
    MyToken token;

    uint256 constant VALIDATOR_PK = 0xCAFE;
    address validator;
    address user = address(0xA11CE);
    address recipient = address(0xB0B);

    // a source lock to mirror on this (destination) bridge
    uint256 constant SRC_CHAIN = 11155111; // sepolia
    address constant SRC_BRIDGE = address(0x5052C); // the source bridge
    uint256 constant SRC_NONCE = 7;
    uint256 constant AMOUNT = 100 ether;

    function setUp() public {
        validator = vm.addr(VALIDATOR_PK);
        token = new MyToken();                 // mints 2000e18 to this test
        bridge = new Bridge(address(token), validator);
        token.transfer(address(bridge), 1000 ether); // fund the destination reserve
    }

    function _sig(uint256 amount) internal view returns (bytes memory) {
        bytes32 id = bridge.transferId(SRC_CHAIN, SRC_BRIDGE, SRC_NONCE, recipient, amount);
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(id);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VALIDATOR_PK, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _release(uint256 amount, bytes memory sig) internal {
        bridge.release(SRC_CHAIN, SRC_BRIDGE, SRC_NONCE, recipient, amount, sig);
    }

    // a validator-signed release pays out exactly once
    function test_release_validSignature_pays() public {
        _release(AMOUNT, _sig(AMOUNT));
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    // THE BUG THE ORIGINAL HAD: a re-delivered event must NOT double-pay
    function test_release_isIdempotent_noDoublePay() public {
        bytes memory sig = _sig(AMOUNT);
        _release(AMOUNT, sig);
        // relayer restart / ws reconnect / source reorg re-fires the same release
        vm.expectRevert(Bridge.AlreadyReleased.selector);
        _release(AMOUNT, sig);
        assertEq(token.balanceOf(recipient), AMOUNT, "must be paid once, not twice");
    }

    // a release not signed by the validator is rejected
    function test_release_wrongSigner_reverts() public {
        bytes32 id = bridge.transferId(SRC_CHAIN, SRC_BRIDGE, SRC_NONCE, recipient, AMOUNT);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(0xBADBAD, MessageHashUtils.toEthSignedMessageHash(id));
        vm.expectRevert(Bridge.BadValidatorSignature.selector);
        _release(AMOUNT, abi.encodePacked(r, s, v));
    }

    // tampering the amount invalidates the signature (it's bound into the transferId)
    function test_release_tamperedAmount_reverts() public {
        bytes memory sig = _sig(AMOUNT);          // signed for AMOUNT
        vm.expectRevert(Bridge.BadValidatorSignature.selector);
        _release(AMOUNT + 1, sig);                // claim more
    }

    // deposit locks tokens and emits a uniquely-incrementing nonce
    function test_deposit_locksAndNonces() public {
        token.transfer(user, 50 ether);
        vm.startPrank(user);
        token.approve(address(bridge), 50 ether);
        bridge.deposit(20 ether, recipient);
        bridge.deposit(30 ether, recipient);
        vm.stopPrank();
        assertEq(bridge.depositNonce(), 2);
        assertEq(token.balanceOf(address(bridge)), 1000 ether + 50 ether);
    }

    // pause blocks both sides
    function test_pause_blocks() public {
        bytes memory sig = _sig(AMOUNT);
        bridge.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _release(AMOUNT, sig);
    }
}
